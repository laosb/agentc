import AgentIsolation
import Foundation

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
///
/// Input arrives already framed and validated (`ACPInbound`). Only a few small
/// control messages are decoded and rewritten; everything else is forwarded as
/// the original bytes with the routing `id` and `sessionId` values replaced,
/// so payloads are never interpreted and never held in memory. While one
/// input is processed, everything emitted shares that input's permit.
final class ACPProxy {
  typealias Object = [String: ACPValue]
  struct Transport {
    /// Must not block; queued output is bounded by the permits it holds.
    var send: (ACPOutbound) -> Void
    var close: () -> Void
    var prepareSession: (Object) throws -> Object = { $0 }
  }
  typealias Launch = (String, ACPWorkspace?) throws -> Transport

  /// A decoded control message. `id` stays the client's raw token.
  private struct Control {
    var message: Object
    var id: Data?
    var bytes: Int
  }
  private struct Backend {
    var transport: Transport
    var workspace: ACPWorkspace?
    var ready = false
    var queued: [Control] = []
  }
  private struct Pending {
    var backend: String
    var id: Data
    var initializing: Bool
  }
  private let options: SharedOptions
  private let limits: ACPLimits
  private let launch: Launch
  private let output: (ACPOutbound) throws -> Void
  private let diagnostic: (String) -> Void
  private var backends: [String: Backend] = [:]
  private var pending: [String: Pending] = [:]
  private var callbacks: [String: (backend: String, id: Data)] = [:]
  private var sessions: [String: (backend: String, native: String)] = [:]
  private var initialize: Control?
  private var capabilities: Object?
  private var queuedBytes = 0
  private var permit: ACPPermit?
  private var sequence = 0
  private let discovery = "discovery"
  // Only for the synchronous Data entry points below.
  private var spool: ACPSpool?
  private var ownsSpool = false
  private let localGate = ACPGate(frames: .max, bytes: .max / 2)
  private var clientIngress: ACPIngress?
  private var backendIngress: [String: ACPIngress] = [:]

  init(
    options: SharedOptions, limits: ACPLimits = .standard, spool: ACPSpool? = nil,
    launch: @escaping Launch,
    output: @escaping (ACPOutbound) throws -> Void,
    diagnostic: @escaping (String) -> Void = { logger.warning("\($0)") }
  ) {
    self.options = options
    self.limits = limits
    self.spool = spool
    self.launch = launch
    self.output = output
    self.diagnostic = diagnostic
  }

  // MARK: Synchronous entry points

  /// Frames and processes bytes on the calling thread. The command instead
  /// frames each stream on its own thread, under a bounded window, and
  /// delivers `ACPInbound` values; these entry points have no backpressure.
  func receiveClient(_ data: Data) throws {
    if clientIngress == nil { clientIngress = try makeIngress() }
    var received: [ACPInbound] = []
    clientIngress!.receive(data) { received.append($0) }
    for inbound in received { try receiveClient(inbound) }
  }

  func receiveBackend(_ id: String, data: Data) throws {
    guard backends[id] != nil else { return }
    if backendIngress[id] == nil { backendIngress[id] = try makeIngress() }
    var received: [ACPInbound] = []
    backendIngress[id]!.receive(data) { received.append($0) }
    for inbound in received { try receiveBackend(id, inbound) }
  }

  private func makeIngress() throws -> ACPIngress {
    if spool == nil {
      spool = try ACPSpool(limits: limits)
      ownsSpool = true
    }
    return ACPIngress(limits: limits, spool: spool!, gate: localGate)
  }

  func finish() throws {
    defer {
      for backend in backends.values { backend.transport.close() }
      backends.removeAll()
      backendIngress.removeAll()
      if ownsSpool { spool?.remove() }
    }
    if clientIngress?.truncated == true { throw ACPError("Truncated ACP message at EOF") }
  }

  // MARK: Client input

