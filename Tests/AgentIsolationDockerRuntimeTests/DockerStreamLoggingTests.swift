#if ContainerRuntimeDocker
  import AgentIsolation
  @testable import AgentIsolationDockerRuntime
  import Foundation
  import Synchronization
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

  @Suite("Docker stdio observation")
  struct DockerStreamLoggingTests {
    @Test("Non-TTY containers keep output attached after stdin EOF")
    func stdinOnce() throws {
      let request = DockerRuntime.makeCreateRequest(
        imageRef: "alpine:latest",
        configuration: ContainerConfiguration(entrypoint: ["cat"], io: .standardIO))
      let json = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
      // Docker otherwise detaches stdout/stderr when the client's stdin ends.
      #expect(json["StdinOnce"] as? Bool == true)
    }

    @Test("Descriptor I/O preserves traffic, EOF, and stderr separation", arguments: [false, true])
    func descriptorIO(tty: Bool) async throws {
      let (attach, peer) = try connection(tty: tty)
      let watchdog = completionWatchdog(attach)
      defer { watchdog.cancel() }
      defer { _ = close(peer) }
      let stdin = Pipe()
      let stdout = Pipe()
      let stderr = Pipe()
      let observedInput = CaptureWriter()
      let observedOutput = CaptureWriter()
      let input = Data("{\"method\":\"initialize\"}\n".utf8)
      let output = Data("{\"result\":\"🌍\"}\n".utf8)
      let diagnostic = Data("guest diagnostic\n".utf8)

      try stdin.fileHandleForWriting.write(contentsOf: input)
      try stdin.fileHandleForWriting.close()
      attach.startIO(
        stdin: FileDescriptor(rawValue: stdin.fileHandleForReading.fileDescriptor),
        stdout: FileDescriptor(rawValue: stdout.fileHandleForWriting.fileDescriptor),
        stderr: FileDescriptor(rawValue: stderr.fileHandleForWriting.fileDescriptor),
        observer: StdioObserver(stdin: observedInput.write, stdout: observedOutput.write))
      let received = try await Task {
        try readInput(peer, count: input.count, tty: tty)
      }.value
      #expect(received == input)
      #expect(observedInput.data == input)

      try sendOutput(output, diagnostic: diagnostic, tty: tty, peer: peer)
      await attach.waitForReadCompletion()
      #expect(observedOutput.data == output)
      try stdout.fileHandleForWriting.close()
      try stderr.fileHandleForWriting.close()
      #expect(stdout.fileHandleForReading.readDataToEndOfFile() == output)
      #expect(stderr.fileHandleForReading.readDataToEndOfFile() == (tty ? Data() : diagnostic))
      // Keep pipe descriptors alive until the attach source has finished.
      withExtendedLifetime(attach) {}
    }

    @Test("Custom I/O observes only payloads and preserves input EOF", arguments: [false, true])
    func customIO(tty: Bool) async throws {
      let (attach, peer) = try connection(tty: tty)
      let watchdog = completionWatchdog(attach)
      defer { watchdog.cancel() }
      defer { _ = close(peer) }
      let stdin = AsyncStream<Data>.makeStream()
      let stdout = CaptureWriter()
      let stderr = CaptureWriter()
      let observedInput = CaptureWriter()
      let observedOutput = CaptureWriter()
      let input = Data([0x00, 0xff, 0x0a])
      let output = Data(repeating: 0x61, count: 96 * 1024)
      let diagnostic = Data("guest diagnostic\n".utf8)

      stdin.continuation.yield(input)
      stdin.continuation.finish()
      attach.startCustomIO(
        stdin: InputStream(inner: stdin.stream), stdout: stdout, stderr: stderr,
        observer: StdioObserver(stdin: observedInput.write, stdout: observedOutput.write))
      let received = try await Task {
        try readInput(peer, count: input.count, tty: tty)
      }.value
      #expect(received == input)
      #expect(observedInput.data == input)
      try sendOutput(output, diagnostic: diagnostic, tty: tty, peer: peer)
      await attach.waitForReadCompletion()
      #expect(stdout.data == output)
      #expect(observedOutput.data == output)
      #expect(stderr.data == (tty ? Data() : diagnostic))
    }
  }

  private struct InputStream: ReaderStream {
    let inner: AsyncStream<Data>
    func stream() -> AsyncStream<Data> { inner }
  }

  private final class CaptureWriter: Writer, Sendable {
    private let bytes = Mutex(Data())
    var data: Data { bytes.withLock { $0 } }
    func write(_ data: Data) { bytes.withLock { $0.append(data) } }
    func close() {}
  }

  private func connection(tty: Bool) throws -> (DockerStreamAttach, Int32) {
    var sockets: [Int32] = [-1, -1]
    #if canImport(Glibc)
      let type = Int32(SOCK_STREAM.rawValue)
    #else
      let type = SOCK_STREAM
    #endif
    try #require(socketpair(AF_UNIX, type, 0, &sockets) == 0)
    // A failed EOF regression should fail the test, never block the suite.
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(
      sockets[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return (DockerStreamAttach(fd: sockets[0], tty: tty), sockets[1])
  }

  private func completionWatchdog(_ attach: DockerStreamAttach) -> Task<Void, Never> {
    Task {
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      Issue.record("Attach did not finish after socket EOF")
      attach.stop()
    }
  }

  private func readToEOF(_ fd: Int32) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count < 0 && errno == EINTR { continue }
      try #require(count >= 0, "stdin did not reach EOF")
      if count == 0 { return result }
      result.append(contentsOf: buffer.prefix(count))
    }
  }

  private func readInput(_ fd: Int32, count: Int, tty: Bool) throws -> Data {
    guard tty else { return try readToEOF(fd) }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while result.count < count {
      let received = read(fd, &buffer, min(buffer.count, count - result.count))
      if received < 0 && errno == EINTR { continue }
      try #require(received > 0, "TTY input ended before its payload arrived")
      result.append(contentsOf: buffer.prefix(received))
    }
    // For a TTY, Docker detaches output on a socket half-close even with
    // StdinOnce enabled. Input EOF must leave the connection open for output.
    var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    var ready: Int32
    repeat { ready = poll(&event, 1, 100) } while ready < 0 && errno == EINTR
    #expect(ready == 0, "TTY attach was half-closed when local stdin ended")
    return result
  }

  private func sendOutput(_ output: Data, diagnostic: Data, tty: Bool, peer: Int32) throws {
    var bytes = tty ? output : frame(output, type: 1) + frame(diagnostic, type: 2)
    // Split the header as well as the payload, just as a real socket may do.
    try bytes.prefix(3).withUnsafeBytes { _ = try FileDescriptor(rawValue: peer).writeAll($0) }
    bytes.removeFirst(3)
    try bytes.withUnsafeBytes { _ = try FileDescriptor(rawValue: peer).writeAll($0) }
    _ = shutdown(peer, Int32(SHUT_WR))
  }

  private func frame(_ payload: Data, type: UInt8) -> Data {
    let size = payload.count
    var result = Data([
      type, 0, 0, 0,
      UInt8(truncatingIfNeeded: size >> 24), UInt8(truncatingIfNeeded: size >> 16),
      UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size),
    ])
    result.append(payload)
    return result
  }
#endif
