import AgentIsolation
import Foundation

/// ACP is newline-delimited JSON, not LSP Content-Length framing.
struct ACPFramer {
  static let limit = 16 * 1024 * 1024
  private var pending = Data()
  private var discarding = false
  private(set) var errors: [String] = []

  mutating func append(_ bytes: Data) -> [Data] {
    errors.removeAll(keepingCapacity: true)
    var lines: [Data] = []
    for byte in bytes {
      if byte == 10 {
        if !discarding, !pending.isEmpty { lines.append(pending) }
        pending = Data()
        discarding = false
      } else if !discarding {
        if pending.count == Self.limit {
          errors.append("ACP message exceeds 16 MiB; discarding through the next newline")
          pending = Data()
          discarding = true
        } else {
          pending.append(byte)
        }
      }
    }
    return lines
  }

  func finish() throws {
    guard pending.isEmpty else { throw ACPError("Truncated ACP message at EOF") }
  }
}

struct ACPError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// A snapshot: a running backend never re-reads settings or widens its mounts.
struct ACPWorkspace {
  let cwd: URL
  let settings: ProjectSettings?
  let additionalMounts: [URL]

  static func resolve(_ path: String, options: SharedOptions) throws -> Self {
    guard path.hasPrefix("/"), !path.contains("\0") else {
      throw ACPError("ACP cwd must be an absolute directory path")
    }
    let cwd = URL(fileURLWithPath: path)
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &directory),
      directory.boolValue
    else { throw ACPError("ACP cwd does not exist: \(path)") }
    if let restriction = options.workspace {
      let root = URL(fileURLWithPath: restriction).resolvingSymlinksInPath().path
      guard contains(root, cwd.resolvingSymlinksInPath().path) else {
        throw ACPError("ACP cwd is outside --workspace: \(path)")
      }
    }
    let folder =
      options.agentcFolder.map { URL(fileURLWithPath: $0) }
      ?? cwd.appendingPathComponent(".agentc")
    let file = folder.appendingPathComponent("settings.json")
    let settings: ProjectSettings?
    if FileManager.default.fileExists(atPath: file.path) {
      // A malformed policy is an error, never permission to fall back to defaults.
      settings = try JSONDecoder().decode(ProjectSettings.self, from: Data(contentsOf: file))
    } else {
      settings = nil
    }
    let mounts = (options.additionalMount + (settings?.agent?.additionalMounts ?? [])).map {
      URL(fileURLWithPath: $0, relativeTo: cwd).absoluteURL
    }
    for mount in [cwd] + mounts {
      guard
        !AgentIsolationPathUtils.isReservedHostMountDestination(
          AgentIsolationPathUtils.containerMountPath(for: mount, scheme: .host))
      else { throw ACPError("Reserved container mount destination: \(mount.path)") }
      guard FileManager.default.fileExists(atPath: mount.path, isDirectory: &directory),
        directory.boolValue
      else { throw ACPError("Mount directory does not exist: \(mount.path)") }
    }
    return Self(cwd: cwd, settings: settings, additionalMounts: mounts)
  }

  static func contains(_ root: String, _ path: String) -> Bool {
    root == path || path.hasPrefix(root == "/" ? "/" : root + "/")
  }
}

/// Single-owner protocol state machine. Transport callbacks must enqueue events;
/// they must not call back into this object. Tests use the same state machine.
final class ACPProxy {
  typealias Object = [String: ACPValue]
  struct Transport {
    var send: (Data) -> Void
    var close: () -> Void
  }
  typealias Launch = (String, ACPWorkspace?) throws -> Transport

  private struct Backend {
    var transport: Transport
    var workspace: ACPWorkspace?
    var framer = ACPFramer()
    var ready = false
    var queued: [Object] = []
  }
  private struct Pending {
    var backend: String
    var original: Object
    var initializing: Bool
  }
  private let options: SharedOptions
  private let launch: Launch
  private let output: (Data) throws -> Void
  private let diagnostic: (String) -> Void
  private var backends: [String: Backend] = [:]
  private var pending: [String: Pending] = [:]
  private var callbacks: [String: (backend: String, id: ACPValue)] = [:]
  private var sessions: [String: (backend: String, native: String)] = [:]
  private var initialize: Object?
  private var capabilities: Object?
  private var clientFramer = ACPFramer()
  private var sequence = 0
  private let discovery = "discovery"

  init(
    options: SharedOptions, launch: @escaping Launch,
    output: @escaping (Data) throws -> Void,
    diagnostic: @escaping (String) -> Void = { logger.warning("\($0)") }
  ) {
    self.options = options
    self.launch = launch
    self.output = output
    self.diagnostic = diagnostic
  }

  func receiveClient(_ data: Data) throws {
    let lines = clientFramer.append(data)
    for error in clientFramer.errors { diagnostic(error) }
    for line in lines {
      let message: Object
      do { message = try Self.parse(line) } catch {
        diagnostic("Ignoring malformed client ACP message: \(error)")
        continue
      }
      do { try client(message) } catch { try reject(message, String(describing: error)) }
    }
  }