  func receiveClient(_ inbound: ACPInbound) throws {
    defer { permit = nil }
    switch inbound {
    case .malformed(let reason, let permit):
      self.permit = permit
      // Nothing in a line that is not JSON can be trusted, including its id.
      diagnostic("Rejecting malformed client ACP message: \(reason)")
      try emit(Self.errorLine(id: nil, code: -32700, message: "Parse error: \(reason)"))
    case .rejected(let reason, let envelope, let permit):
      self.permit = permit
      diagnostic("Rejecting client ACP message: \(reason)")
      if !envelope.hasMethod {
        // A response the agent may be waiting for must still be answered.
        if let key = envelope.idString, let callback = callbacks.removeValue(forKey: key) {
          try? send(
            Self.errorLine(
              id: callback.id, code: -32603, message: "ACP client response was rejected: \(reason)"),
            to: callback.backend)
        } else {
          try emit(Self.errorLine(id: nil, code: -32600, message: reason))
        }
      } else if let id = envelope.id {
        try emit(Self.errorLine(id: id, code: -32600, message: reason))
      } else if envelope.idAmbiguous {
        try emit(Self.errorLine(id: nil, code: -32600, message: reason))
      }  // Otherwise a notification: nobody is waiting for a reply.
    case .message(let frame, let permit):
      self.permit = permit
      do { try client(frame) } catch { try reject(frame.envelope.id, String(describing: error)) }
    }
  }

