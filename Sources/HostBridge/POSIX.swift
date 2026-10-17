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

public enum BridgePOSIX {
  public static func error(_ operation: String) -> BridgeError {
    BridgeError("\(operation): \(String(cString: strerror(errno)))")
  }

  public static func nonblocking(_ fd: Int32) throws {
    guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
      throw error("fcntl")
    }
  }

  public static func configureSocket(_ fd: Int32) throws {
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    #if canImport(Darwin)
      var enabled: Int32 = 1
      guard
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
      else {
        throw error("SO_NOSIGPIPE")
      }
    #endif
    try nonblocking(fd)
  }

  public static func pipe() throws -> (read: Int32, write: Int32) {
    var fds: [Int32] = [-1, -1]
    #if canImport(Darwin)
      let result = Darwin.pipe(&fds)
    #elseif canImport(Glibc)
      let result = Glibc.pipe2(&fds, O_CLOEXEC)
    #else
      let result = Musl.pipe2(&fds, O_CLOEXEC)
    #endif
    guard result == 0 else { throw error("pipe") }
    for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    return (fds[0], fds[1])
  }

  public static func socket(path: String, listening: Bool) throws -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw BridgeError("Host bridge socket path is too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    #if canImport(Darwin)
      let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #elseif canImport(Musl)
      let fd = Musl.socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0)
    #else
      let fd = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
    #endif
    guard fd >= 0 else { throw error("socket") }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        listening
          ? bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
          : connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let failure = error(listening ? "bind" : "connect")
      close(fd)
      throw failure
    }
    if listening && listen(fd, 32) != 0 {
      let failure = error("listen")
      close(fd)
      throw failure
    }
    do { try configureSocket(fd) } catch {
      close(fd)
      throw error
    }
    return fd
  }

  /// nil means would-block, empty means EOF.
  public static func read(_ fd: Int32, limit: Int = BridgeFrame.chunkSize) throws -> Data? {
    var bytes = [UInt8](repeating: 0, count: limit)
    let count = bytes.withUnsafeMutableBytes {
      #if canImport(Darwin)
        Darwin.read(fd, $0.baseAddress, $0.count)
      #elseif canImport(Glibc)
        Glibc.read(fd, $0.baseAddress, $0.count)
      #else
        Musl.read(fd, $0.baseAddress, $0.count)
      #endif
    }
    if count < 0 {
      if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return nil }
      throw error("read")
    }
    return Data(bytes.prefix(count))
  }

  public static func write(_ fd: Int32, buffer: inout Data, limit: Int = Int.max) throws {
    guard !buffer.isEmpty else { return }
    let count = buffer.withUnsafeBytes {
      #if canImport(Darwin)
        Darwin.write(fd, $0.baseAddress, min(limit, $0.count))
      #elseif canImport(Glibc)
        Glibc.write(fd, $0.baseAddress, min(limit, $0.count))
      #else
        Musl.write(fd, $0.baseAddress, min(limit, $0.count))
      #endif
    }
    if count < 0 {
      if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return }
      throw error("write")
    }
    buffer.removeFirst(count)
  }

  public static func poll(_ descriptors: inout [pollfd], milliseconds: Int32 = 100) throws {
    #if canImport(Darwin)
      let result = Darwin.poll(&descriptors, nfds_t(descriptors.count), milliseconds)
    #elseif canImport(Glibc)
      let result = Glibc.poll(&descriptors, nfds_t(descriptors.count), milliseconds)
    #else
      let result = Musl.poll(&descriptors, nfds_t(descriptors.count), milliseconds)
    #endif
    guard result >= 0 || errno == EINTR else {
      throw error("poll")
    }
  }

  public static let signals: [(String, Int32)] = [
    ("HUP", SIGHUP), ("INT", SIGINT), ("QUIT", SIGQUIT), ("TERM", SIGTERM),
    ("USR1", SIGUSR1), ("USR2", SIGUSR2), ("ALRM", SIGALRM), ("PIPE", SIGPIPE),
    ("ABRT", SIGABRT), ("KILL", SIGKILL), ("SEGV", SIGSEGV), ("ILL", SIGILL),
    ("FPE", SIGFPE), ("BUS", SIGBUS),
  ]
}

/// Owned by one IO loop. shutdown() from the broker interrupts that loop without
/// closing/reusing its fd beneath it.
public final class BridgeConnection {
  public let fd: Int32
  public var output = Data()
  private var decoder = BridgeDecoder()
  public init(fd: Int32) { self.fd = fd }
  deinit { close(fd) }

  public func enqueue(_ frame: BridgeFrame) throws {
    let bytes = try frame.encoded()
    guard output.count + bytes.count <= BridgeFrame.launchLimit + 65536 else {
      throw BridgeError("Host bridge output queue is full")
    }
    output.append(bytes)
  }
  public func flush() throws { try BridgePOSIX.write(fd, buffer: &output) }
  public func receive() throws -> [BridgeFrame] {
    guard let data = try BridgePOSIX.read(fd) else { return [] }
    guard !data.isEmpty else {
      try decoder.finish()
      throw BridgeError("Host bridge disconnected")
    }
    return try decoder.append(data)
  }

  public func readLaunch() throws -> BridgeLaunch {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
      try BridgePOSIX.poll(&fds)
      if fds[0].revents != 0 {
        let frames = try receive()
        if !frames.isEmpty {
          guard frames.count == 1, frames[0].kind == .launch else {
            throw BridgeError("Expected a host bridge launch")
          }
          return try JSONDecoder().decode(BridgeLaunch.self, from: frames[0].data)
        }
      }
    }
    throw BridgeError("Host bridge launch timed out")
  }
}
