#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public protocol Writer: Sendable {
  func write(_ data: Data) throws
  func close() throws
}
