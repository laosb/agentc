#if ContainerRuntimeDocker
  import AgentIsolation
  @testable import AgentIsolationDockerRuntime
  import Dispatch
  import Foundation
  import Testing

  #if canImport(System)
    import System
  #else
    import SystemPackage
  #endif
  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #else
    import Musl
  #endif

  @Suite("Docker startup I/O")
  struct DockerStartupTests {
    @Test("Empty stdin reaches EOF after startup and early output is preserved")
    func emptyStdinDuringStartup() async throws {
      let daemon = try StartupDaemon()
      let serving = Task { try await daemon.serve() }
      let runtime = DockerRuntime(
        config: ContainerRuntimeConfiguration(
          storagePath: "/tmp/agentc-startup-test", endpoint: daemon.endpoint, ociRuntime: "kata"))
      defer { Task { try? await runtime.shutdown() } }
      let stdout = MockWriter()
      let stderr = MockWriter()
      let observedOutput = MockWriter()
      let container = try await runtime.runContainer(
        imageRef: "alpine:latest",
        configuration: ContainerConfiguration(
          entrypoint: ["echo", "started"],
          io: .custom(stdin: EmptyReaderStream(), stdout: stdout, stderr: stderr),
          stdioObserver: StdioObserver(
            stdin: { _ in }, stdout: { try? observedOutput.write($0) })))
      defer { container.attachConnection?.stop() }
      let closedBeforeStart = try await serving.value
      await container.attachConnection?.waitForReadCompletion()

      #expect(closedBeforeStart == false, "stdin EOF must not race Kata's Start and CloseIO RPCs")
      #expect(stdout.string == "early stdout\n")
      #expect(stderr.string == "early stderr\n")
      #expect(observedOutput.string == "early stdout\n")
    }
  }

  /// A minimal Docker peer that delays the start response and checks the attach
  /// socket for EOF. No Docker daemon or VM is needed to exercise startup ordering.
  private final class StartupDaemon: Sendable {
    let endpoint: String
    private let listener: Int32

    init() throws {
      #if canImport(Glibc)
        let type = Int32(SOCK_STREAM.rawValue)
      #else
        let type = SOCK_STREAM
      #endif
      let fd = socket(AF_INET, type, 0)
      guard fd >= 0 else { throw PeerError("cannot create listener") }
      do {
        var address = sockaddr_in()
        #if canImport(Darwin)
          address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
          }
        }
        guard bound == 0, listen(fd, 4) == 0 else { throw PeerError("cannot bind listener") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let located = withUnsafeMutablePointer(to: &address) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard located == 0 else { throw PeerError("cannot locate listener") }
        listener = fd
        endpoint = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
      } catch {
        _ = close(fd)
        throw error
      }
    }

    deinit { _ = close(listener) }

    func serve() async throws -> Bool {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
          do { continuation.resume(returning: try self.handleStartup()) } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }

    private func handleStartup() throws -> Bool {
      let create = try request("POST /v1.44/containers/create ")
      defer { _ = close(create) }
      try respond(create, status: "201 Created", body: #"{"Id":"startup-test"}"#)

      let attach = try request("POST /v1.44/containers/startup-test/attach?")
      defer { _ = close(attach) }
      try writeAll(
        attach,
        Data("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n".utf8)
      )

      let start = try request("POST /v1.44/containers/startup-test/start ")
      defer { _ = close(start) }
      // Make early EOF observable even if the client's input task is scheduled
      // after its start request. Kata can deadlock if CloseIO wins this race.
      let closedBeforeStart = try readable(attach, timeout: 100)
      try writeAll(attach, frame("early stdout\n", type: 1) + frame("early stderr\n", type: 2))
      try respond(start, status: "204 No Content")

      guard try readable(attach, timeout: 5000) else { throw PeerError("stdin never reached EOF") }
      var byte: UInt8 = 0
      guard read(attach, &byte, 1) == 0 else { throw PeerError("expected empty stdin") }
      _ = shutdown(attach, Int32(SHUT_WR))
      return closedBeforeStart
    }

    private func request(_ prefix: String) throws -> Int32 {
      guard try readable(listener, timeout: 5000) else {
        throw PeerError("missing request: \(prefix)")
      }
      let fd = accept(listener, nil, nil)
      guard fd >= 0 else { throw PeerError("cannot accept request") }
      do {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        while true {
          let count = read(fd, &buffer, buffer.count)
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw PeerError("incomplete request: \(prefix)") }
          data.append(contentsOf: buffer.prefix(count))
          guard let boundary = data.range(of: separator)?.upperBound else { continue }
          let headers = String(decoding: data[..<boundary], as: UTF8.self)
          guard headers.hasPrefix(prefix) else { throw PeerError("unexpected request: \(headers)") }
          let length =
            headers.components(separatedBy: "\r\n").first {
              $0.lowercased().hasPrefix("content-length:")
            }.flatMap {
              Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            } ?? 0
          if data.count >= boundary + length { return fd }
        }
      } catch {
        _ = close(fd)
        throw error
      }
    }
  }

  private struct PeerError: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  private func readable(_ fd: Int32, timeout: Int32) throws -> Bool {
    var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    var result: Int32
    repeat { result = poll(&event, 1, timeout) } while result < 0 && errno == EINTR
    guard result >= 0 else { throw PeerError("poll failed") }
    return result > 0
  }

  private func respond(_ fd: Int32, status: String, body: String = "") throws {
    try writeAll(
      fd,
      Data(
        "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
          .utf8))
  }

  private func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { _ = try FileDescriptor(rawValue: fd).writeAll($0) }
  }

  private func frame(_ text: String, type: UInt8) -> Data {
    let payload = Data(text.utf8)
    return Data([type, 0, 0, 0, 0, 0, 0, UInt8(payload.count)]) + payload
  }
#endif
