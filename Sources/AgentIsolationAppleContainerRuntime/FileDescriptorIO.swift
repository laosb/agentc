#if canImport(Containerization)
  import Containerization
  import Foundation
  import System

  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #endif

  /// `ReaderStream` backed by a `FileDescriptor` (e.g. stdin).
  struct FileDescriptorReader: ReaderStream {
    private let fd: FileDescriptor

    init(_ fd: FileDescriptor) {
      self.fd = fd
    }

    func stream() -> AsyncStream<Data> {
      let rawFD = fd.rawValue
      return AsyncStream { continuation in
        let source = DispatchSource.makeReadSource(
          fileDescriptor: rawFD,
          queue: DispatchQueue.global(qos: .userInteractive))
        source.setEventHandler {
          var buffer = [UInt8](repeating: 0, count: 4096)
          let bytesRead = read(rawFD, &buffer, buffer.count)
          if bytesRead <= 0 {
            source.cancel()
          } else {
            continuation.yield(Data(buffer[0..<bytesRead]))
          }
        }
        source.setCancelHandler {
          continuation.finish()
        }
        continuation.onTermination = { _ in
          source.cancel()
        }
        source.resume()
      }
    }
  }

  /// `Writer` backed by a `FileDescriptor` (e.g. stdout / stderr).
  struct FileDescriptorWriter: Writer {
    private let fd: FileDescriptor

    init(_ fd: FileDescriptor) {
      self.fd = fd
    }

    func write(_ data: Data) throws {
      _ = try data.withUnsafeBytes { try fd.writeAll($0) }
    }

    func close() throws {
      try fd.close()
    }
  }
#endif
