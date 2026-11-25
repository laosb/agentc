import Subprocess

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

/// Manages the agent-isolation-configurations git repository (clone / pull).
enum ConfigurationsManager {
  static let defaultRepo = "https://github.com/laosb/agent-isolation-configurations"
  static let defaultUpdateInterval = 86400

  enum UpdateResult: Sendable, Equatable {
    case cloned(revision: String?)
    case updated(from: String?, to: String?)
    case upToDate(revision: String?)
  }

  struct CommitInfo: Sendable, Equatable {
    let revision: String
    let committedAt: String?
    let subject: String?

    var shortRevision: String {
      String(revision.prefix(7))
    }
  }

  enum Freshness: Sendable, Equatable {
    case notCloned
    case upToDate
    case staleRemote(remoteRevision: String)
    case staleLocal(remoteError: String?)
    case remoteUnavailable(remoteError: String?)
  }

  struct Status: Sendable, Equatable {
    let directory: URL
    let isCloned: Bool
    let repoURL: String?
    let localCommit: CommitInfo?
    let lastUpdated: Date?
    let freshness: Freshness

    var isStale: Bool {
      switch freshness {
      case .notCloned, .staleRemote, .staleLocal:
        return true
      case .upToDate, .remoteUnavailable:
        return false
      }
    }
  }

  /// Resolve the local configurations directory, honoring an explicit override.
  static func resolveDirectory(explicit: String?) -> URL {
    if let explicit, !explicit.isEmpty {
      return URL(fileURLWithPath: explicit)
    }
    return MigrationCheck.homeDir.appendingPathComponent(".agentc/configurations")
  }

  /// Inspect the local configurations repository and check whether it is stale.
  ///
  /// When `checkRemote` is enabled and an `origin` remote is configured, queries
  /// the remote's `HEAD` (or tracked branch) without modifying the local repo.
  /// If the remote cannot be reached, falls back to checking `.agentc-last-pull`
  /// against `updateInterval`.
  static func status(
    at dir: URL,
    updateInterval: Int? = nil,
    checkRemote: Bool = true
  ) async -> Status {
    let gitDir = dir.appendingPathComponent(".git")
    guard FileManager.default.fileExists(atPath: gitDir.path) else {
      return Status(
        directory: dir,
        isCloned: false,
        repoURL: nil,
        localCommit: nil,
        lastUpdated: nil,
        freshness: .notCloned
      )
    }

    let repoURL = await originURL(in: dir)
    let localCommit = await headCommit(in: dir)
    let lastUpdated = lastPullDate(in: dir)
    let interval = updateInterval ?? defaultUpdateInterval
    let locallyStale = isMarkerStale(lastUpdated: lastUpdated, interval: interval)

    let freshness: Freshness
    if checkRemote, repoURL != nil {
      let remote = await remoteHeadRevision(in: dir)
      if let remoteRevision = remote.revision {
        if localCommit?.revision == remoteRevision {
          freshness = .upToDate
        } else {
          freshness = .staleRemote(remoteRevision: remoteRevision)
        }
      } else if locallyStale {
        freshness = .staleLocal(remoteError: remote.error)
      } else {
        freshness = .remoteUnavailable(remoteError: remote.error)
      }
    } else if repoURL == nil {
      freshness =
        locallyStale
        ? .staleLocal(remoteError: "no origin remote configured")
        : .remoteUnavailable(remoteError: "no origin remote configured")
    } else {
      freshness = locallyStale ? .staleLocal(remoteError: nil) : .upToDate
    }

    return Status(
      directory: dir,
      isCloned: true,
      repoURL: repoURL,
      localCommit: localCommit,
      lastUpdated: lastUpdated,
      freshness: freshness
    )
  }

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

    try await withLock(for: dir) {
      let gitDir = dir.appendingPathComponent(".git")

      if !FileManager.default.fileExists(atPath: gitDir.path) {
        try await cloneRepo(from: repo, to: dir)
        return
      }

      // Check if update is needed
      if !isMarkerStale(lastUpdated: lastPullDate(in: dir), interval: interval) {
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
      touchLastPullMarker(in: dir)
    }
  }

  /// Immediately clone or pull the configurations repo, ignoring the update interval.
  ///
  /// Unlike ``ensureRepo(at:repoURL:updateInterval:)``, pull failures are reported
  /// as errors and do not update the `.agentc-last-pull` timestamp.
  static func updateRepo(
    at dir: URL,
    repoURL: String? = nil
  ) async throws -> UpdateResult {
    try await withLock(for: dir) {
      let gitDir = dir.appendingPathComponent(".git")

      if !FileManager.default.fileExists(atPath: gitDir.path) {
        let repo = (repoURL?.isEmpty == false ? repoURL : nil) ?? defaultRepo
        try await cloneRepo(from: repo, to: dir)
        return .cloned(revision: await headRevision(in: dir))
      }

      let before = await headRevision(in: dir)

      var arguments = ["-C", dir.path, "pull", "--ff-only", "--quiet"]
      if let explicitRepo = repoURL, !explicitRepo.isEmpty,
        await originURL(in: dir) != explicitRepo
      {
        arguments.append(explicitRepo)
      }

      let result = try await run(
        .path("/usr/bin/git"),
        arguments: Arguments(arguments),
        output: .discarded,
        error: .string(limit: 65_536)
      )
      guard result.terminationStatus.isSuccess else {
        throw AgentcError.configRepoError(
          formatGitError(
            "Failed to update configurations repo in \(dir.path)",
            stderr: result.standardError
          )
        )
      }

      touchLastPullMarker(in: dir)

      let after = await headRevision(in: dir)
      if before != after {
        return .updated(from: before, to: after)
      }
      return .upToDate(revision: after)
    }
  }

