import AgentIsolation
import Dispatch
import HostBridge
import Synchronization

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#else
  import Musl
#endif

/// One broker per container. A bounded number of blocking IO workers keeps the
/// POSIX loops off Swift's cooperative executor without unbounded task queues.
final class HostBridgeBroker: Sendable {
  let attachment: HostBridgeAttachment
  let manifest: BridgeManifest
  private let root: URL
  private let listener: Int32
  private let mappings: [String: HostBinaryMapping]
  private let workspace: String
  private let hostEnvironment: [String: String]
  private struct State {
    var stopped = false
    var connections: Set<Int32> = []
  }
  private let state = Mutex(State())
  private let workers = DispatchGroup()

  init(mappings declarations: [HostBinaryMapping], workspace: String) throws {
    try Self.validate(declarations)
    self.workspace = workspace
    self.hostEnvironment = ProcessInfo.processInfo.environment
    var mappings: [String: HostBinaryMapping] = [:]
    var entries: [BridgeManifest.Entry] = []
    for mapping in declarations {
      let id = UUID().uuidString
      mappings[id] = mapping
      entries.append(
        .init(
          id: id, path: mapping.containerPath, forwardEnvironment: mapping.forwardEnvironment ?? [])
      )
    }
    self.mappings = mappings
    manifest = .init(token: UUID().uuidString + UUID().uuidString, entries: entries)
    // A short path is necessary on Darwin (sun_path is only 104 bytes). The
    // private parent is never mounted; the readable guest subtree is mounted RO.
    root = URL(fileURLWithPath: "/tmp/agentc-bridge-\(UUID().uuidString)")
    let directory = root.appendingPathComponent("guest")
    let socket = root.appendingPathComponent("socket").path
    attachment = .init(directory: directory.path, socket: socket)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
      try JSONEncoder().encode(manifest).write(
        to: directory.appendingPathComponent("manifest.json"))
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: directory.appendingPathComponent("manifest.json").path)
      // Relay/bind target must exist inside the read-only manifest mount.
      try Data().write(to: directory.appendingPathComponent("socket"))
      listener = try BridgePOSIX.socket(path: socket, listening: true)
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
    // The private parent protects host access; the guest may have a different uid.
    chmod(socket, 0o666)
    workers.enter()
    DispatchQueue.global().async { [self] in
      defer {
        close(listener)
        workers.leave()
      }
      acceptConnections()
    }
  }

  static func validate(_ mappings: [HostBinaryMapping]) throws {
    var paths: Set<String> = []
    for mapping in mappings {
      let path = mapping.containerPath
      let components = path.split(separator: "/", omittingEmptySubsequences: false)
      guard path.hasPrefix("/"), !path.contains("\0"), path != "/",
        !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
        paths.insert(path).inserted,
        !["/proc", "/sys", "/dev", "/etc", "/run", "/agent-isolation", "/entrypoint-bootstrap"]
          .contains(where: { path == $0 || path.hasPrefix($0 + "/") })
      else { throw BridgeError("Invalid, reserved, or duplicate host bridge path: \(path)") }
      guard mapping.hostCommand.hasPrefix("/"), !mapping.hostCommand.contains("\0"),
        access(mapping.hostCommand, X_OK) == 0
      else {
        throw BridgeError(
          "Host command must be an absolute executable path: \(mapping.hostCommand)")
      }
      guard !(mapping.arguments ?? []).contains(where: { $0.contains("\0") }) else {
        throw BridgeError("Host bridge arguments cannot contain NUL")
      }
      for name in mapping.forwardEnvironment ?? [] {
        guard !name.isEmpty, !name.contains("="), !name.contains("\0"),
          !name.contains("*"), !name.hasPrefix("AGENTC_")
        else {
          throw BridgeError("Invalid host bridge environment name: \(name)")
        }
      }
    }
  }

  static func environment(
    for request: BridgeLaunch, mapping: HostBinaryMapping, host: [String: String]
  ) throws -> [String: String] {
    let allowed = Set(mapping.forwardEnvironment ?? [])
    guard
      request.environment.allSatisfy({
        allowed.contains($0.key) && !$0.value.contains("\0")
      })
    else { throw BridgeError("Host bridge environment is outside the allow list") }
    return host.merging(request.environment) { _, forwarded in forwarded }
  }

  /// Stops accepting, interrupts every IO loop, waits for child reaping, then
  /// removes credentials. Safe to call repeatedly, but never from a worker.
  func stop() {
    state.withLock {
      $0.stopped = true
      for fd in $0.connections { _ = shutdown(fd, Int32(SHUT_RDWR)) }
    }
    workers.wait()
    try? FileManager.default.removeItem(at: root)
  }

  private func acceptConnections() {
    while !state.withLock({ $0.stopped }) {
      var descriptors = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
      do { try BridgePOSIX.poll(&descriptors) } catch { return }
      guard descriptors[0].revents != 0 else { continue }
      #if canImport(Darwin)
        let fd = accept(listener, nil, nil)
      #elseif canImport(Glibc)
        let fd = accept4(listener, nil, nil, Int32(SOCK_CLOEXEC.rawValue))
      #else
        let fd = accept4(listener, nil, nil, SOCK_CLOEXEC)
      #endif
      guard fd >= 0 else { continue }
      do { try BridgePOSIX.configureSocket(fd) } catch {
        close(fd)
        continue
      }
      let admitted = state.withLock { state -> Bool in
        guard !state.stopped, state.connections.count < 32 else { return false }
        state.connections.insert(fd)
        workers.enter()
        return true
      }
      guard admitted else {
        close(fd)
        continue
      }
      DispatchQueue.global().async { [self] in
        serve(fd)
        workers.leave()
      }
    }
  }

  private func serve(_ fd: Int32) {
    // Do not change the host application's global signal disposition. Blocking
    // SIGPIPE on this worker converts broken pipes into ordinary write errors.
    var mask = sigset_t()
    var previous = sigset_t()
    sigemptyset(&mask)
    sigaddset(&mask, SIGPIPE)
    pthread_sigmask(SIG_BLOCK, &mask, &previous)
    defer {
      var pending = sigset_t()
      sigpending(&pending)
      if sigismember(&pending, SIGPIPE) == 1 {
        var number: Int32 = 0
        sigwait(&mask, &number)
      }
      pthread_sigmask(SIG_SETMASK, &previous, nil)
    }
    let connection = BridgeConnection(fd: fd)
    defer {
      state.withLock { _ = $0.connections.remove(fd) }
      withExtendedLifetime(connection) {}
    }
    do {
      let request = try connection.readLaunch()
      guard request.version == 1, request.token == manifest.token,
        let mapping = mappings[request.mapping]
      else {
        throw BridgeError("Unauthorized host bridge launch")
      }
      guard !request.arguments.contains(where: { $0.contains("\0") }),
        mapping.forwardArguments != false || request.arguments.isEmpty
      else {
        throw BridgeError("Host bridge arguments are not permitted")
      }
      let environment = try Self.environment(for: request, mapping: mapping, host: hostEnvironment)
      let process = try HostBridgeProcess(
        command: mapping.hostCommand, arguments: (mapping.arguments ?? []) + request.arguments,
        environment: environment, cwd: workspace)
      try process.relay(connection)
    } catch {
      // No environment values or stream payloads are included in diagnostics.
      try? connection.enqueue(.init(.failure, Data(String(describing: error).utf8)))
      try? connection.flush()
    }
  }
}
