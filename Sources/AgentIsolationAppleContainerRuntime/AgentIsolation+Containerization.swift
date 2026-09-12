#if canImport(Containerization)
  import AgentIsolation
  import Containerization
  import Foundation

  struct ContainerizationReaderStream: Containerization.ReaderStream {
    private let reader: any AgentIsolation.ReaderStream

    init(_ reader: any AgentIsolation.ReaderStream) {
      self.reader = reader
    }

    @inlinable func stream() -> AsyncStream<Data> {
      reader.stream()
    }
  }

  struct ContainerizationWriter: Containerization.Writer {
    private let writer: any AgentIsolation.Writer

    init(_ writer: any AgentIsolation.Writer) {
      self.writer = writer
    }

    @inlinable func write(_ data: Data) throws {
      try writer.write(data)
    }

    @inlinable func close() throws {
      try writer.close()
    }
  }

  /// Wrap the already-configured streams, including Terminal, so observation
  /// leaves raw mode, resize handling, and EOF ownership with Containerization.
  struct ObservedContainerizationReader: Containerization.ReaderStream {
    let reader: any Containerization.ReaderStream
    let observe: @Sendable (Data) -> Void

    func stream() -> AsyncStream<Data> {
      let input = reader.stream()
      return AsyncStream { continuation in
        let task = Task {
          for await data in input {
            guard !Task.isCancelled else { break }
            observe(data)
            continuation.yield(data)
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
  }

  struct ObservedContainerizationWriter: Containerization.Writer {
    let writer: any Containerization.Writer
    let observe: @Sendable (Data) -> Void

    func write(_ data: Data) throws {
      observe(data)
      try writer.write(data)
    }

    func close() throws { try writer.close() }
  }

#endif