  private func client(_ frame: ACPFrame) throws {
    let envelope = frame.envelope
    guard let method = envelope.method else {
      guard !envelope.hasMethod else { throw ACPError("method must be a string") }
      if let key = envelope.idString, let range = envelope.idRange,
        let callback = callbacks.removeValue(forKey: key)
      {
        try send(
          ACPOutbound(
            body: frame.body, edits: [.init(range: range, replacement: callback.id)], permit: permit),
          to: callback.backend)
      }
      return
    }
    if method == "initialize" {
      guard initialize == nil else { throw ACPError("Already initialized") }
      let request = try control(frame)
      let transport = try launch(discovery, nil)
      initialize = request
      backends[discovery] = Backend(transport: transport, workspace: nil)
      try forward(request, to: discovery, initializing: true)
      return
    }
    guard capabilities != nil else { throw ACPError("Initialize must complete first") }
    if ["session/new", "session/load", "session/resume"].contains(method) {
      let request = try control(frame)
      let params = request.message["params"]?.object ?? [:]
      guard let cwd = params["cwd"]?.string, cwd.hasPrefix("/"), !cwd.contains("\0") else {
        throw ACPError("Session cwd must be an absolute directory path")
      }
      guard params["additionalDirectories"] == nil else {
        throw ACPError(
          "Use settings additionalMounts or --additional-mount; live expansion is unsupported")
      }
      let key = AgentIsolationPathUtils.containerMountPath(
        for: URL(fileURLWithPath: cwd), scheme: .host)
      if backends[key]?.ready == true {
        try forwardSession(request, to: key)
        return
      }
      guard queuedBytes + request.bytes <= limits.queuedControlBytes else {
        throw ACPError("Too many queued session requests")
      }
      // Resolve only when first used: settings edits cannot expand a live backend.
      if backends[key] == nil {
        guard backends.count < 9 else { throw ACPError("At most eight ACP workspaces may be open") }
        let workspace = try ACPWorkspace.resolve(cwd, options: options)
        backends[key] = Backend(transport: try launch(key, workspace), workspace: workspace)
        backends[key]!.queued.append(request)
        queuedBytes += request.bytes
        try forward(initialize!, to: key, initializing: true)
      } else {
        guard backends[key]!.queued.count < 64 else {
          throw ACPError("Too many queued session requests")
        }
        backends[key]!.queued.append(request)
        queuedBytes += request.bytes
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
    if let session = envelope.paramsSessionID {
      guard let route = sessions[session] else { throw ACPError("Unknown sessionId") }
      try forward(frame, to: route.backend, session: route.native)
    } else {
      // Authentication and connection-scoped extensions use the discovery backend.
      try forward(frame, to: discovery)
    }
  }

  private func forwardSession(_ control: Control, to backend: String) throws {
    var control = control
    var params = control.message["params"]?.object ?? [:]
    guard params["additionalDirectories"] == nil else {
      throw ACPError(
        "Use settings additionalMounts or --additional-mount; live expansion is unsupported")
    }
    if let external = params["sessionId"]?.string {
      let native = try Self.decodeSession(external, workspace: backend)
      params["sessionId"] = .string(native)
      sessions[Self.sessionID(workspace: backend, native: native)] = (backend, native)
    }
    control.message["params"] = .object(params)
    if let prepare = backends[backend]?.transport.prepareSession {
      control.message = try prepare(control.message)
    }
    try forward(control, to: backend)
  }

  // MARK: Backend input

  func receiveBackend(_ id: String, _ inbound: ACPInbound) throws {
    defer { permit = nil }
    guard backends[id] != nil else { return }
    switch inbound {
    case .malformed(let reason, let permit):
      self.permit = permit
      // The line may have been a response somebody is waiting for, and there
      // is no trustworthy id to tell. Fail everything this backend owes.
      try backendEnded(id, reason: "malformed ACP message from backend: \(reason)")
    case .rejected(let reason, let envelope, let permit):
      self.permit = permit
      if envelope.hasMethod {
        if let raw = envelope.id {
          diagnostic("Backend \(id): rejecting ACP request: \(reason)")
          try? send(Self.errorLine(id: raw, code: -32600, message: reason), to: id)
        } else if envelope.idAmbiguous {
          try backendEnded(id, reason: "unattributable ACP message from backend: \(reason)")
        } else {
          diagnostic("Backend \(id): dropping ACP notification: \(reason)")
        }
      } else if let key = envelope.idString, let request = pending[key], request.backend == id {
        pending.removeValue(forKey: key)
        if request.initializing {
          try initializationFailed(id, request, "Backend initialization failed: \(reason)")
        } else {
          diagnostic("Backend \(id): rejecting ACP response: \(reason)")
          try reject(request.id, "ACP agent response was rejected: \(reason)", code: -32603)
        }
      } else {
        try backendEnded(id, reason: "unattributable ACP message from backend: \(reason)")
      }
    case .message(let frame, let permit):
      self.permit = permit
      try server(id, frame)
    }
  }

  func backendEnded(_ id: String, reason: String) throws {
    guard let backend = backends.removeValue(forKey: id) else { return }
    backendIngress.removeValue(forKey: id)
    diagnostic("Backend \(id): \(reason)")
    backend.transport.close()
    for (key, request) in pending.filter({ $0.value.backend == id }) {
      pending.removeValue(forKey: key)
      if !request.initializing || id == discovery {
        try reject(request.id, reason, code: -32603)
      }
    }
    for request in backend.queued {
      queuedBytes -= request.bytes
      try reject(request.id, reason, code: -32603)
    }
    callbacks = callbacks.filter { $0.value.backend != id }
    sessions = sessions.filter { $0.value.backend != id }
    if id == discovery, capabilities == nil { initialize = nil }
  }

  func initializationTimedOut(_ id: String) throws {
    if backends[id]?.ready == false {
      try backendEnded(id, reason: "ACP backend initialization timed out")
    }
  }

  private func server(_ backend: String, _ frame: ACPFrame) throws {
    let envelope = frame.envelope
    var edits: [ACPOutbound.Edit] = []
    if envelope.hasMethod {
      if let native = envelope.paramsSessionID, let range = envelope.paramsSessionRange {
        let external = Self.sessionID(workspace: backend, native: native)
        sessions[external] = (backend, native)
        edits.append(.init(range: range, replacement: Self.jsonString(external)))
      }
      if let id = envelope.id, let range = envelope.idRange {
        guard callbacks.count < 1024 else {
          diagnostic("Backend \(backend): too many outstanding ACP callbacks")
          try? send(
            Self.errorLine(id: id, code: -32603, message: "Too many outstanding ACP callbacks"),
            to: backend)
          return
        }
        let key = nextID()
        callbacks[key] = (backend, id)
        edits.append(.init(range: range, replacement: Self.jsonString(key)))
      }
      try output(Self.outbound(frame.body, edits, permit))
      return
    }
    guard let key = envelope.idString, let range = envelope.idRange,
      let request = pending[key], request.backend == backend
    else { return }
    pending.removeValue(forKey: key)
    if request.initializing {
      try initialized(backend, frame, request)
      return
    }
    edits.append(.init(range: range, replacement: request.id))
    if let native = envelope.resultSessionID, let range = envelope.resultSessionRange {
      let external = Self.sessionID(workspace: backend, native: native)
      sessions[external] = (backend, native)
      edits.append(.init(range: range, replacement: Self.jsonString(external)))
    }
    try output(Self.outbound(frame.body, edits, permit))
  }

  private func initialized(_ backend: String, _ frame: ACPFrame, _ request: Pending) throws {
    var message: Object
    do { message = try control(frame).message } catch {
      try initializationFailed(backend, request, "Backend initialization failed: \(error)")
      return
    }
    guard let result = message["result"]?.object else {
      if backend == discovery { try emit(Self.encodeLine(message, id: request.id)) }
      try backendEnded(backend, reason: "Backend initialization failed")
      return
    }
    let normalized = Self.advertised(result)
    if backend == discovery {
      capabilities = normalized
      message["result"] = .object(normalized)
      try emit(Self.encodeLine(message, id: request.id))
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
      queuedBytes -= request.bytes
      do { try forwardSession(request, to: backend) } catch {
        try reject(request.id, String(describing: error))
      }
    }
  }

  private func initializationFailed(_ backend: String, _ request: Pending, _ reason: String) throws {
    if backend == discovery { try reject(request.id, reason, code: -32603) }
    try backendEnded(backend, reason: reason)
  }

  // MARK: Forwarding

  /// Decodes a message the proxy must understand. These are small by nature;
  /// a large one is refused rather than held in memory.
  private func control(_ frame: ACPFrame) throws -> Control {
    let count = frame.body.count
    guard count <= limits.controlBytes else {
      throw ACPError("ACP control message exceeds the \(limits.controlBytes)-byte limit")
    }
    return Control(
      message: try Self.parse(frame.body.read(0..<count)), id: frame.envelope.id, bytes: count)
  }

  private func forward(_ control: Control, to backend: String, initializing: Bool = false) throws {
    guard backends[backend] != nil else { throw ACPError("Backend unavailable") }
    guard pending.count < 1024 else { throw ACPError("Too many outstanding ACP requests") }
    var message = control.message
    if let id = control.id {
      let key = nextID()
      pending[key] = Pending(backend: backend, id: id, initializing: initializing)
      message["id"] = .string(key)
    }
    try send(Self.encodeLine(message, id: nil), to: backend)
  }

  /// Forwards the original bytes, replacing only the request id and session id.
  private func forward(_ frame: ACPFrame, to backend: String, session: String? = nil) throws {
    guard backends[backend] != nil else { throw ACPError("Backend unavailable") }
    guard pending.count < 1024 else { throw ACPError("Too many outstanding ACP requests") }
    var edits: [ACPOutbound.Edit] = []
    if let session, let range = frame.envelope.paramsSessionRange {
      edits.append(.init(range: range, replacement: Self.jsonString(session)))
    }
    if let id = frame.envelope.id, let range = frame.envelope.idRange {
      let key = nextID()
      pending[key] = Pending(backend: backend, id: id, initializing: false)
      edits.append(.init(range: range, replacement: Self.jsonString(key)))
    }
    try send(Self.outbound(frame.body, edits, permit), to: backend)
  }

  private func send(_ line: Data, to backend: String) throws {
    try send(ACPOutbound(body: .inline(line), permit: permit), to: backend)
  }

  private func send(_ outbound: ACPOutbound, to backend: String) throws {
    guard let transport = backends[backend]?.transport else {
      throw ACPError("Backend unavailable")
    }
    transport.send(outbound)
  }

  private func nextID() -> String {
    sequence += 1
    return "agentc-\(sequence)"
  }

  private func reject(_ id: Data?, _ reason: String, code: Int = -32602) throws {
    diagnostic(reason)
    guard let id else { return }
    try emit(Self.errorLine(id: id, code: code, message: reason))
  }

  private func emit(_ line: Data) throws {
    try output(ACPOutbound(body: .inline(line), permit: permit))
  }

  private static func outbound(
    _ body: ACPBody, _ edits: [ACPOutbound.Edit], _ permit: ACPPermit?
  ) -> ACPOutbound {
    ACPOutbound(
      body: body, edits: edits.sorted { $0.range.lowerBound < $1.range.lowerBound }, permit: permit)
  }

  // MARK: Encoding

  static func parse(_ data: Data) throws -> Object {
    let value = try JSONDecoder().decode(Object.self, from: data)
    guard value["jsonrpc"]?.string == "2.0"
    else { throw ACPError("Expected an ACP JSON-RPC 2.0 object") }
    return value
  }

  static func encode(_ message: Object) throws -> Data {
    var data = try encodeLine(message, id: nil)
    data.append(10)
    return data
  }

  /// One line without its newline. A raw `id` token, when given, replaces the
  /// message's own so client IDs are echoed byte for byte.
  static func encodeLine(_ message: Object, id: Data?) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let id else { return try encoder.encode(message) }
    var message = message
    message["id"] = nil
    let rest = try encoder.encode(message)
    var data = Data(#"{"id":"#.utf8)
    data.append(id)
    if rest.count > 2 {
      data.append(0x2C)
      data.append(rest.dropFirst())
    } else {
      data.append(0x7D)
    }
    return data
  }

  static func jsonString(_ value: String) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return (try? encoder.encode(value)) ?? Data(#""""#.utf8)
  }

  static func errorLine(id: Data?, code: Int, message: String) -> Data {
    var data = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
    data.append(id ?? Data("null".utf8))
    data.append(Data(#","error":{"code":\#(code),"message":"#.utf8))
    data.append(jsonString(message))
    data.append(Data("}}".utf8))
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