  func finish() throws {
    defer {
      for backend in backends.values { backend.transport.close() }
      backends.removeAll()
    }
    try clientFramer.finish()
  }

  func receiveBackend(_ id: String, data: Data) throws {
    guard var backend = backends[id] else { return }
    let lines = backend.framer.append(data)
    for error in backend.framer.errors { diagnostic("Backend \(id): \(error)") }
    backends[id] = backend
    for line in lines {
      let message: Object
      do { message = try Self.parse(line) } catch {
        diagnostic("Ignoring malformed ACP message from backend \(id): \(error)")
        continue
      }
      try server(id, message: message)
    }
  }

  func backendEnded(_ id: String, reason: String) throws {
    guard let backend = backends.removeValue(forKey: id) else { return }
    diagnostic("Backend \(id): \(reason)")
    backend.transport.close()
    for (key, request) in pending.filter({ $0.value.backend == id }) {
      pending.removeValue(forKey: key)
      if !request.initializing || id == discovery {
        try reject(request.original, reason, code: -32603)
      }
    }
    for message in backend.queued { try reject(message, reason, code: -32603) }
    callbacks = callbacks.filter { $0.value.backend != id }
    sessions = sessions.filter { $0.value.backend != id }
    if id == discovery, capabilities == nil { initialize = nil }
  }

  func initializationTimedOut(_ id: String) throws {
    if backends[id]?.ready == false {
      try backendEnded(id, reason: "ACP backend initialization timed out")
    }
  }

  private func client(_ message: Object) throws {
    guard let method = message["method"]?.string else {
      if let key = message["id"]?.string, let callback = callbacks.removeValue(forKey: key) {
        var response = message
        response["id"] = callback.id
        try send(response, to: callback.backend)
      }
      return
    }
    if method == "initialize" {
      guard initialize == nil else { throw ACPError("Already initialized") }
      let transport = try launch(discovery, nil)
      initialize = message
      backends[discovery] = Backend(transport: transport, workspace: nil)
      try forward(message, to: discovery, initializing: true)
      return
    }
    guard capabilities != nil else { throw ACPError("Initialize must complete first") }
    let params = message["params"]?.object ?? [:]
    if ["session/new", "session/load", "session/resume"].contains(method) {
      guard let cwd = params["cwd"]?.string, cwd.hasPrefix("/"), !cwd.contains("\0") else {
        throw ACPError("Session cwd must be an absolute directory path")
      }
      guard params["additionalDirectories"] == nil else {
        throw ACPError(
          "Use settings additionalMounts or --additional-mount; live expansion is unsupported")
      }
      let key = AgentIsolationPathUtils.containerMountPath(
        for: URL(fileURLWithPath: cwd), scheme: .host)
      // Resolve only when first used: settings edits cannot expand a live backend.
      if backends[key] == nil {
        guard backends.count < 9 else { throw ACPError("At most eight ACP workspaces may be open") }
        let workspace = try ACPWorkspace.resolve(cwd, options: options)
        backends[key] = Backend(transport: try launch(key, workspace), workspace: workspace)
        backends[key]!.queued.append(message)
        try forward(initialize!, to: key, initializing: true)
      } else if backends[key]!.ready {
        try forwardSession(message, to: key)
      } else {
        guard backends[key]!.queued.count < 64 else {
          throw ACPError("Too many queued session requests")
        }
        backends[key]!.queued.append(message)
      }
      return
    }
    if [
      "session/list", "session/fork", "session/add_directory", "session/remove_directory",
      "session/set_additional_directories", "_session/add_directory", "_session/remove_directory",
      "_session/set_additional_directories",
    ].contains(method) {
      throw ACPError("This ACP mode does not support session listing, forking, or mount expansion")
    }
    if let session = params["sessionId"]?.string {
      guard let route = sessions[session] else { throw ACPError("Unknown sessionId") }
      var request = message
      var rewritten = params
      rewritten["sessionId"] = .string(route.native)
      request["params"] = .object(rewritten)
      try forward(request, to: route.backend)
    } else {
      // Authentication and connection-scoped extensions use the discovery backend.
      try forward(message, to: discovery)
    }
  }

  private func forwardSession(_ message: Object, to backend: String) throws {
    var request = message
    var params = request["params"]?.object ?? [:]
    guard params["additionalDirectories"] == nil else {
      throw ACPError(
        "Use settings additionalMounts or --additional-mount; live expansion is unsupported")
    }
    if let external = params["sessionId"]?.string {
      let native = try Self.decodeSession(external, workspace: backend)
      params["sessionId"] = .string(native)
      sessions[Self.sessionID(workspace: backend, native: native)] = (backend, native)
    }
    request["params"] = .object(params)
    try forward(request, to: backend)
  }

