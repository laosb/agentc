#if canImport(FoundationEssentials) && (canImport(Musl) || canImport(Glibc))
  import FoundationEssentials
  #if canImport(Musl)
    @preconcurrency import Musl
  #else
    @preconcurrency import Glibc
  #endif

  /// A checked, descriptor-relative ownership repair.
  ///
  /// Replaces the old path-based recursive `chown`, which followed symlinks when
  /// changing ownership, trusted `dirent.d_type`, and silently ignored every
  /// error. Those are not acceptable for a migration whose success gets recorded:
  /// a symlink out of the profile could have redirected a `chown` at anything the
  /// root user can reach, and an ignored `EPERM` would have been published as a
  /// completed repair.
  ///
  /// This walker:
  /// - opens directories relative to their parent's descriptor, so a component
  ///   cannot be swapped out underneath it mid-walk;
  /// - never follows a symlink, either to descend or to change ownership;
  /// - never crosses onto another filesystem, so a nested mount inside the profile
  ///   is left alone;
  /// - resolves entries with `fstatat` rather than trusting `d_type`, which is
  ///   `DT_UNKNOWN` on plenty of filesystems;
  /// - changes ownership only where it actually differs;
  /// - collects errors and reports them, rather than reporting success.
  enum OwnershipWalker {
    /// How much work a pass did, and what went wrong.
    struct Stats {
      var visited = 0
      var changed = 0
      /// Entries skipped because they sit on a different filesystem.
      var skippedOtherFilesystem = 0
      var errors: [String] = []

      var firstError: String? { errors.first }
    }

    enum Failure: Error, CustomStringConvertible {
      case cannotOpen(String, Int32)
      case incomplete(Stats)

      var description: String {
        switch self {
        case .cannotOpen(let path, let code):
          return "cannot open \(path): \(String(cString: strerror(code)))"
        case .incomplete(let stats):
          let extra = stats.errors.count > 1 ? " (and \(stats.errors.count - 1) more)" : ""
          return "\(stats.errors.first ?? "unknown error")\(extra)"
        }
      }
    }

    /// Deep enough for any real profile; a bound stops a pathological tree from
    /// exhausting the stack or descriptor table.
    static let maximumDepth = 128

    /// Cap on collected error messages, so a systematically failing tree cannot
    /// produce an unbounded report.
    private static let maximumErrors = 16

    /// Recursively give `root` and everything under it to `uid`/`gid`.
    ///
    /// Throws when anything could not be changed: a partial repair must never be
    /// published as a success.
    static func repair(root: String, uid: uid_t, gid: gid_t) throws -> Stats {
      var stats = Stats()
      let rootFD = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard rootFD >= 0 else { throw Failure.cannotOpen(root, errno) }
      defer { close(rootFD) }

      var rootInfo = stat()
      guard fstat(rootFD, &rootInfo) == 0 else { throw Failure.cannotOpen(root, errno) }

      stats.visited += 1
      if rootInfo.st_uid != uid || rootInfo.st_gid != gid {
        if fchown(rootFD, uid, gid) == 0 {
          stats.changed += 1
        } else {
          record(&stats, "chown \(root): \(String(cString: strerror(errno)))")
        }
      }

      walk(
        directory: rootFD, path: root, device: rootInfo.st_dev, uid: uid, gid: gid,
        depth: 0, stats: &stats)

      guard stats.errors.isEmpty else { throw Failure.incomplete(stats) }
      return stats
    }

    private static func record(_ stats: inout Stats, _ message: String) {
      guard stats.errors.count < maximumErrors else { return }
      stats.errors.append(message)
    }

    private static func walk(
      directory: Int32,
      path: String,
      device: dev_t,
      uid: uid_t,
      gid: gid_t,
      depth: Int,
      stats: inout Stats
    ) {
      guard depth < maximumDepth else {
        record(&stats, "\(path): directory nesting exceeds \(maximumDepth) levels")
        return
      }

      // `fdopendir` takes ownership of the descriptor it is given, and the caller
      // still needs theirs, so hand it a duplicate.
      let duplicated = dup(directory)
      guard duplicated >= 0, let handle = fdopendir(duplicated) else {
        if duplicated >= 0 { close(duplicated) }
        record(&stats, "cannot read \(path): \(String(cString: strerror(errno)))")
        return
      }
      defer { closedir(handle) }

      while let entry = readdir(handle) {
        var nameBuffer = entry.pointee.d_name
        let name = withUnsafePointer(to: &nameBuffer) {
          String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        if name == "." || name == ".." { continue }
        let childPath = "\(path)/\(name)"

        // Resolve the entry properly rather than trusting `d_type`, which many
        // filesystems report as DT_UNKNOWN, and never follow a symlink.
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
          record(&stats, "stat \(childPath): \(String(cString: strerror(errno)))")
          continue
        }

        // A nested mount is somebody else's filesystem. Repair is restricted to
        // the profile home itself.
        guard info.st_dev == device else {
          stats.skippedOtherFilesystem += 1
          continue
        }

        stats.visited += 1
        if info.st_uid != uid || info.st_gid != gid {
          if fchownat(directory, name, uid, gid, AT_SYMLINK_NOFOLLOW) == 0 {
            stats.changed += 1
          } else {
            record(&stats, "chown \(childPath): \(String(cString: strerror(errno)))")
            continue
          }
        }

        guard (info.st_mode & S_IFMT) == S_IFDIR else { continue }

        let childFD = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard childFD >= 0 else {
          record(&stats, "cannot open \(childPath): \(String(cString: strerror(errno)))")
          continue
        }
        defer { close(childFD) }
        walk(
          directory: childFD, path: childPath, device: device, uid: uid, gid: gid,
          depth: depth + 1, stats: &stats)
      }
    }
  }
#endif
