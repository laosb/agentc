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

/// An advisory interprocess lock held on a lock file.
///
/// Separate `agentc` invocations share the rootfs cache, so an in-process actor
/// alone would not serialize them. `flock` locks the open file description rather
/// than the process, so two `FileLock`s in one process exclude each other too.
///
/// The lock is released when ``release()`` is called or the handle is deallocated,
/// including if the process dies — the kernel closes the descriptor either way, so
/// a crash cannot leave the cache permanently locked.
public final class FileLock: @unchecked Sendable {
  public enum Mode {
    case shared
    case exclusive

    var flag: Int32 {
      switch self {
      case .shared: LOCK_SH
      case .exclusive: LOCK_EX
      }
    }
  }

  public enum Error: Swift.Error, CustomStringConvertible {
    case cannotOpen(path: String, errno: Int32)
    case cannotLock(path: String, errno: Int32)

    public var description: String {
      switch self {
      case .cannotOpen(let path, let code):
        return "cannot open lock file \(path): \(String(cString: strerror(code)))"
      case .cannotLock(let path, let code):
        return "cannot lock \(path): \(String(cString: strerror(code)))"
      }
    }
  }

  fileprivate var descriptor: Int32
  public let path: String

  private init(descriptor: Int32, path: String) {
    self.descriptor = descriptor
    self.path = path
  }

  deinit {
    if descriptor >= 0 { close(descriptor) }
  }

  /// Release the lock. Safe to call more than once.
  public func release() {
    guard descriptor >= 0 else { return }
    close(descriptor)
    descriptor = -1
  }

  /// Acquire a lock, waiting for it if necessary.
  ///
  /// The lock file's parent directory must already exist. Lock files live outside
  /// the entry directories they guard so that replacing or pruning an entry never
  /// unlinks the lock another process is holding.
  public static func acquire(at url: URL, mode: Mode) throws -> FileLock {
    let descriptor = try openLockFile(at: url)
    guard flock(descriptor, mode.flag) == 0 else {
      let code = errno
      close(descriptor)
      throw Error.cannotLock(path: url.path, errno: code)
    }
    return FileLock(descriptor: descriptor, path: url.path)
  }

  /// Wait without blocking a cooperative executor thread. Uses the same
  /// interprocess lock as `acquire`, but the backoff remains cancellable.
  public static func acquireAsync(at url: URL, mode: Mode) async throws -> FileLock {
    var delay = Duration.milliseconds(2)
    while true {
      try Task.checkCancellation()
      if let lock = try tryAcquire(at: url, mode: mode) { return lock }
      try await Task.sleep(for: delay)
      delay = min(delay * 2, .milliseconds(100))
    }
  }

  /// Acquire a lock only if it is free right now.
  ///
  /// Returns `nil` when another holder has it. Maintenance work uses this so a
  /// busy entry is skipped rather than delaying a session that is starting up.
  public static func tryAcquire(at url: URL, mode: Mode) throws -> FileLock? {
    let descriptor = try openLockFile(at: url)
    guard flock(descriptor, mode.flag | LOCK_NB) == 0 else {
      let code = errno
      close(descriptor)
      if code == EWOULDBLOCK || code == EAGAIN { return nil }
      throw Error.cannotLock(path: url.path, errno: code)
    }
    return FileLock(descriptor: descriptor, path: url.path)
  }

  private static func openLockFile(at url: URL) throws -> Int32 {
    let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw Error.cannotOpen(path: url.path, errno: errno)
    }
    return descriptor
  }
}

extension FileLock {
  /// Convert an already-held lock to another mode on the same descriptor.
  ///
  /// Used to downgrade an exclusive repair lease to the shared lease an ordinary
  /// session holds for the rest of its life. `flock` performs the conversion on
  /// the existing open file description, so the lock is never fully dropped and
  /// reacquired — but callers must still serialize conversions against each other,
  /// because a downgrade momentarily admits waiting shared holders.
  public func convert(to mode: Mode) throws {
    guard descriptor >= 0 else { return }
    guard flock(descriptor, mode.flag) == 0 else {
      throw Error.cannotLock(path: path, errno: errno)
    }
  }
}
