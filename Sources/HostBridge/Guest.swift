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

// Only used in the single-threaded guest proxy. The handler performs one
// async-signal-safe, nonblocking write; no Swift allocations or locks.
nonisolated(unsafe) private var signalPipe: Int32 = -1
private func bridgeSignal(_ number: Int32) {
  let saved = errno
  var byte = UInt8(number)
  _ = write(signalPipe, &byte, 1)
  errno = saved
}

public enum GuestBridge {
  public static let invocationFlag = "--agentc-host-bridge"

  /// Runs before the bootstrap's ordinary setup or privilege drop.
  public static func invoke(mapping: String, arguments: [String]) -> Never {
    do {
      let manifest = try JSONDecoder().decode(
        BridgeManifest.self, from: Data(contentsOf: URL(fileURLWithPath: BridgeManifest.filePath)))
      guard let entry = manifest.entries.first(where: { $0.id == mapping }) else {
        throw BridgeError("Unknown host bridge mapping")
      }
      // Read only named variables, including values changed by the caller since
      // container startup. The broker independently enforces this same policy.
      var environment: [String: String] = [:]
      for name in entry.forwardEnvironment {
        if let value = getenv(name) { environment[name] = String(cString: value) }
      }
      let result = try relay(
        socketPath: BridgeManifest.socketPath,
        launch: .init(
          token: manifest.token, mapping: mapping, arguments: arguments, environment: environment))
      if let name = result.signal,
        let number = BridgePOSIX.signals.first(where: { $0.0 == name })?.1
      {
        signal(number, SIG_DFL)
        var mask = sigset_t()
        sigemptyset(&mask)
        sigaddset(&mask, number)
        sigprocmask(SIG_UNBLOCK, &mask, nil)
        raise(number)
      }
      exit(result.code)
    } catch {
      var message = Data("agentc host bridge: \(error)\n".utf8)
      try? BridgePOSIX.write(STDERR_FILENO, buffer: &message)
      exit(125)
    }
  }

