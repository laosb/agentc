import AgentIsolation
import Synchronization

#if canImport(FoundationEssentials)
  import FoundationEssentials
  import Dispatch
#else
  import Foundation
#endif

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

// On Glibc, SOCK_STREAM is an enum (__socket_type), not Int32.
// On Darwin and Musl it is already Int32.
#if canImport(Glibc)
  private let _SOCK_STREAM = Int32(SOCK_STREAM.rawValue)
#else
  private let _SOCK_STREAM = SOCK_STREAM
#endif

/// Mutable state protected by a Mutex inside `DockerStreamAttach`.
/// Marked @unchecked Sendable because DispatchSource predates Swift concurrency;
/// all access is serialized through the enclosing Mutex.
private struct AttachState: ~Copyable, @unchecked Sendable {
  var readSource: DispatchSourceRead?
  var writeSource: DispatchSourceRead?
  var writerTask: Task<Void, Never>?
  var demuxBuffer = Data()
  var isReadDone = false
  var readDoneContinuation: CheckedContinuation<Void, Never>?
}

/// Handles bidirectional I/O with a Docker container via the attach API.
///
/// Uses a raw socket connection (Unix domain or TCP) with HTTP upgrade
/// to establish a streaming connection for stdin/stdout/stderr.
final class DockerStreamAttach: Sendable {
  private let fd: Int32
  private let tty: Bool
  private let state = Mutex(AttachState())

  private init(fd: Int32, tty: Bool) {
    self.fd = fd
    self.tty = tty
  }

  deinit {
    stop()
  }

  // MARK: - Connect

  /// Connect to the Docker socket and attach to a container.
  static func attach(
    endpoint: String,
    containerId: String,
    tty: Bool
  ) throws -> DockerStreamAttach {
    let fd: Int32

    if endpoint.hasPrefix("/") || endpoint.hasPrefix("unix://") {
      let path = endpoint.hasPrefix("unix://") ? String(endpoint.dropFirst(7)) : endpoint
      fd = try connectUnixSocket(path: path)
    } else {
      let (host, port) = parseTCPEndpoint(endpoint)
      fd = try connectTCPSocket(host: host, port: port)
    }

    let attach = DockerStreamAttach(fd: fd, tty: tty)
    try attach.sendAttachRequest(containerId: containerId)
    try attach.readUpgradeResponse()
    return attach
  }

  // MARK: - I/O

  /// Start bidirectional I/O between the socket and file descriptors.
  func startIO(stdin stdinFD: FileDescriptor, stdout stdoutFD: FileDescriptor, stderr stderrFD: FileDescriptor)
  {
    // Socket -> stdout/stderr
    let socketReadSource = DispatchSource.makeReadSource(
      fileDescriptor: fd, queue: DispatchQueue.global(qos: .userInteractive))
    socketReadSource.setEventHandler { [weak self] in
      guard let self = self else { return }
      var buffer = [UInt8](repeating: 0, count: 32768)
      let bytesRead = read(self.fd, &buffer, buffer.count)
      if bytesRead <= 0 {
        socketReadSource.cancel()
        return
      }
      let data = Data(buffer[0..<bytesRead])
      if self.tty {
        data.withUnsafeBytes { _ = try? stdoutFD.write($0) }
      } else {
        self.demuxWrite(data, stdout: stdoutFD, stderr: stderrFD)
      }
    }
    socketReadSource.setCancelHandler { [weak self] in
      guard let self = self else { return }
      self.state.withLock { state in
        state.readSource = nil
        if !state.isReadDone {
          state.isReadDone = true
          state.readDoneContinuation?.resume()
          state.readDoneContinuation = nil
        }
      }
    }
    self.state.withLock { $0.readSource = socketReadSource }
    socketReadSource.resume()

    // stdin -> socket
    let stdinReadSource = DispatchSource.makeReadSource(
      fileDescriptor: stdinFD.rawValue,
      queue: DispatchQueue.global(qos: .userInteractive))
    stdinReadSource.setEventHandler { [weak self] in
      guard let self = self else { return }
      var buffer = [UInt8](repeating: 0, count: 4096)
      let bytesRead = read(stdinFD.rawValue, &buffer, buffer.count)
      if bytesRead <= 0 {
        stdinReadSource.cancel()
        return
      }
      _ = buffer.withUnsafeBufferPointer { ptr in
        write(self.fd, ptr.baseAddress!, bytesRead)
      }
    }
    stdinReadSource.setCancelHandler { [weak self] in
      guard let self = self else { return }
      self.state.withLock { $0.writeSource = nil }
    }
    self.state.withLock { $0.writeSource = stdinReadSource }
    stdinReadSource.resume()
  }

