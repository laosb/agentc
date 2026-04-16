import ArgumentParser

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// Checks whether the user should migrate from the legacy ~/.claudec directory.
///
/// Returns `true` if migration is needed and the user should be prompted.
/// Returns `false` if no migration is needed (either ~/.agentc exists, or
/// ~/.claudec doesn't exist, or the check is suppressed).
enum MigrationCheck {
  /// Resolve the user's home directory.
  ///
  /// Reads `HOME` from the process environment first (more reliable across
  /// platforms), falling back to `NSHomeDirectory()`.
  static var homeDir: URL {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
      return URL(fileURLWithPath: home)
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  /// The agentc data directory: ~/.agentc
  static var agentcDir: URL {
    homeDir.appendingPathComponent(".agentc")
  }

  /// The legacy claudec data directory: ~/.claudec
  static var claudecDir: URL {
    homeDir.appendingPathComponent(".claudec")
  }

  /// Check if migration from claudec is needed.
  ///
  /// Migration is needed when:
  /// 1. `~/.agentc` does NOT exist
  /// 2. `~/.claudec` DOES exist
  /// 3. `--suppress-migration-from-claudec` is NOT set
  ///
  /// When migration is needed, prints a message and exits with an error.
  static func checkIfNeeded(suppress: Bool) throws {
    guard !suppress else { return }

    let fm = FileManager.default

    // If ~/.agentc already exists, no migration needed
    guard !fm.fileExists(atPath: agentcDir.path) else { return }

    // If ~/.claudec doesn't exist, nothing to migrate
    guard fm.fileExists(atPath: claudecDir.path) else { return }

    // Migration needed
    let message = """
      agentc: Found existing ~/.claudec directory from the legacy claudec CLI.
      Run `agentc migrate-from-claudec` to migrate your profiles and configurations.
      Or use `--suppress-migration-from-claudec` to skip this check.

      """
    writeToStderr(message)
    throw ExitCode(1)
  }
}
