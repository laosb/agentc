#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// A bootstrap subcommand, deliberately independent of root setup, configuration
/// scripts, and the image's userspace. The published bootstrap is static musl.
enum MCPStdioRelay {
  // Versioned wire-mode marker, also checked by BootstrapManager before mounting.
  static let argument = "--agentc-mcp-stdio-relay-v1"

  struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  static func run(_ arguments: [String]) throws -> Int32 {
    if arguments == ["--version"] {
      print(argument)
      return 0
    }
    var arguments = arguments
    var host: String?
    if arguments.count == 4, arguments[0] == "--host" {
      host = arguments[1]
      arguments.removeFirst(2)
    }
    guard arguments.count == 2, let port = UInt16(arguments[0]), port != 0,
      arguments[1].utf8.count == 64,
      arguments[1].utf8.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      })
    else { throw Failure("usage: \(argument) [--host address] port capability") }
    _ = signal(SIGPIPE, SIG_IGN)
    let hosts =
      host.map { [$0] } ?? ([defaultGateway()].compactMap { $0 } + ["host.docker.internal"])
    for host in hosts {
      if let socket = connect(host: host, port: String(port), token: arguments[1]) {
        defer { _ = close(socket) }
        try relay(socket)
        return 0
      }
    }
    throw Failure("Cannot connect to or authenticate with host MCP bridge")
  }

  static func defaultGateway() -> String? {
    guard let routes = try? String(contentsOfFile: "/proc/net/route", encoding: .utf8) else {
      return nil
    }
    return gateway(in: routes)
  }

  static func gateway(in routes: String) -> String? {
    for line in routes.split(separator: "\n") {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 4, fields[1] == "00000000",
        let address = UInt32(fields[2], radix: 16), address != 0,
        let flags = UInt32(fields[3], radix: 16), flags & 2 != 0
      else { continue }
      return (0..<4).map { String((address >> ($0 * 8)) & 255) }.joined(separator: ".")
    }
    return nil
  }

  private static var now: Int64 {
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC, &time)
    return Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000
  }

  private static func wait(_ fd: Int32, for events: Int16, until deadline: Int64) -> Bool {
    while now < deadline {
      var descriptor = pollfd(fd: fd, events: events, revents: 0)
      let result = poll(&descriptor, 1, Int32(max(1, deadline - now)))
      if result < 0 && errno == EINTR { continue }
      return result > 0
    }
    return false
  }

  private static func connect(host: String, port: String, token: String) -> Int32? {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    #if canImport(Glibc)
      hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    #else
      hints.ai_socktype = SOCK_STREAM
    #endif
    var addresses: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, port, &hints, &addresses) == 0 else { return nil }
    defer { if let addresses { freeaddrinfo(addresses) } }
    var current = addresses
    while let address = current {
      current = address.pointee.ai_next
      let fd = socket(
        address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
      guard fd >= 0 else { continue }
      var usable = fcntl(fd, F_SETFL, O_NONBLOCK) == 0
      let deadline = now + 5000
      if usable {
        #if canImport(Darwin)
          let result = Darwin.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen)
        #elseif canImport(Glibc)
          let result = Glibc.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen)
        #else
          let result = Musl.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen)
        #endif
        if result < 0 {
          usable = errno == EINPROGRESS && wait(fd, for: Int16(POLLOUT), until: deadline)
          var error: Int32 = 0
          var size = socklen_t(MemoryLayout<Int32>.size)
          if usable {
            usable = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0
          }
        }
      }
      if usable {
        var greeting = Buffer(Data((token + "\n").utf8))
        while !greeting.empty && wait(fd, for: Int16(POLLOUT), until: deadline) {
          do { try greeting.write(to: fd) } catch {
            usable = false
            break
          }
        }
        var ack: [UInt8] = []
        while usable && greeting.empty && ack.count < 3
          && wait(fd, for: Int16(POLLIN), until: deadline)
        {
          var byte: UInt8 = 0
          let count = read(fd, &byte, 1)
          if count == 1 {
            ack.append(byte)
          } else if count < 0 && (errno == EINTR || errno == EAGAIN) {
            continue
          } else {
            break
          }
        }
        if ack == Array("OK\n".utf8) { return fd }
      }
      _ = close(fd)
    }
    return nil
  }

  private struct Buffer {
    var bytes: Data
    var offset = 0
    var empty: Bool { offset == bytes.count }
    init(_ bytes: Data = Data()) { self.bytes = bytes }

    mutating func read(from fd: Int32) throws -> Bool {
      var block = [UInt8](repeating: 0, count: 64 * 1024)
      let count = block.withUnsafeMutableBytes { POSIXRead(fd, $0.baseAddress, $0.count) }
      if count > 0 {
        bytes = Data(block.prefix(count))
        offset = 0
      } else if count == 0 {
        return false
      } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
        throw Failure("Host MCP relay read failed: errno \(errno)")
      }
      return true
    }

    mutating func write(to fd: Int32) throws {
      let count = bytes.withUnsafeBytes {
        POSIXWrite(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset)
      }
      if count > 0 {
        offset += count
      } else if count == 0 {
        throw Failure("Host MCP relay write made no progress")
      } else if count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
        throw Failure("Host MCP relay write failed: errno \(errno)")
      }
    }
  }

  private static func POSIXRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int)
    -> Int
  {
    #if canImport(Darwin)
      Darwin.read(fd, buffer, count)
    #elseif canImport(Glibc)
      Glibc.read(fd, buffer, count)
    #else
      Musl.read(fd, buffer, count)
    #endif
  }

  private static func POSIXWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
      Darwin.write(fd, buffer, count)
    #elseif canImport(Glibc)
      Glibc.write(fd, buffer, count)
    #else
      Musl.write(fd, buffer, count)
    #endif
  }

  private static func relay(_ socket: Int32) throws {
    let inputFlags = fcntl(STDIN_FILENO, F_GETFL)
    let outputFlags = fcntl(STDOUT_FILENO, F_GETFL)
    guard inputFlags >= 0, outputFlags >= 0 else { throw Failure("Cannot access relay stdio") }
    defer {
      _ = fcntl(STDIN_FILENO, F_SETFL, inputFlags)
      _ = fcntl(STDOUT_FILENO, F_SETFL, outputFlags)
    }
    guard fcntl(STDIN_FILENO, F_SETFL, inputFlags | O_NONBLOCK) == 0,
      fcntl(STDOUT_FILENO, F_SETFL, outputFlags | O_NONBLOCK) == 0
    else { throw Failure("Cannot configure relay stdio") }
    var inputOpen = true
    var socketOpen = true
    var writeOpen = true
    var toHost = Buffer()
    var toClient = Buffer()
    while socketOpen || !toClient.empty {
      if !inputOpen && toHost.empty && writeOpen {
        _ = shutdown(socket, Int32(SHUT_WR))
        writeOpen = false
      }
      var fds = [
        pollfd(
          fd: inputOpen && toHost.empty ? STDIN_FILENO : -1, events: Int16(POLLIN), revents: 0),
        pollfd(
          fd: (socketOpen && toClient.empty) || !toHost.empty ? socket : -1,
          events: Int16(
            (socketOpen && toClient.empty ? POLLIN : 0) | (!toHost.empty ? POLLOUT : 0)), revents: 0
        ),
        pollfd(fd: !toClient.empty ? STDOUT_FILENO : -1, events: Int16(POLLOUT), revents: 0),
      ]
      let result = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), -1) }
      if result < 0 {
        if errno == EINTR { continue }
        throw Failure("Host MCP relay poll failed: errno \(errno)")
      }
      if fds[0].revents & Int16(POLLIN | POLLHUP) != 0 {
        inputOpen = try toHost.read(from: STDIN_FILENO)
      }
      if toClient.empty && fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
        socketOpen = try toClient.read(from: socket)
      }
      if !toHost.empty && fds[1].revents & Int16(POLLOUT) != 0 { try toHost.write(to: socket) }
      if !toClient.empty && fds[2].revents & Int16(POLLOUT) != 0 {
        try toClient.write(to: STDOUT_FILENO)
      }
      if fds[0].revents & Int16(POLLERR | POLLNVAL) != 0
        || fds[2].revents & Int16(POLLERR | POLLNVAL | POLLHUP) != 0
      {
        throw Failure("Host MCP relay stdio closed unexpectedly")
      }
    }
  }
}
