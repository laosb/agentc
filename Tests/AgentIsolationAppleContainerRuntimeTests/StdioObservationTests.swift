#if canImport(Containerization)
  import AgentIsolation
  @testable import AgentIsolationAppleContainerRuntime
  import Foundation
  import Synchronization
  import Testing

  @Suite("Apple Containerization stdio observation")
  struct StdioObservationTests {
    @Test("Input observation preserves chunks and EOF")
    func input() async {
      let chunks = [Data([0x00, 0xff]), Data("request\n".utf8)]
      let stream = AsyncStream<Data> { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      }
      let captured = Output()
      let reader = ObservedContainerizationReader(
        reader: ContainerizationReaderStream(Input(inner: stream)), observe: captured.write)
      var forwarded: [Data] = []
      for await chunk in reader.stream() { forwarded.append(chunk) }
      #expect(forwarded == chunks)
      #expect(captured.data == chunks.reduce(into: Data()) { $0.append($1) })
    }

    @Test("Output observation preserves data and delegates close")
    func output() throws {
      let forwarded = Output()
      let captured = Output()
      let writer = ObservedContainerizationWriter(
        writer: ContainerizationWriter(forwarded), observe: captured.write)
      let data = Data([0x00, 0xff, 0x0a])
      try writer.write(data)
      try writer.close()
      #expect(forwarded.data == data)
      #expect(captured.data == data)
      #expect(forwarded.closed)
      #expect(!captured.closed)
    }
  }

  private struct Input: ReaderStream {
    let inner: AsyncStream<Data>
    func stream() -> AsyncStream<Data> { inner }
  }

  private final class Output: Writer, Sendable {
    private let storage = Mutex((data: Data(), closed: false))
    var data: Data { storage.withLock { $0.data } }
    var closed: Bool { storage.withLock { $0.closed } }
    func write(_ data: Data) { storage.withLock { $0.data.append(data) } }
    func close() { storage.withLock { $0.closed = true } }
  }
#endif