  /// Wait for the socket read stream to finish (EOF or cancellation).
  ///
  /// Call after the container has exited to ensure all output has been
  /// forwarded to stdout/stderr before the process exits.
  func waitForReadCompletion() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let done = self.state.withLock { state -> Bool in
        if state.isReadDone { return true }
        state.readDoneContinuation = continuation
        return false
      }
      if done { continuation.resume() }
    }
  }

  /// Stop the I/O and close the socket.
  func stop() {
    state.withLock { state in
      state.readSource?.cancel()
      state.readSource = nil
      state.writeSource?.cancel()
      state.writeSource = nil
      state.writerTask?.cancel()
      state.writerTask = nil
      if !state.isReadDone {
        state.isReadDone = true
        state.readDoneContinuation?.resume()
        state.readDoneContinuation = nil
      }
    }
    close(fd)
  }

  /// Start bidirectional I/O between the socket and custom Reader/Writer streams.
  ///
  /// Unlike ``startIO(stdin:stdout:stderr:)``, this method accepts protocol-based
  /// streams instead of `FileDescriptor` values, allowing callers to capture or
  /// transform container output.
  func startCustomIO(stdin: any ReaderStream, stdout: any Writer, stderr: any Writer) {
    // Socket → Writers
    let socketReadSource = DispatchSource.makeReadSource(
      fileDescriptor: fd, queue: DispatchQueue.global(qos: .userInteractive))
    socketReadSource.setEventHandler { [weak self] in
      guard let self = self else { return }
      var buffer = [UInt8](repeating: 0, count: 32768)
      let bytesRead = read(self.fd, &buffer, buffer.count)
      if bytesRead <= 0 {
        socketReadSource.cancel()
        return
      }
      let data = Data(buffer[0..<bytesRead])
      if self.tty {
        try? stdout.write(data)
      } else {
        self.demuxWriteToWriters(data, stdout: stdout, stderr: stderr)
      }
    }
    socketReadSource.setCancelHandler { [weak self] in
      guard let self = self else { return }
      self.state.withLock { state in
        state.readSource = nil
        if !state.isReadDone {
          state.isReadDone = true
          state.readDoneContinuation?.resume()
          state.readDoneContinuation = nil
        }
      }
    }
    self.state.withLock { $0.readSource = socketReadSource }
    socketReadSource.resume()

    // ReaderStream → socket
    let socketFd = self.fd
    let stdinStream = stdin.stream()
    let writerTask = Task {
      for await data in stdinStream {
        guard !Task.isCancelled else { break }
        guard !data.isEmpty else { continue }
        let bytes = [UInt8](data)
        _ = bytes.withUnsafeBufferPointer { ptr in
          write(socketFd, ptr.baseAddress!, bytes.count)
        }
      }
    }
    self.state.withLock { $0.writerTask = writerTask }
  }

  // MARK: - Multiplexed Stream Demuxing

  /// Process multiplexed Docker stream data (non-TTY mode).
  ///
  /// Each frame has an 8-byte header: [type:1][padding:3][size:4_be]
  /// Type: 0=stdin, 1=stdout, 2=stderr
  private func demuxWrite(_ data: Data, stdout: FileDescriptor, stderr: FileDescriptor) {
    state.withLock { state in
      state.demuxBuffer.append(data)

      while state.demuxBuffer.count >= 8 {
        let streamType = state.demuxBuffer[0]
        let size =
          Int(state.demuxBuffer[4]) << 24 | Int(state.demuxBuffer[5]) << 16
          | Int(state.demuxBuffer[6]) << 8 | Int(state.demuxBuffer[7])

        guard state.demuxBuffer.count >= 8 + size else { break }

        let payload = state.demuxBuffer[8..<(8 + size)]
        switch streamType {
        case 1:
          Data(payload).withUnsafeBytes { _ = try? stdout.write($0) }
        case 2:
          Data(payload).withUnsafeBytes { _ = try? stderr.write($0) }
        default:
          break
        }

        state.demuxBuffer = Data(state.demuxBuffer[(8 + size)...])
      }
    }
  }

  /// Process multiplexed Docker stream data, routing payloads to custom `Writer` instances.
  private func demuxWriteToWriters(_ data: Data, stdout: any Writer, stderr: any Writer) {
    state.withLock { state in
      state.demuxBuffer.append(data)

      while state.demuxBuffer.count >= 8 {
        let streamType = state.demuxBuffer[0]
        let size =
          Int(state.demuxBuffer[4]) << 24 | Int(state.demuxBuffer[5]) << 16
          | Int(state.demuxBuffer[6]) << 8 | Int(state.demuxBuffer[7])

        guard state.demuxBuffer.count >= 8 + size else { break }

        let payload = state.demuxBuffer[8..<(8 + size)]
        switch streamType {
        case 1:
          try? stdout.write(Data(payload))
        case 2:
          try? stderr.write(Data(payload))
        default:
          break
        }

        state.demuxBuffer = Data(state.demuxBuffer[(8 + size)...])
      }
    }
  }

  // MARK: - HTTP Upgrade

  private func sendAttachRequest(containerId: String) throws {
    let request =
      "POST /v1.44/containers/\(containerId)/attach?stream=1&stdout=1&stderr=1&stdin=1 HTTP/1.1\r\n"
      + "Host: localhost\r\n"
      + "Upgrade: tcp\r\n"
      + "Connection: Upgrade\r\n"
      + "\r\n"

    let bytes = Array(request.utf8)
    var totalWritten = 0
    while totalWritten < bytes.count {
      let written = bytes.withUnsafeBufferPointer { ptr in
        write(fd, ptr.baseAddress! + totalWritten, bytes.count - totalWritten)
      }
      guard written > 0 else {
        throw DockerRuntimeError.attachFailed("Failed to send attach request")
      }
      totalWritten += written
    }
  }

  private func readUpgradeResponse() throws {
    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]  // \r\n\r\n

    // Read until we see the end of HTTP headers (\r\n\r\n)
    while true {
      let bytesRead = read(fd, &buffer, buffer.count)
      guard bytesRead > 0 else {
        throw DockerRuntimeError.attachFailed("Connection closed during upgrade")
      }
      responseData.append(contentsOf: buffer[0..<bytesRead])

      // Search for \r\n\r\n in the raw bytes to find the header/body boundary.
      // We must NOT use String.distance here because Swift counts \r\n as one
      // Character (grapheme cluster), which would give a wrong byte offset.
      guard let sepRange = responseData.range(of: Data(separator)) else { continue }
      let headerEnd = sepRange.upperBound

      if let str = String(data: responseData[..<headerEnd], encoding: .utf8) {
        guard str.contains("101") else {
          throw DockerRuntimeError.attachFailed(
            "Expected 101 Switching Protocols, got: \(str.prefix(200))")
        }
      }

      // Any data after the headers is already stream data — push it into the demux buffer
      if responseData.count > headerEnd {
        state.withLock { $0.demuxBuffer.append(responseData[headerEnd...]) }
      }
      return
    }
  }

  // MARK: - Socket Connection

  private static func connectUnixSocket(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, _SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw DockerRuntimeError.socketError("Failed to create Unix socket: \(errnoString)")
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count <= maxLen else {
      close(fd)
      throw DockerRuntimeError.socketError("Socket path too long: \(path)")
    }
    _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
      pathBytes.withUnsafeBufferPointer { buf in
        memcpy(ptr, buf.baseAddress!, buf.count)
      }
    }

    let result = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let err = errnoString
      close(fd)
      throw DockerRuntimeError.socketError(
        "Failed to connect to Unix socket \(path): \(err)")
    }
    return fd
  }

  private static func connectTCPSocket(host: String, port: Int) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = _SOCK_STREAM

    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &result)
    guard status == 0, let addrInfo = result else {
      throw DockerRuntimeError.socketError(
        "Failed to resolve \(host):\(port): \(String(cString: gai_strerror(status)))")
    }
    defer { freeaddrinfo(addrInfo) }

    let fd = socket(addrInfo.pointee.ai_family, addrInfo.pointee.ai_socktype, 0)
    guard fd >= 0 else {
      throw DockerRuntimeError.socketError("Failed to create TCP socket: \(errnoString)")
    }

    guard connect(fd, addrInfo.pointee.ai_addr, addrInfo.pointee.ai_addrlen) == 0 else {
      let err = errnoString
      close(fd)
      throw DockerRuntimeError.socketError(
        "Failed to connect to \(host):\(port): \(err)")
    }
    return fd
  }

  private static func parseTCPEndpoint(_ endpoint: String) -> (host: String, port: Int) {
    var cleaned = endpoint
    for prefix in ["tcp://", "http://", "https://"] {
      if cleaned.hasPrefix(prefix) {
        cleaned = String(cleaned.dropFirst(prefix.count))
        break
      }
    }
    let parts = cleaned.split(separator: ":", maxSplits: 1)
    let host = String(parts[0])
    let port = parts.count > 1 ? Int(parts[1]) ?? 2375 : 2375
    return (host, port)
  }

  private static var errnoString: String {
    String(cString: strerror(errno))
  }
}

// MARK: - Terminal Utilities

/// Saves and restores terminal state for raw mode.
struct DockerTerminalState {
  #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    private var original: termios

    /// Set terminal to raw mode, returning the previous state for restoration.
    static func setRaw() -> DockerTerminalState? {
      var original = termios()
      guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
      var raw = original
      cfmakeraw(&raw)
      guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return nil }
      return DockerTerminalState(original: original)
    }

    /// Restore the terminal to its original state.
    func restore() {
      var t = original
      tcsetattr(STDIN_FILENO, TCSANOW, &t)
    }
  #endif
}

/// Get the current terminal window size.
func dockerTerminalSize() -> (width: Int, height: Int)? {
  #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    var ws = winsize()
    guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0 else { return nil }
    return (Int(ws.ws_col), Int(ws.ws_row))
  #else
    return nil
  #endif
}
