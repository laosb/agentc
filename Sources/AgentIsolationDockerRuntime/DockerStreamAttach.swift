#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif
import Foundation

// On Linux (Glibc/Musl), SOCK_STREAM is an enum (__socket_type), not Int32.
#if canImport(Darwin)
  private let _SOCK_STREAM = SOCK_STREAM
#else
  private let _SOCK_STREAM = Int32(SOCK_STREAM.rawValue)
#endif

/// Handles bidirectional I/O with a Docker container via the attach API.
///
/// Uses a raw socket connection (Unix domain or TCP) with HTTP upgrade
/// to establish a streaming connection for stdin/stdout/stderr.
final class DockerStreamAttach: @unchecked Sendable {
  private let fd: Int32
  private let tty: Bool
  private var readSource: DispatchSourceRead?
  private var writeSource: DispatchSourceRead?
  private var demuxBuffer = Data()
  private let lock = NSLock()

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

  /// Start bidirectional I/O between the socket and file handles.
  func startIO(stdin stdinFH: FileHandle, stdout stdoutFH: FileHandle, stderr stderrFH: FileHandle)
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
        stdoutFH.write(data)
      } else {
        self.demuxWrite(data, stdout: stdoutFH, stderr: stderrFH)
      }
    }
    socketReadSource.setCancelHandler { [weak self] in
      guard let self = self else { return }
      self.lock.lock()
      self.readSource = nil
      self.lock.unlock()
    }
    self.readSource = socketReadSource
    socketReadSource.resume()

    // stdin -> socket
    let stdinReadSource = DispatchSource.makeReadSource(
      fileDescriptor: stdinFH.fileDescriptor,
      queue: DispatchQueue.global(qos: .userInteractive))
    stdinReadSource.setEventHandler { [weak self] in
      guard let self = self else { return }
      var buffer = [UInt8](repeating: 0, count: 4096)
      let bytesRead = read(stdinFH.fileDescriptor, &buffer, buffer.count)
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
      self.lock.lock()
      self.writeSource = nil
      self.lock.unlock()
    }
    self.writeSource = stdinReadSource
    stdinReadSource.resume()
  }

  /// Stop the I/O and close the socket.
  func stop() {
    lock.lock()
    readSource?.cancel()
    readSource = nil
    writeSource?.cancel()
    writeSource = nil
    lock.unlock()
    close(fd)
  }

  // MARK: - Multiplexed Stream Demuxing

  /// Process multiplexed Docker stream data (non-TTY mode).
  ///
  /// Each frame has an 8-byte header: [type:1][padding:3][size:4_be]
  /// Type: 0=stdin, 1=stdout, 2=stderr
  private func demuxWrite(_ data: Data, stdout: FileHandle, stderr: FileHandle) {
    lock.lock()
    demuxBuffer.append(data)

    while demuxBuffer.count >= 8 {
      let streamType = demuxBuffer[0]
      let size =
        Int(demuxBuffer[4]) << 24 | Int(demuxBuffer[5]) << 16
        | Int(demuxBuffer[6]) << 8 | Int(demuxBuffer[7])

      guard demuxBuffer.count >= 8 + size else { break }

      let payload = demuxBuffer[8..<(8 + size)]
      switch streamType {
      case 1:
        stdout.write(Data(payload))
      case 2:
        stderr.write(Data(payload))
      default:
        break
      }

      demuxBuffer = Data(demuxBuffer[(8 + size)...])
    }
    lock.unlock()
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

    // Read until we see the end of HTTP headers (\r\n\r\n)
    while true {
      let bytesRead = read(fd, &buffer, buffer.count)
      guard bytesRead > 0 else {
        throw DockerRuntimeError.attachFailed("Connection closed during upgrade")
      }
      responseData.append(contentsOf: buffer[0..<bytesRead])

      if let str = String(data: responseData, encoding: .utf8),
        str.contains("\r\n\r\n")
      {
        guard str.contains("101") else {
          throw DockerRuntimeError.attachFailed(
            "Expected 101 Switching Protocols, got: \(str.prefix(200))")
        }
        // Any data after the headers is already stream data — push it into the demux buffer
        if let headerEnd = str.range(of: "\r\n\r\n") {
          let headerSize = str.distance(from: str.startIndex, to: headerEnd.upperBound)
          if responseData.count > headerSize {
            demuxBuffer.append(responseData[headerSize...])
          }
        }
        return
      }
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
