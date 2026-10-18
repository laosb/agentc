import AgentIsolation
import Foundation
import Subprocess
import Synchronization

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

/// An authenticated byte relay, not an MCP interpreter. Each capability is bound
/// to one client-supplied command and workspace; the network peer cannot choose
/// an executable, arguments, environment, or working directory.
final class HostStdioMCPBridge: Sendable {
  struct Server: Decodable, Sendable {
    struct Variable: Decodable, Sendable {
      let name: String
      let value: String
    }
    let name: String
    let command: String
    let args: [String]?
    let env: [Variable]?

    func validate() throws {
      guard !name.isEmpty, !command.isEmpty,
        !([command] + (args ?? [])).contains(where: { $0.contains("\0") }),
        !(env ?? []).contains(where: {
          $0.name.isEmpty || $0.name.contains("=") || $0.name.contains("\0")
            || $0.value.contains("\0")
        })
      else { throw ACPError("Invalid host stdio MCP command or environment") }
    }
  }

  private struct Definition: Sendable {
    let backend: String
    let cwd: URL
    let server: Server
  }
  private struct Connection: Sendable {
    let backend: String
    let task: Task<Void, Never>
  }
  private struct State {
    var stopped = false
    var definitions: [String: Definition] = [:]
    var connections: [UUID: Connection] = [:]
  }
  private let state = Mutex(State())
  private let listener: Int32
  let port: UInt16
  private let listenerDone: AsyncStream<Void>
  private let listenerFinished: AsyncStream<Void>.Continuation

  init() throws {
    #if canImport(Glibc)
      let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
      let fd = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { throw ACPError("Cannot create host MCP listener: errno \(errno)") }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = INADDR_ANY
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fd, 16) == 0,
      fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
      fcntl(fd, F_SETFL, O_NONBLOCK) == 0
    else {
      let error = errno
      _ = close(fd)
      throw ACPError("Cannot bind host MCP listener: errno \(error)")
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard named == 0 else {
      _ = close(fd)
      throw ACPError("Cannot determine host MCP listener port")
    }
    listener = fd
    port = UInt16(bigEndian: address.sin_port)
    (listenerDone, listenerFinished) = AsyncStream<Void>.makeStream()
    logger.debug("Host MCP bridge listening on port \(port)")
    DispatchQueue(label: "agentc.host-mcp.accept").async { self.acceptConnections() }
  }

  static func hasStdioServers(_ message: ACPProxy.Object) -> Bool {
    guard case .array(let servers) = message["params"]?.object?["mcpServers"] else { return false }
    return servers.contains { isStdio($0) }
  }

  private static func isStdio(_ value: ACPValue) -> Bool {
    guard let object = value.object else { return false }
    return (object["type"] == nil || object["type"] == "stdio") && object["command"] != nil
  }

  func rewrite(_ message: ACPProxy.Object, backend: String, cwd: URL) throws -> ACPProxy.Object {
    guard var params = message["params"]?.object,
      case .array(let servers) = params["mcpServers"]
    else { return message }
    // Validate the whole batch before publishing any capabilities.
    let definitions = try servers.map { value -> Server? in
      guard Self.isStdio(value) else { return nil }
      let server = try JSONDecoder().decode(Server.self, from: JSONEncoder().encode(value))
      try server.validate()
      return server
    }
    let rewritten = try state.withLock { state in
      guard !state.stopped else { throw ACPError("Host MCP bridge has stopped") }
      guard state.definitions.count + definitions.compactMap({ $0 }).count <= 128 else {
        throw ACPError("Too many host stdio MCP servers on this ACP connection")
      }
      return zip(servers, definitions).map { value, server -> ACPValue in
        guard let server, var object = value.object else { return value }
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        state.definitions[token] = Definition(backend: backend, cwd: cwd, server: server)
        object["command"] = .string(IsolationConfig.mcpRelayExecutable)
        object["args"] = .array([
          .string(BootstrapManager.mcpRelayArgument),
          .string(String(port)), .string(token),
        ])
        // Host environment values must not leak into the guest process.
        object["env"] = []
        return .object(object)
      }
    }
    logger.warning(
      "Host stdio MCP bridging enabled for this workspace; client commands run outside container isolation"
    )
    params["mcpServers"] = .array(rewritten)
    var message = message
    message["params"] = .object(params)
    return message
  }

  func stop(backend: String) {
    let tasks = state.withLock { state in
      state.definitions = state.definitions.filter { $0.value.backend != backend }
      return state.connections.values.filter { $0.backend == backend }.map(\.task)
    }
    for task in tasks { task.cancel() }
  }

