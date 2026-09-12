#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Observes container stdin and stdout without changing their bytes or I/O mode.
/// Callbacks can run concurrently and should return promptly. Stderr is separate;
/// a terminal, as usual, merges guest stdout and stderr into its output stream.
public struct StdioObserver: Sendable {
  public var stdin: @Sendable (Data) -> Void
  public var stdout: @Sendable (Data) -> Void

  public init(
    stdin: @escaping @Sendable (Data) -> Void,
    stdout: @escaping @Sendable (Data) -> Void
  ) {
    self.stdin = stdin
    self.stdout = stdout
  }
}
