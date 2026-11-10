import Foundation

/// Blocking test I/O must not occupy a cooperative executor thread needed by
/// the asynchronous code under test. A detached Task still uses that executor.
func blockingIO<Value: Sendable>(
  _ body: @escaping @Sendable () throws -> Value
) async throws -> Value {
  try await withCheckedThrowingContinuation { continuation in
    Thread.detachNewThread {
      do { continuation.resume(returning: try body()) } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}