  func shutdown() async {
    let tasks = state.withLock { state in
      state.stopped = true
      state.definitions.removeAll()
      return state.connections.values.map(\.task)
    }
    for task in tasks { task.cancel() }
    for await _ in listenerDone {}
    for task in tasks { await task.value }
  }

  private func acceptConnections() {
    defer {
      _ = close(listener)
      listenerFinished.finish()
    }
    while !state.withLock({ $0.stopped }) {
      var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      let result = poll(&event, 1, 100)
      if result < 0 {
        if errno == EINTR { continue }
        logger.error("Host MCP listener failed: errno \(errno)")
        return
      }
      guard result > 0 else { continue }
      let socket = accept(listener, nil, nil)
      guard socket >= 0 else { continue }
      logger.debug("Host MCP bridge accepted a connection")
      // Darwin inherits the listener's O_NONBLOCK. MCP programs expect normal
      // blocking stdin/stdout; don't expose EAGAIN to the child.
      guard fcntl(socket, F_SETFD, FD_CLOEXEC) == 0,
        fcntl(socket, F_SETFL, 0) == 0
      else {
        _ = close(socket)
        continue
      }
      #if canImport(Darwin)
        var noSigpipe: Int32 = 1
        _ = setsockopt(
          socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
      #endif
      guard let token = authenticate(socket) else {
        logger.warning("Rejected host MCP connection: incomplete authentication")
        _ = close(socket)
        continue
      }
      let started = state.withLock { state -> Bool in
        guard !state.stopped, let definition = state.definitions[token],
          state.connections.count < 32
        else { return false }
        let id = UUID()
        let task = Task {
          await self.run(definition, socket: socket)
          _ = self.state.withLock { $0.connections.removeValue(forKey: id) }
        }
        state.connections[id] = Connection(backend: definition.backend, task: task)
        return true
      }
      if !started {
        logger.warning("Rejected host MCP connection: invalid capability or connection limit")
        _ = close(socket)
      }
    }
  }

  private func authenticate(_ socket: Int32) -> String? {
    let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    var bytes: [UInt8] = []
    while bytes.count < 65, DispatchTime.now().uptimeNanoseconds < deadline,
      !state.withLock({ $0.stopped })
    {
      var event = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
      guard poll(&event, 1, 100) > 0 else { continue }
      var byte: UInt8 = 0
      guard recv(socket, &byte, 1, 0) == 1 else { return nil }
      if byte == 10 {
        guard bytes.count == 64 else { return nil }
        return String(bytes: bytes, encoding: .utf8)
      }
      bytes.append(byte)
    }
    return nil
  }

  private func run(_ definition: Definition, socket: Int32) async {
    defer { _ = close(socket) }
    do {
      try Task.checkCancellation()
      let ack = Array("OK\n".utf8)
      #if os(Linux)
        let flags = Int32(MSG_NOSIGNAL)
      #else
        let flags: Int32 = 0
      #endif
      guard ack.withUnsafeBytes({ send(socket, $0.baseAddress, $0.count, flags) }) == ack.count
      else {
        return
      }
      var environment: [Environment.Key: String?] = [:]
      for variable in definition.server.env ?? [] {
        environment[Environment.Key(stringLiteral: variable.name)] = variable.value
      }
      var platform = PlatformOptions()
      platform.createSession = true
      platform.teardownSequence = [
        .gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(2))
      ]
      let command = definition.server.command
      let executable: Executable = command.contains("/") ? .path(FilePath(command)) : .name(command)
      let fd = FileDescriptor(rawValue: socket)
      let result = try await Subprocess.run(
        executable,
        arguments: Arguments(definition.server.args ?? []),
        environment: .inherit.updating(environment),
        workingDirectory: FilePath(definition.cwd.path),
        platformOptions: platform,
        input: .fileDescriptor(fd, closeAfterSpawningProcess: false),
        output: .fileDescriptor(fd, closeAfterSpawningProcess: false),
        error: .fileDescriptor(.standardError, closeAfterSpawningProcess: false))
      if !result.terminationStatus.isSuccess {
        logger.warning(
          "Host stdio MCP server \(definition.server.name) exited: \(result.terminationStatus)")
      }
    } catch {
      if !Task.isCancelled {
        logger.warning("Host stdio MCP server \(definition.server.name) failed: \(error)")
      }
    }
  }

}