  private func server(_ backend: String, message: Object) throws {
    var message = message
    if message["method"] != nil {
      if var params = message["params"]?.object, let native = params["sessionId"]?.string {
        let external = Self.sessionID(workspace: backend, native: native)
        sessions[external] = (backend, native)
        params["sessionId"] = .string(external)
        message["params"] = .object(params)
      }
      if let id = message["id"] {
        let key = nextID()
        callbacks[key] = (backend, id)
        message["id"] = .string(key)
      }
      try emit(message)
      return
    }
    guard let key = message["id"]?.string,
      let request = pending[key], request.backend == backend
    else { return }
    pending.removeValue(forKey: key)
    if request.initializing {
      guard let result = message["result"]?.object else {
        if backend == discovery {
          message["id"] = request.original["id"]
          try emit(message)
        }
        try backendEnded(backend, reason: "Backend initialization failed")
        return
      }
      let normalized = Self.advertised(result)
      if backend == discovery {
        capabilities = normalized
        message["result"] = .object(normalized)
        message["id"] = request.original["id"]
        try emit(message)
      } else {
        guard Self.compatible(capabilities!, normalized) else {
          try backendEnded(
            backend, reason: "Project agent capabilities differ from the initialized agent")
          return
        }
      }
      backends[backend]?.ready = true
      let queued = backends[backend]?.queued ?? []
      backends[backend]?.queued = []
      for request in queued {
        do { try forwardSession(request, to: backend) } catch {
          try reject(request, String(describing: error))
        }
      }
      return
    }
    message["id"] = request.original["id"]
    if var result = message["result"]?.object, let native = result["sessionId"]?.string {
      let external = Self.sessionID(workspace: backend, native: native)
      sessions[external] = (backend, native)
      result["sessionId"] = .string(external)
      message["result"] = .object(result)
    }
    try emit(message)
  }

  private func forward(_ message: Object, to backend: String, initializing: Bool = false) throws {
    guard backends[backend] != nil else { throw ACPError("Backend unavailable") }
    guard pending.count < 1024 else { throw ACPError("Too many outstanding ACP requests") }
    var rewritten = message
    if message["id"] != nil {
      let id = nextID()
      pending[id] = Pending(backend: backend, original: message, initializing: initializing)
      rewritten["id"] = .string(id)
    }
    try send(rewritten, to: backend)
  }

  private func send(_ message: Object, to backend: String) throws {
    guard let transport = backends[backend]?.transport else {
      throw ACPError("Backend unavailable")
    }
    transport.send(try Self.encode(message))
  }

  private func nextID() -> String {
    sequence += 1
    return "agentc-\(sequence)"
  }

  private func reject(_ message: Object, _ reason: String, code: Int = -32602) throws {
    diagnostic(reason)
    guard let id = message["id"] else { return }
    try emit([
      "jsonrpc": "2.0", "id": id,
      "error": ["code": .number(Decimal(code)), "message": .string(reason)],
    ])
  }

  private func emit(_ message: Object) throws { try output(Self.encode(message)) }

  static func parse(_ data: Data) throws -> Object {
    let value = try JSONDecoder().decode(Object.self, from: data)
    guard value["jsonrpc"]?.string == "2.0"
    else { throw ACPError("Expected an ACP JSON-RPC 2.0 object") }
    return value
  }

  static func encode(_ message: Object) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(message)
    data.append(10)
    return data
  }

  static func advertised(_ result: Object) -> Object {
    var result = result
    var capabilities = result["agentCapabilities"]?.object ?? [:]
    var sessions = capabilities["sessionCapabilities"]?.object ?? [:]
    for unsupported in ["list", "fork", "additionalDirectories"] {
      sessions.removeValue(forKey: unsupported)
    }
    capabilities["sessionCapabilities"] = .object(sessions)
    result["agentCapabilities"] = .object(capabilities)
    return result
  }

  static func compatible(_ lhs: Object, _ rhs: Object) -> Bool {
    // Only compare capabilities whose meaning this proxy understands. In
    // particular, _meta can contain changing auth status and opaque extensions.
    guard lhs["protocolVersion"] == rhs["protocolVersion"],
      lhs["authMethods"] == rhs["authMethods"]
    else { return false }
    let left = lhs["agentCapabilities"]?.object ?? [:]
    let right = rhs["agentCapabilities"]?.object ?? [:]
    return ["loadSession", "promptCapabilities", "mcpCapabilities", "sessionCapabilities"]
      .allSatisfy { left[$0] == right[$0] }
  }

  static func sessionID(workspace: String, native: String) -> String {
    "agentc:" + Data(workspace.utf8).base64EncodedString() + ":"
      + Data(native.utf8).base64EncodedString()
  }

  static func decodeSession(_ id: String, workspace: String) throws -> String {
    guard id.hasPrefix("agentc:") else {
      throw ACPError("Use the sessionId returned by agentc acp when loading or resuming a session")
    }
    let parts = id.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3,
      let root = Data(base64Encoded: String(parts[1])),
      String(data: root, encoding: .utf8) == workspace,
      let native = Data(base64Encoded: String(parts[2])),
      let value = String(data: native, encoding: .utf8)
    else { throw ACPError("Session ID belongs to another workspace or is malformed") }
    return value
  }
}
