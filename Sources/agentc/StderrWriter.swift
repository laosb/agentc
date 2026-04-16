#if canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(Darwin)
  import Darwin
#endif

/// Write a message to standard error. Concurrency-safe (uses the STDERR_FILENO
/// constant and the POSIX `write` syscall rather than C's mutable `stderr` global).
func writeToStderr(_ message: String) {
  var msg = message
  msg.withUTF8 { buf in
    _ = write(STDERR_FILENO, buf.baseAddress!, buf.count)
  }
}
