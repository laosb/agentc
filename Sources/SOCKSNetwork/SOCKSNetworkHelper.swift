#if os(macOS)
  import AgentIsolation
  import Darwin
  import Foundation
  import Synchronization

  /// Owns the host networking child and its sockets. This is process separation,
  /// not a macOS sandbox. The child has the same host privileges as agentc.
  public final class SOCKSNetworkHelper: Sendable {
    public static let privateArgument = "--agentc-socks-network-v1"
    private static let lifecycleQueue = DispatchQueue(
      label: "agentc.socks-network.lifecycle", attributes: .concurrent)

    // Foundation Process is only accessed while holding `state`'s lock.
    private struct State: @unchecked Sendable {
      var process: Process?
      var packet: FileHandle?
      var control: FileHandle?
    }

    private let state: Mutex<State>

    private init(process: Process, packet: FileHandle, control: FileHandle) {
      state = Mutex(State(process: process, packet: packet, control: control))
    }

    /// Async runtime entrypoint. Process startup and socket readiness use blocking
    /// system calls, so keep them off Swift's cooperative executor.
    public static func launch(
      proxy: SOCKS5Proxy,
      hostMCPPort: UInt16? = nil,
      executableURL: URL? = nil,
      startupTimeout: TimeInterval = 10
    ) async throws -> SOCKSNetworkHelper {
      try Task.checkCancellation()
      let helper = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<SOCKSNetworkHelper, any Error>) in
        lifecycleQueue.async {
          continuation.resume(
            with: Result {
              try start(
                proxy: proxy, hostMCPPort: hostMCPPort, executableURL: executableURL,
                startupTimeout: startupTimeout)
            })
        }
      }
      // Cancellation cannot interrupt Process.run(), but the readiness deadline
      // bounds it. Never hand a child to a caller that has already cancelled.
      if Task.isCancelled {
        await helper.stopAsync()
        throw CancellationError()
      }
      return helper
    }

    /// Starts the exact current executable, not a command found through PATH.
    /// Credentials travel only through the private control socket. An explicit
    /// executable URL is useful for embedders that provide the private entrypoint.
    public static func start(
      proxy: SOCKS5Proxy,
      hostMCPPort: UInt16? = nil,
      executableURL: URL? = nil,
      startupTimeout: TimeInterval = 10
    ) throws -> SOCKSNetworkHelper {
      guard startupTimeout.isFinite, startupTimeout > 0, startupTimeout <= 60 else {
        throw HelperError.invalidConfiguration
      }
      let configuration = Configuration(proxy: proxy, hostMCPPort: hostMCPPort)
      try configuration.validate()
      let frame = try configuration.frame()
      guard let executable = executableURL ?? Bundle.main.executableURL,
        executable.isFileURL, executable.path.hasPrefix("/")
      else {
        throw HelperError.executableUnavailable
      }

      let (packetParent, packetChild) = try socketPair(type: SOCK_DGRAM)
      defer { try? packetChild.close() }
      let controlParent: FileHandle
      let controlChild: FileHandle
      do {
        (controlParent, controlChild) = try socketPair(type: SOCK_STREAM)
      } catch {
        try? packetParent.close()
        throw error
      }
      defer { try? controlChild.close() }

      let process = Process()
      process.executableURL = executable
      process.arguments = [privateArgument]
      // No proxy credentials, DYLD injection, logging settings, or unrelated
      // user environment reaches this private mode. It needs no environment.
      process.environment = [:]
      process.currentDirectoryURL = URL(fileURLWithPath: "/")
      process.standardInput = packetChild
      process.standardOutput = controlChild
      process.standardError = FileHandle.standardError
      let helper = SOCKSNetworkHelper(
        process: process, packet: packetParent, control: controlParent)
      do {
        try process.run()
        // Close these immediately: keeping a duplicate child control endpoint
        // here would prevent us from seeing EOF when startup fails.
        try packetChild.close()
        try controlChild.close()
        let deadline =
          DispatchTime.now().uptimeNanoseconds
          + UInt64(startupTimeout * 1_000_000_000)
        try transfer(frame, to: controlParent.fileDescriptor, deadline: deadline)
        let ready = try receive(
          count: 1, from: controlParent.fileDescriptor, deadline: deadline)
        guard ready == Data([1]) else { throw HelperError.invalidHandshake }
        return helper
      } catch {
        helper.stop()
        // Do not forward Process errors: callers must not log credentials or
        // private configuration as part of a diagnostic.
        throw (error as? HelperError) ?? HelperError.startFailed
      }
    }

    /// Borrows the packet endpoint while constructing a VZ attachment. The
    /// caller must neither close it nor retain it independently of this helper.
    /// The lock prevents stop() from closing it during attachment construction.
    public func withPacketFileHandle<T>(_ body: (FileHandle) throws -> T) throws -> T {
      try state.withLock { state in
        guard let packet = state.packet else { throw HelperError.stopped }
        return try body(packet)
      }
    }

    /// Preferred from async teardown paths; escalation/reaping cannot occupy a
    /// cooperative worker while other sessions are trying to stop their VMs.
    public func stopAsync() async {
      await withCheckedContinuation { continuation in
        Self.lifecycleQueue.async {
          self.stop()
          continuation.resume()
        }
      }
    }

    /// Idempotent and serialized, including concurrent stop/deinit paths.
    /// Closing control requests normal engine shutdown; escalation bounds the
    /// lifetime even if a faulty child stops servicing its control socket.
    public func stop() {
      state.withLock { state in
        try? state.control?.close()
        state.control = nil
        try? state.packet?.close()
        state.packet = nil
        if let process = state.process, process.isRunning {
          Self.waitForExit(process, milliseconds: 250)
          if process.isRunning {
            process.terminate()
            Self.waitForExit(process, milliseconds: 250)
          }
          if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
          }
          process.waitUntilExit()
        }
        state.process = nil
      }
    }

    deinit { stop() }

    /// Called before ArgumentParser, logging, migration, or session bootstrap.
    /// `nil` means this was not a private-mode invocation. Errors are deliberately
    /// generic: decoded credentials and engine error payloads never reach stderr.
    public static func runPrivateMode(
      arguments: [String] = CommandLine.arguments
    ) async -> Int32? {
      guard arguments.dropFirst().first == privateArgument else { return nil }
      guard arguments.count == 2 else { return 64 }
      defer {
        _ = Darwin.close(STDIN_FILENO)
        _ = Darwin.close(STDOUT_FILENO)
      }
      do {
        try validateSocket(STDIN_FILENO, type: SOCK_DGRAM)
        try validateSocket(STDOUT_FILENO, type: SOCK_STREAM)
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        let header = try receive(count: 4, from: STDOUT_FILENO, deadline: deadline)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= Configuration.maximumBytes else {
          throw HelperError.invalidConfiguration
        }
        let payload = try receive(
          count: Int(length), from: STDOUT_FILENO, deadline: deadline)
        let configuration = try JSONDecoder().decode(Configuration.self, from: payload)
        try configuration.validate()
        // CLOEXEC on the inherited endpoints also prevents future execs in the
        // child from accidentally retaining the parent-death channel.
        try configureSocket(STDIN_FILENO)
        try configureSocket(STDOUT_FILENO)
        try await SOCKSNetworkEngine.run(
          proxy: configuration.proxy, packetFD: STDIN_FILENO,
          controlFD: STDOUT_FILENO, hostMCPPort: configuration.hostMCPPort)
        return 0
      } catch {
        try? FileHandle.standardError.write(
          contentsOf: Data("agentc: private SOCKS network helper failed\n".utf8))
        return 1
      }
    }

    struct Configuration: Codable {
      static let maximumBytes: UInt32 = 16_384
      let version: Int
      let proxy: SOCKS5Proxy
      let hostMCPPort: UInt16?

      init(proxy: SOCKS5Proxy, hostMCPPort: UInt16?) {
        version = 1
        self.proxy = proxy
        self.hostMCPPort = hostMCPPort
      }

      func validate() throws {
        // Codable bypasses SOCKS5Proxy's URL initializer; validate the wire
        // representation again before passing it to the networking engine.
        guard version == 1, !proxy.host.isEmpty, proxy.host.utf8.count <= 1024,
          !proxy.host.contains("\0"), proxy.port != 0, hostMCPPort != 0,
          (proxy.username == nil) == (proxy.password == nil),
          [proxy.username, proxy.password].compactMap({ $0 }).allSatisfy({
            (1...255).contains($0.utf8.count) && !$0.contains("\0")
          })
        else { throw HelperError.invalidConfiguration }
        // Use the same strict numeric endpoint rule as CLI and decoding; never
        // accept a DNS hostname that would trigger a host resolver lookup.
        guard let dns = try? SOCKS5DNS(url: "tcp://\(proxy.dns.host):\(proxy.dns.port)"),
          dns == proxy.dns
        else { throw HelperError.invalidConfiguration }
      }

      func frame() throws -> Data {
        let payload = try JSONEncoder().encode(self)
        guard !payload.isEmpty, payload.count <= Self.maximumBytes else {
          throw HelperError.invalidConfiguration
        }
        let length = UInt32(payload.count)
        return Data([
          UInt8(truncatingIfNeeded: length >> 24),
          UInt8(truncatingIfNeeded: length >> 16),
          UInt8(truncatingIfNeeded: length >> 8),
          UInt8(truncatingIfNeeded: length),
        ]) + payload
      }
    }

    public enum HelperError: Error, LocalizedError {
      case invalidConfiguration, executableUnavailable, startFailed, invalidHandshake
      case socketFailure, timedOut, stopped

      public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Invalid private SOCKS networking configuration."
        case .executableUnavailable: "Cannot locate the current agentc executable."
        case .startFailed: "Could not start the private SOCKS networking child."
        case .invalidHandshake: "The private SOCKS networking child did not become ready."
        case .socketFailure: "The private SOCKS networking socket failed."
        case .timedOut: "Timed out starting the private SOCKS networking child."
        case .stopped: "The private SOCKS networking child has stopped."
        }
      }
    }

    private static func socketPair(type: Int32) throws -> (FileHandle, FileHandle) {
      var descriptors: [Int32] = [-1, -1]
      guard socketpair(AF_UNIX, type, 0, &descriptors) == 0 else {
        throw HelperError.socketFailure
      }
      do {
        for fd in descriptors { try configureSocket(fd) }
      } catch {
        for fd in descriptors { _ = Darwin.close(fd) }
        throw error
      }
      return (
        FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
        FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
      )
    }

    private static func configureSocket(_ fd: Int32) throws {
      var one: Int32 = 1
      guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
          == 0
      else { throw HelperError.socketFailure }
    }

    private static func validateSocket(_ fd: Int32, type: Int32) throws {
      var actual: Int32 = 0
      var size = socklen_t(MemoryLayout.size(ofValue: actual))
      var address = sockaddr_un()
      var addressSize = socklen_t(MemoryLayout.size(ofValue: address))
      let result = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          getpeername(fd, $0, &addressSize)
        }
      }
      guard getsockopt(fd, SOL_SOCKET, SO_TYPE, &actual, &size) == 0,
        actual == type, result == 0, address.sun_family == AF_UNIX
      else { throw HelperError.invalidHandshake }
    }

    private static func waitForExit(_ process: Process, milliseconds: Int) {
      let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(milliseconds) * 1_000_000
      while process.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
        usleep(10_000)
      }
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: UInt64) throws {
      while true {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw HelperError.timedOut }
        let remaining = Int32(min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max)))
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&descriptor, 1, remaining)
        if result < 0, errno == EINTR { continue }
        guard result >= 0 else { throw HelperError.socketFailure }
        guard result != 0 else { throw HelperError.timedOut }
        guard descriptor.revents & events != 0 else { throw HelperError.invalidHandshake }
        return
      }
    }

    private static func transfer(_ data: Data, to fd: Int32, deadline: UInt64) throws {
      try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          try wait(fd, events: Int16(POLLOUT), deadline: deadline)
          let count = send(
            fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, MSG_DONTWAIT)
          if count < 0, errno == EINTR || errno == EAGAIN { continue }
          guard count > 0 else { throw HelperError.socketFailure }
          offset += count
        }
      }
    }

    private static func receive(count: Int, from fd: Int32, deadline: UInt64) throws -> Data {
      var data = Data(count: count)
      try data.withUnsafeMutableBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          try wait(fd, events: Int16(POLLIN), deadline: deadline)
          let received = recv(
            fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, MSG_DONTWAIT)
          if received < 0, errno == EINTR || errno == EAGAIN { continue }
          guard received > 0 else { throw HelperError.invalidHandshake }
          offset += received
        }
      }
      return data
    }
  }
#endif
