#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public protocol ReaderStream: Sendable {
  func stream() -> AsyncStream<Data>
}