  // MARK: - Private helpers

  private static func withLock<T>(
    for dir: URL,
    _ body: () async throws -> T
  ) async throws -> T {
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

    return try await body()
  }

  private static func cloneRepo(from repo: String, to dir: URL) async throws {
    // Remove dir if it exists but isn't a valid git repo
    if FileManager.default.fileExists(atPath: dir.path) {
      try FileManager.default.removeItem(at: dir)
    }
    logger.info("Cloning configurations repo...")
    let result = try await run(
      .path("/usr/bin/git"),
      arguments: ["clone", "--depth", "1", "--quiet", repo, dir.path],
      output: .discarded,
      error: .string(limit: 65_536)
    )
    guard result.terminationStatus.isSuccess else {
      throw AgentcError.configRepoError(
        formatGitError(
          "Failed to clone configurations repo from \(repo)",
          stderr: result.standardError
        )
      )
    }
    touchLastPullMarker(in: dir)
  }

  private static func touchLastPullMarker(in dir: URL) {
    let markerFile = dir.appendingPathComponent(".agentc-last-pull")
    _ = FileManager.default.createFile(atPath: markerFile.path, contents: nil)
  }

  private static func lastPullDate(in dir: URL) -> Date? {
    let markerFile = dir.appendingPathComponent(".agentc-last-pull")
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: markerFile.path) else {
      return nil
    }
    return attrs[.modificationDate] as? Date
  }

  private static func isMarkerStale(lastUpdated: Date?, interval: Int, now: Date = Date()) -> Bool {
    guard let lastUpdated else { return true }
    return now.timeIntervalSince(lastUpdated) >= Double(interval)
  }

  private static func headRevision(in dir: URL) async -> String? {
    guard
      let result = try? await run(
        .path("/usr/bin/git"),
        arguments: ["-C", dir.path, "rev-parse", "HEAD"],
        output: .string(limit: 256),
        error: .discarded
      ),
      result.terminationStatus.isSuccess
    else {
      return nil
    }
    let rev = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    return rev.isEmpty ? nil : rev
  }

  private static func headCommit(in dir: URL) async -> CommitInfo? {
    guard
      let result = try? await run(
        .path("/usr/bin/git"),
        arguments: ["-C", dir.path, "log", "-1", "--format=%H%n%cI%n%s"],
        output: .string(limit: 4096),
        error: .discarded
      ),
      result.terminationStatus.isSuccess
    else {
      return nil
    }
    let lines = result.standardOutput.split(
      separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
    guard let first = lines.first else { return nil }
    let revision = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !revision.isEmpty else { return nil }

    let committedAt: String? =
      lines.count > 1
      ? {
        let value = String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
      }()
      : nil
    let subject: String? =
      lines.count > 2
      ? {
        let value = String(lines[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
      }()
      : nil

    return CommitInfo(revision: revision, committedAt: committedAt, subject: subject)
  }

  private static func originURL(in dir: URL) async -> String? {
    guard
      let result = try? await run(
        .path("/usr/bin/git"),
        arguments: ["-C", dir.path, "remote", "get-url", "origin"],
        output: .string(limit: 4096),
        error: .discarded
      ),
      result.terminationStatus.isSuccess
    else {
      return nil
    }
    let url = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    return url.isEmpty ? nil : url
  }

  private static func upstreamBranchRef(in dir: URL) async -> String? {
    guard
      let result = try? await run(
        .path("/usr/bin/git"),
        arguments: ["-C", dir.path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
        output: .string(limit: 256),
        error: .discarded
      ),
      result.terminationStatus.isSuccess
    else {
      return nil
    }
    let upstream = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard upstream.hasPrefix("origin/") else { return nil }
    let branch = String(upstream.dropFirst("origin/".count))
    return branch.isEmpty ? nil : "refs/heads/\(branch)"
  }

  private static func remoteHeadRevision(in dir: URL) async -> (revision: String?, error: String?) {
    let ref = await upstreamBranchRef(in: dir) ?? "HEAD"
    do {
      let result = try await run(
        .path("/usr/bin/git"),
        arguments: [
          "-C", dir.path,
          "-c", "http.lowSpeedLimit=1",
          "-c", "http.lowSpeedTime=5",
          "ls-remote", "--quiet", "origin", ref,
        ],
        environment: .inherit.updating(["GIT_TERMINAL_PROMPT": "0"]),
        output: .string(limit: 4096),
        error: .string(limit: 4096)
      )
      guard result.terminationStatus.isSuccess else {
        let err = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return (nil, err.isEmpty ? "git ls-remote failed" : err)
      }
      let firstLine = result.standardOutput.split(separator: "\n", maxSplits: 1).first
      if let token = firstLine?.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
        !token.isEmpty
      {
        return (String(token), nil)
      }
      return (nil, "remote ref '\(ref)' not found")
    } catch {
      return (nil, error.localizedDescription)
    }
  }

  private static func formatGitError(_ prefix: String, stderr: String) -> String {
    let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !detail.isEmpty else {
      return prefix
    }
    return "\(prefix): \(detail)"
  }
}

// MARK: - Errors

enum AgentcError: LocalizedError {
  case configRepoError(String)
  case bootstrapNotFound(String)
  case bootstrapDownloadFailed(String)
  case runtimeNotAvailable(String)
  case imageManagementNotSupported(String)
  case imageNotFound(String)
  /// A profile-ownership lifecycle failure, already phrased for a user.
  case profileOwnership(String)

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
    case .imageManagementNotSupported(let runtime):
      return "agentc: runtime '\(runtime)' does not support image management"
    case .imageNotFound(let reference):
      return "agentc: image '\(reference)' was not found"
    case .profileOwnership(let message):
      return "agentc: \(message)"
    }
  }
}
