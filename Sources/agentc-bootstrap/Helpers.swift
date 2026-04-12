import FoundationEssentials
import Musl

// MARK: - Errors

enum BootstrapError: Error, CustomStringConvertible {
  case setupFailed(String)
  case userNotFound(String)
  case privilegeDropFailed(String)
  case configurationError(String)
  case execFailed(String)

  var description: String {
    switch self {
    case .setupFailed(let msg): return "setup failed: \(msg)"
    case .userNotFound(let user): return "user '\(user)' not found"
    case .privilegeDropFailed(let msg): return "privilege drop failed: \(msg)"
    case .configurationError(let msg): return "configuration error: \(msg)"
    case .execFailed(let msg): return "exec failed: \(msg)"
    }
  }
}

// MARK: - Privilege management

enum Privileges {
  /// Drop root privileges to the given user using setuid/setgid.
  static func drop(to username: String) throws {
    guard let pw = getpwnam(username) else {
      throw BootstrapError.userNotFound(username)
    }

    let uid = pw.pointee.pw_uid
    let gid = pw.pointee.pw_gid
    let home = String(cString: pw.pointee.pw_dir)

    guard initgroups(username, gid) == 0 else {
      throw BootstrapError.privilegeDropFailed(
        "initgroups: \(String(cString: strerror(errno)))")
    }
    guard setgid(gid) == 0 else {
      throw BootstrapError.privilegeDropFailed(
        "setgid: \(String(cString: strerror(errno)))")
    }
    guard setuid(uid) == 0 else {
      throw BootstrapError.privilegeDropFailed(
        "setuid: \(String(cString: strerror(errno)))")
    }

    setenv("HOME", home, 1)
    setenv("USER", username, 1)
    setenv("LOGNAME", username, 1)
    setenv("SHELL", "/bin/bash", 1)
  }
}

// MARK: - Helpers

enum Helpers {
  /// Read an environment variable.
  static func envVar(_ name: String) -> String? {
    guard let ptr = getenv(name) else { return nil }
    return String(cString: ptr)
  }

  /// Check if a command exists on PATH.
  static func commandExists(_ name: String) -> Bool {
    findCommand(name) != nil
  }

  /// Find the absolute path of a command on PATH.
  static func findCommand(_ name: String) -> String? {
    let searchPaths =
      (envVar("PATH")
      ?? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
      .split(separator: ":")
    for dir in searchPaths {
      let full = "\(dir)/\(name)"
      if access(full, X_OK) == 0 {
        return full
      }
    }
    return nil
  }

  /// Run a command synchronously via posix_spawnp. Throws on non-zero exit.
  @discardableResult
  static func run(
    command: String, arguments: [String], silent: Bool = false
  ) throws -> Int32 {
    let execPath: String
    if command.hasPrefix("/") {
      guard access(command, X_OK) == 0 else {
        throw BootstrapError.setupFailed("not executable: \(command)")
      }
      execPath = command
    } else {
      guard let found = findCommand(command) else {
        throw BootstrapError.setupFailed("command not found: \(command)")
      }
      execPath = found
    }

    let allArgs = [execPath] + arguments
    let cArgs = allArgs.map { strdup($0)! }
    var argv: [UnsafeMutablePointer<CChar>?] = cArgs + [nil]
    defer { cArgs.forEach { free($0) } }

    var fileActions = posix_spawn_file_actions_t()
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    var devNullFd: Int32 = -1
    if silent {
      devNullFd = open("/dev/null", O_WRONLY)
      if devNullFd >= 0 {
        posix_spawn_file_actions_adddup2(&fileActions, devNullFd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, devNullFd, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, devNullFd)
      }
    }

    var pid: pid_t = 0
    let spawnResult = posix_spawnp(
      &pid, execPath, &fileActions, nil, &argv, environ)
    if devNullFd >= 0 { close(devNullFd) }

    guard spawnResult == 0 else {
      throw BootstrapError.setupFailed(
        "\(command) spawn failed: \(String(cString: strerror(spawnResult)))")
    }

    var status: Int32 = 0
    waitpid(pid, &status, 0)

    // Manually compute WIFEXITED / WEXITSTATUS (C macros unavailable in Swift).
    let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1

    guard exitCode == 0 else {
      throw BootstrapError.setupFailed(
        "\(command) \(arguments.joined(separator: " ")) exited with \(exitCode)"
      )
    }
    return exitCode
  }

  /// Create a directory and any missing parents.
  static func mkdirp(_ path: String) {
    try? FileManager.default.createDirectory(
      atPath: path, withIntermediateDirectories: true, attributes: nil)
  }

  /// Recursively change ownership. Best-effort, errors are silently ignored.
  static func chownRecursive(_ path: String, uid: uid_t, gid: gid_t) {
    chown(path, uid, gid)
    guard let enumerator = FileManager.default.enumerator(atPath: path)
    else { return }
    while let relative = enumerator.nextObject() as? String {
      chown("\(path)/\(relative)", uid, gid)
    }
  }

  /// Replace the current process with the given command (exec).
  /// Does not return on success.
  static func execReplace(command: [String]) -> Never {
    guard !command.isEmpty else {
      fputs("agentc-bootstrap: exec failed: empty command\n", stderr)
      _exit(127)
    }

    var cStrings =
      command.map { strdup($0)! } as [UnsafeMutablePointer<CChar>?]
    cStrings.append(nil)

    execvp(cStrings[0]!, &cStrings)

    // execvp only returns on failure.
    let err = String(cString: strerror(errno))
    fputs("agentc-bootstrap: exec \(command[0]): \(err)\n", stderr)
    _exit(127)
  }
}
