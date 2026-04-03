import Containerization
import Foundation

/// `ReaderStream` backed by a `FileHandle` (e.g. stdin).
struct FileHandleReader: ReaderStream {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func stream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty {
                    h.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
    }
}

/// `Writer` backed by a `FileHandle` (e.g. stdout / stderr).
struct FileHandleWriter: Writer {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    func close() throws {
        try handle.close()
    }
}
