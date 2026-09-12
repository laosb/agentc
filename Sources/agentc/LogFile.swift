import Synchronization

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// An append-only regular file. Never accepts stdout, a terminal, or a pipe as a
/// logging destination, even when reached through a symlink such as /dev/stdout.
final class LogFile: Sendable {
  private let descriptor: Int32
  private let lock = Mutex(())
  private let path: String

  init(path: String) throws {
    self.path = path
    guard !path.isEmpty, !path.contains("\0") else {
      throw LogFileError(message: "log file path must not be empty or contain NUL")
    }
    var fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NONBLOCK, 0o600)
    guard fd >= 0 else { throw Self.error("open", path: path) }
    do {
      // Keep ownership separate from the process's standard descriptors, even
      // when the caller launched agentc with one of them closed.
      if fd < 3 {
        let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 3)
        let savedErrno = errno
        _ = close(fd)
        fd = duplicate
        guard fd >= 0 else {
          throw Self.error("duplicate", path: path, code: savedErrno)
        }
      }
      var info = stat()
      guard fstat(fd, &info) == 0 else { throw Self.error("inspect", path: path) }
      guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
        throw LogFileError(message: "log file '\(path)' must be a regular file")
      }
      var stdoutInfo = stat()
      if fstat(STDOUT_FILENO, &stdoutInfo) == 0,
        info.st_dev == stdoutInfo.st_dev, info.st_ino == stdoutInfo.st_ino
      {
        throw LogFileError(message: "log file '\(path)' must not refer to stdout")
      }
    } catch {
      if fd >= 0 { _ = close(fd) }
      throw error
    }
    descriptor = fd
  }

  deinit { _ = close(descriptor) }

  func append(_ data: Data) throws {
    try lock.withLock { _ in
      try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let count = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw Self.error("write", path: path) }
          offset += count
        }
      }
    }
  }

  /// Redirect fd 2 so runtime, guest, subprocess, and command errors share
  /// the same destination. fd 0 and fd 1 stay untouched, including their TTY state.
  func redirectStandardError() throws {
    guard dup2(descriptor, STDERR_FILENO) >= 0 else {
      throw Self.error("redirect stderr to", path: path)
    }
  }

  private static func error(_ operation: String, path: String, code: Int32 = errno) -> LogFileError
  {
    LogFileError(
      message: "cannot \(operation) log file '\(path)': \(String(cString: strerror(code)))")
  }
}

struct LogFileError: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
