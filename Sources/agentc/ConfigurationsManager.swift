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

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

import Subprocess

/// Manages the agent-isolation-configurations git repository (clone / pull).
enum ConfigurationsManager {
  static let defaultRepo = "https://github.com/laosb/agent-isolation-configurations"
  static let defaultUpdateInterval = 86400

  /// Ensure the configurations repo is cloned and up-to-date.
  ///
  /// Uses advisory file locking (`flock`) to prevent concurrent processes from
  /// racing on clone or pull operations.
  static func ensureRepo(
    at dir: URL,
    repoURL: String? = nil,
    updateInterval: Int? = nil
  ) async throws {
    let repo = repoURL ?? defaultRepo
    let interval = updateInterval ?? defaultUpdateInterval

    let parentDir = dir.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

    // Acquire an exclusive file lock so parallel processes don't race.
    let lockPath = parentDir.appendingPathComponent(".configurations.lock").path
    let lockFD = open(lockPath, O_RDWR | O_CREAT, 0o644)
    guard lockFD >= 0 else {
      throw AgentcError.configRepoError("Failed to create configurations lock file")
    }
    defer {
      flock(lockFD, LOCK_UN)
      close(lockFD)
    }
    guard flock(lockFD, LOCK_EX) == 0 else {
      throw AgentcError.configRepoError("Failed to acquire configurations lock")
    }

    let gitDir = dir.appendingPathComponent(".git")

    if !FileManager.default.fileExists(atPath: gitDir.path) {
      // Remove dir if it exists but isn't a valid git repo
      if FileManager.default.fileExists(atPath: dir.path) {
        try FileManager.default.removeItem(at: dir)
      }
      writeToStderr("agentc: cloning configurations repo...\n")
      let result = try await run(
        .path("/usr/bin/git"),
        arguments: ["clone", "--depth", "1", repo, dir.path],
        output: .discarded
      )
      guard result.terminationStatus.isSuccess else {
        throw AgentcError.configRepoError(
          "Failed to clone configurations repo from \(repo)")
      }
      return
    }

    // Check if update is needed
    let markerFile = dir.appendingPathComponent(".agentc-last-pull")
    let now = Date()
    if let attrs = try? FileManager.default.attributesOfItem(atPath: markerFile.path),
      let modified = attrs[.modificationDate] as? Date,
      now.timeIntervalSince(modified) < Double(interval)
    {
      return  // Recently updated
    }

    // Pull updates
    _ = try? await run(
      .path("/usr/bin/git"),
      arguments: ["-C", dir.path, "pull", "--ff-only", "--quiet"],
      output: .discarded,
      error: .discarded
    )
    // Update marker regardless of pull success (avoid repeated failures)
    FileManager.default.createFile(atPath: markerFile.path, contents: nil)
  }
}

// MARK: - Errors

enum AgentcError: LocalizedError {
  case configRepoError(String)
  case bootstrapNotFound(String)
  case bootstrapDownloadFailed(String)
  case runtimeNotAvailable(String)

  var errorDescription: String? {
    switch self {
    case .configRepoError(let message):
      return "agentc: \(message)"
    case .bootstrapNotFound(let message):
      return "agentc: \(message)"
    case .bootstrapDownloadFailed(let message):
      return "agentc: \(message)"
    case .runtimeNotAvailable(let runtime):
      return "agentc: runtime '\(runtime)' is not available in this build"
    }
  }
}