  /// Intentionally synchronous: one small poll loop, no networking framework,
  /// process library, threads, or unbounded asynchronous queues in the guest.
  public static func relay(
    socketPath: String, launch: BridgeLaunch,
    stdinFD: Int32 = STDIN_FILENO, stdoutFD: Int32 = STDOUT_FILENO,
    stderrFD: Int32 = STDERR_FILENO, forwardSignals: Bool = true
  ) throws -> BridgeTermination {
    let signals = try BridgePOSIX.pipe()
    defer {
      close(signals.read)
      close(signals.write)
    }
    try BridgePOSIX.nonblocking(signals.read)
    try BridgePOSIX.nonblocking(signals.write)
    if forwardSignals { signalPipe = signals.write }
    let forwarded: [Int32] =
      forwardSignals ? [SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGUSR1, SIGUSR2, SIGALRM] : []
    let previous = forwarded.map { signal($0, bridgeSignal) }
    let previousPipe = forwardSignals ? signal(SIGPIPE, SIG_IGN) : nil
    defer {
      for (number, handler) in zip(forwarded, previous) { signal(number, handler) }
      if forwardSignals {
        signal(SIGPIPE, previousPipe)
        signalPipe = -1
      }
    }
    let connection = BridgeConnection(
      fd: try BridgePOSIX.socket(path: socketPath, listening: false))
    try connection.enqueue(.init(.launch, JSONEncoder().encode(launch)))
    var stdout = Data()
    var stderr = Data()
    var stdinReady = false
    var stdinEnded = false
    var termination: BridgeTermination?
    let handshakeDeadline = ContinuousClock.now + .seconds(10)
    var connected = false

    while termination == nil || !stdout.isEmpty || !stderr.isEmpty {
      if !connected && ContinuousClock.now >= handshakeDeadline {
        throw BridgeError("Host bridge handshake timed out")
      }
      let canReceive = termination == nil && stdout.count + stderr.count < 64 * 1024
      var fds = [
        pollfd(
          fd: termination == nil ? connection.fd : -1,
          events: (canReceive ? Int16(POLLIN) : 0)
            | (connection.output.isEmpty ? 0 : Int16(POLLOUT)),
          revents: 0),
        pollfd(fd: stdinReady && !stdinEnded ? stdinFD : -1, events: Int16(POLLIN), revents: 0),
        pollfd(fd: stdout.isEmpty ? -1 : stdoutFD, events: Int16(POLLOUT), revents: 0),
        pollfd(fd: stderr.isEmpty ? -1 : stderrFD, events: Int16(POLLOUT), revents: 0),
        // Do not send control frames until launch has been acknowledged.
        pollfd(fd: connected ? signals.read : -1, events: Int16(POLLIN), revents: 0),
      ]
      try BridgePOSIX.poll(&fds)
      if termination == nil, fds[4].revents != 0, let bytes = try BridgePOSIX.read(signals.read) {
        for byte in bytes {
          if let name = BridgePOSIX.signals.first(where: { $0.1 == Int32(byte) })?.0 {
            // Bound queued control traffic even if the host stops reading.
            guard connection.output.count < BridgeFrame.launchLimit + 65536 else {
              throw BridgeError("Host bridge signal queue is full")
            }
            try connection.enqueue(.init(.signal, Data(name.utf8)))
          }
        }
      }
      if fds[1].revents != 0, let data = try BridgePOSIX.read(stdinFD) {
        stdinReady = false
        stdinEnded = data.isEmpty
        try connection.enqueue(.init(data.isEmpty ? .stdinEOF : .stdin, data))
      }
      // Writes no larger than POSIX's minimum PIPE_BUF after POLLOUT. Do not
      // change O_NONBLOCK on inherited stdio: those flags are shared with the caller.
      if fds[2].revents != 0 { try BridgePOSIX.write(stdoutFD, buffer: &stdout, limit: 512) }
      if fds[3].revents != 0 { try BridgePOSIX.write(stderrFD, buffer: &stderr, limit: 512) }
      if fds[0].revents & Int16(POLLOUT) != 0 { try connection.flush() }
      if canReceive && fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
        for frame in try connection.receive() {
          guard termination == nil else { throw BridgeError("Data after host termination") }
          switch frame.kind {
          case .stdinReady:
            guard frame.data.isEmpty, !stdinReady, !stdinEnded else {
              throw BridgeError("Unexpected host bridge stdin credit")
            }
            connected = true
            stdinReady = true
          case .stdout: stdout.append(frame.data)
          case .stderr: stderr.append(frame.data)
          case .exit:
            termination = try JSONDecoder().decode(BridgeTermination.self, from: frame.data)
            stdinReady = false
            stdinEnded = true
            connection.output.removeAll()
          case .failure:
            throw BridgeError(String(decoding: frame.data, as: UTF8.self))
          default: throw BridgeError("Unexpected host bridge response")
          }
        }
      }
    }
    return termination!
  }

  /// Install only new paths on the image filesystem. Never write wrappers into
  /// host-backed mounts, overwrite an image binary, or follow a destination symlink.
  public static func installIfPresent() throws {
    guard getenv("AGENTC_HOST_BRIDGE") != nil else { return }
    let manifest = try JSONDecoder().decode(
      BridgeManifest.self, from: Data(contentsOf: URL(fileURLWithPath: BridgeManifest.filePath)))
    let mountInfo = try String(
      decoding: Data(contentsOf: URL(fileURLWithPath: "/proc/self/mountinfo")), as: UTF8.self)
    let mountPoints = mountInfo.split(separator: "\n").compactMap { line -> String? in
      let fields = line.split(separator: " ")
      guard fields.count > 4 else { return nil }
      return String(fields[4]).replacing("\\040", with: " ")
        .replacing("\\011", with: "\t")
        .replacing("\\012", with: "\n")
        .replacing("\\134", with: "\\")
    }.filter { $0 != "/" }
    var root = stat()
    guard stat("/", &root) == 0 else { throw BridgePOSIX.error("stat root") }
    for entry in manifest.entries {
      let destination = URL(fileURLWithPath: entry.path)
      var ancestor = destination.deletingLastPathComponent()
      while !FileManager.default.fileExists(atPath: ancestor.path) {
        ancestor.deleteLastPathComponent()
      }
      let resolved = ancestor.resolvingSymlinksInPath().path
      var info = stat()
      guard stat(ancestor.path, &info) == 0, info.st_dev == root.st_dev,
        !mountPoints.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") })
      else {
        throw BridgeError(
          "Host bridge paths must be on the container image filesystem: \(entry.path)")
      }
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      let fd = open(entry.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o755)
      guard fd >= 0 else {
        throw BridgeError(
          "Cannot create host bridge path (existing files are never replaced): \(entry.path)")
      }
      do {
        // IDs are host-generated UUIDs, not shell input. No host command or token
        // appears in the wrapper or its arguments.
        guard UUID(uuidString: entry.id) != nil else {
          throw BridgeError("Invalid bridge mapping ID")
        }
        var script = Data(
          "#!/bin/sh\nexec /entrypoint-bootstrap/bootstrap \(invocationFlag) \(entry.id) \"$@\"\n"
            .utf8)
        while !script.isEmpty { try BridgePOSIX.write(fd, buffer: &script) }
        close(fd)
      } catch {
        close(fd)
        throw error
      }
    }
  }
}
