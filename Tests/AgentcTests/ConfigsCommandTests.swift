import Foundation
import Testing

@testable import agentc

@Suite("Configs command")
struct ConfigsCommandTests {
  @Test("Parses agentc configs and agentc configs update options")
  func parseOptions() throws {
    let defaultStatus = try #require(
      AgentcCommand.parseAsRoot([
        "configs",
        "--configurations-dir", "/tmp/my-configs",
        "--configurations-update-interval", "3600",
      ]) as? ConfigsStatusCommand)
    #expect(defaultStatus.configurationsDir == "/tmp/my-configs")
    #expect(defaultStatus.configurationsUpdateInterval == 3600)

    let explicitStatus = try #require(
      AgentcCommand.parseAsRoot([
        "configs", "status", "--configurations-dir", "/tmp/my-configs",
      ]) as? ConfigsStatusCommand)
    #expect(explicitStatus.configurationsDir == "/tmp/my-configs")

    let update = try #require(
      AgentcCommand.parseAsRoot([
        "configs", "update",
        "--configurations-dir", "/tmp/my-configs",
        "--configurations-repo", "https://example.com/configs.git",
        "--verbose",
      ]) as? ConfigsUpdateCommand)
    #expect(update.configurationsDir == "/tmp/my-configs")
    #expect(update.configurationsRepo == "https://example.com/configs.git")
    #expect(update.logging.verbose)
  }

  @Test("status reports notCloned, upToDate, staleRemote, and offline fallback states")
  func statusStates() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let (bare, seed) = try makeRemoteGitRepo(in: root)
    let repoURL = "file://\(bare.path)"
    let localDir = root.appendingPathComponent("configurations")

    // 1. Not cloned yet
    let missing = await ConfigurationsManager.status(at: localDir)
    #expect(!missing.isCloned)
    #expect(missing.freshness == .notCloned)
    #expect(missing.isStale)

    // 2. Cloned and up to date
    let cloned = try await ConfigurationsManager.updateRepo(at: localDir, repoURL: repoURL)
    guard case .cloned(let firstRev) = cloned, let firstRev else {
      Issue.record("Expected .cloned with revision")
      return
    }

    let upToDate = await ConfigurationsManager.status(at: localDir)
    #expect(upToDate.isCloned)
    #expect(upToDate.repoURL == repoURL)
    #expect(upToDate.localCommit?.revision == firstRev)
    #expect(upToDate.localCommit?.subject == "initial config")
    #expect(upToDate.localCommit?.committedAt != nil)
    #expect(upToDate.lastUpdated != nil)
    #expect(upToDate.freshness == .upToDate)
    #expect(!upToDate.isStale)

    // 3. Push a new commit -> detected as staleRemote
    try commitFile(
      in: seed,
      relativePath: "claude/settings.json",
      contents: "{\"version\":2}\n",
      message: "bump config")
    try runGit(["-C", seed.path, "push", "origin", "HEAD"])

    let staleRemote = await ConfigurationsManager.status(at: localDir)
    guard case .staleRemote(let remoteRev) = staleRemote.freshness else {
      Issue.record("Expected .staleRemote, got \(staleRemote.freshness)")
      return
    }
    #expect(remoteRev != firstRev)
    #expect(staleRemote.localCommit?.revision == firstRev)
    #expect(staleRemote.isStale)

    // 4. Unreachable remote: fresh marker -> remoteUnavailable; expired interval -> staleLocal
    try runGit([
      "-C", localDir.path, "remote", "set-url", "origin",
      "file://\(root.appendingPathComponent("missing.git").path)",
    ])
    let offlineFresh = await ConfigurationsManager.status(at: localDir, updateInterval: 86400)
    guard case .remoteUnavailable(let err) = offlineFresh.freshness else {
      Issue.record("Expected .remoteUnavailable, got \(offlineFresh.freshness)")
      return
    }
    #expect(err != nil)
    #expect(!offlineFresh.isStale)

    let offlineStale = await ConfigurationsManager.status(at: localDir, updateInterval: 0)
    guard case .staleLocal(let staleErr) = offlineStale.freshness else {
      Issue.record("Expected .staleLocal, got \(offlineStale.freshness)")
      return
    }
    #expect(staleErr != nil)
    #expect(offlineStale.isStale)
  }

  @Test("updateRepo clones, detects up-to-date, and pulls new commits regardless of interval")
  func updateRepoLifecycle() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let (bare, seed) = try makeRemoteGitRepo(in: root)
    let repoURL = "file://\(bare.path)"
    let localDir = root.appendingPathComponent("configurations")

    // 1. Fresh clone
    let cloned = try await ConfigurationsManager.updateRepo(at: localDir, repoURL: repoURL)
    guard case .cloned(let firstRev) = cloned else {
      Issue.record("Expected .cloned, got \(cloned)")
      return
    }
    #expect(firstRev != nil)
    #expect(
      FileManager.default.fileExists(
        atPath: localDir.appendingPathComponent(".agentc-last-pull").path))
    #expect(
      try String(
        contentsOf: localDir.appendingPathComponent("claude/settings.json"), encoding: .utf8)
        == "{\"version\":1}\n")

    // 2. Immediate second update reports upToDate
    let same = try await ConfigurationsManager.updateRepo(at: localDir, repoURL: repoURL)
    #expect(same == .upToDate(revision: firstRev))

    // 3. Push a new commit to the remote; updateRepo pulls immediately despite fresh marker
    try commitFile(
      in: seed,
      relativePath: "claude/settings.json",
      contents: "{\"version\":2}\n",
      message: "bump claude config")
    try runGit(["-C", seed.path, "push", "origin", "HEAD"])

    let updated = try await ConfigurationsManager.updateRepo(at: localDir, repoURL: repoURL)
    guard case .updated(let fromRev, let toRev) = updated else {
      Issue.record("Expected .updated, got \(updated)")
      return
    }
    #expect(fromRev == firstRev)
    #expect(toRev != nil)
    #expect(toRev != firstRev)
    #expect(
      try String(
        contentsOf: localDir.appendingPathComponent("claude/settings.json"), encoding: .utf8)
        == "{\"version\":2}\n")
  }

  @Test("updateRepo pulls from an explicit alternate repo URL when provided")
  func updateRepoAlternateURL() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let (bareA, seedA) = try makeRemoteGitRepo(in: root, name: "remote-a")
    let localDir = root.appendingPathComponent("configurations")
    _ = try await ConfigurationsManager.updateRepo(at: localDir, repoURL: "file://\(bareA.path)")

    // Create a second bare repo forked from remote-a with an extra commit.
    let bareB = root.appendingPathComponent("remote-b.git")
    try runGit(["clone", "--bare", bareA.path, bareB.path])
    try commitFile(
      in: seedA,
      relativePath: "extra.txt",
      contents: "from-b\n",
      message: "add extra on B")
    try runGit(["-C", seedA.path, "push", bareB.path, "HEAD"])

    let updated = try await ConfigurationsManager.updateRepo(
      at: localDir, repoURL: "file://\(bareB.path)")
    guard case .updated = updated else {
      Issue.record("Expected .updated from alternate repo, got \(updated)")
      return
    }
    #expect(
      try String(contentsOf: localDir.appendingPathComponent("extra.txt"), encoding: .utf8)
        == "from-b\n")
  }

  @Test("updateRepo fails and preserves marker when pull cannot fast-forward")
  func updateRepoDivergedFails() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let (bare, seed) = try makeRemoteGitRepo(in: root)
    let localDir = root.appendingPathComponent("configurations")
    _ = try await ConfigurationsManager.updateRepo(at: localDir, repoURL: "file://\(bare.path)")

    // Remove the marker so we can verify a failed pull does not recreate it.
    let marker = localDir.appendingPathComponent(".agentc-last-pull")
    try FileManager.default.removeItem(at: marker)

    // Diverge local and remote histories.
    try runGit(["-C", localDir.path, "config", "user.email", "test@example.com"])
    try runGit(["-C", localDir.path, "config", "user.name", "Test"])
    try commitFile(
      in: localDir, relativePath: "local.txt", contents: "local\n", message: "local commit")
    try commitFile(
      in: seed, relativePath: "remote.txt", contents: "remote\n", message: "remote commit")
    try runGit(["-C", seed.path, "push", "origin", "HEAD"])

    await #expect(throws: AgentcError.self) {
      _ = try await ConfigurationsManager.updateRepo(at: localDir)
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test("agentc configs CLI inspects status, prompts when stale, and updates cleanly")
  func cliEndToEnd() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let (bare, seed) = try makeRemoteGitRepo(in: root)
    let repoURL = "file://\(bare.path)"
    let localDir = root.appendingPathComponent("configurations")

    // Before clone, `agentc configs` reports not cloned and prompts to update.
    let notClonedResult = try await runCLI([
      "configs", "--configurations-dir", localDir.path,
    ])
    #expect(notClonedResult.status == 0)
    #expect(notClonedResult.stdout.contains("not cloned"))
    #expect(notClonedResult.stdout.contains("agentc configs update"))

    // First update clones.
    let cloneResult = try await runCLI([
      "configs", "update",
      "--configurations-dir", localDir.path,
      "--configurations-repo", repoURL,
    ])
    #expect(cloneResult.status == 0)
    #expect(cloneResult.stdout.isEmpty)
    #expect(cloneResult.stderr.contains("Cloned configurations"))

    // `agentc configs` shows repo URL, local commit, and up-to-date status without update prompt.
    let statusUpToDate = try await runCLI([
      "configs", "--configurations-dir", localDir.path,
    ])
    #expect(statusUpToDate.status == 0)
    #expect(statusUpToDate.stdout.contains("repo:          \(repoURL)"))
    #expect(statusUpToDate.stdout.contains("initial config"))
    #expect(statusUpToDate.stdout.contains("status:        up to date"))
    #expect(!statusUpToDate.stdout.contains("agentc configs update"))

    // Second update is already up to date.
    let upToDateResult = try await runCLI([
      "configs", "update",
      "--configurations-dir", localDir.path,
    ])
    #expect(upToDateResult.status == 0)
    #expect(upToDateResult.stdout.isEmpty)
    #expect(upToDateResult.stderr.contains("already up to date"))

    // Push a commit -> `agentc configs` detects staleness and prompts `agentc configs update`.
    try commitFile(
      in: seed,
      relativePath: "claude/settings.json",
      contents: "{\"version\":3}\n",
      message: "v3")
    try runGit(["-C", seed.path, "push", "origin", "HEAD"])

    let statusStale = try await runCLI([
      "configs", "--configurations-dir", localDir.path,
    ])
    #expect(statusStale.status == 0)
    #expect(statusStale.stdout.contains("repo:          \(repoURL)"))
    #expect(statusStale.stdout.contains("remoteCommit:"))
    #expect(statusStale.stdout.contains("status:        stale"))
    #expect(statusStale.stdout.contains("Run `agentc configs update` to update."))

    // Update with --log-file.
    let logFile = root.appendingPathComponent("configs.log")
    let updateResult = try await runCLI([
      "configs", "update",
      "--configurations-dir", localDir.path,
      "--log-file", logFile.path,
      "--verbose",
    ])
    #expect(updateResult.status == 0)
    #expect(updateResult.stdout.isEmpty)
    #expect(updateResult.stderr.isEmpty)
    let logContents = try String(contentsOf: logFile, encoding: .utf8)
    #expect(logContents.contains("Updated configurations"))
    #expect(
      try String(
        contentsOf: localDir.appendingPathComponent("claude/settings.json"), encoding: .utf8)
        == "{\"version\":3}\n")

    // After updating, `agentc configs` reflects the new commit and up-to-date status.
    let statusAfterUpdate = try await runCLI([
      "configs", "--configurations-dir", localDir.path,
    ])
    #expect(statusAfterUpdate.status == 0)
    #expect(statusAfterUpdate.stdout.contains("(v3)"))
    #expect(statusAfterUpdate.stdout.contains("status:        up to date"))
    #expect(!statusAfterUpdate.stdout.contains("agentc configs update"))

    // Invalid repo URL fails cleanly with empty stdout.
    let missingDir = root.appendingPathComponent("missing-configs")
    let failResult = try await runCLI([
      "configs", "update",
      "--configurations-dir", missingDir.path,
      "--configurations-repo", "file://\(root.appendingPathComponent("does-not-exist.git").path)",
    ])
    #expect(failResult.status != 0)
    #expect(failResult.stdout.isEmpty)
    #expect(failResult.stderr.contains("Failed to clone configurations repo"))
  }

  // MARK: - Helpers

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("agentc-configs-test-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeRemoteGitRepo(in root: URL, name: String = "remote") throws
    -> (bare: URL, seed: URL)
  {
    let bare = root.appendingPathComponent("\(name).git")
    try runGit(["init", "--bare", bare.path])

    let seed = root.appendingPathComponent("\(name)-seed")
    try runGit(["clone", bare.path, seed.path])
    try runGit(["-C", seed.path, "config", "user.email", "test@example.com"])
    try runGit(["-C", seed.path, "config", "user.name", "Test"])

    try commitFile(
      in: seed,
      relativePath: "claude/settings.json",
      contents: "{\"version\":1}\n",
      message: "initial config")
    try runGit(["-C", seed.path, "push", "origin", "HEAD"])
    return (bare, seed)
  }

  private func commitFile(
    in repo: URL, relativePath: String, contents: String, message: String
  ) throws {
    let fileURL = repo.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: fileURL)
    try runGit(["-C", repo.path, "add", relativePath])
    try runGit(["-C", repo.path, "commit", "-m", message])
  }

  private func runGit(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    let stderr = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderr
    try process.run()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let message = String(decoding: errData, as: UTF8.self)
      throw NSError(
        domain: "ConfigsCommandTests",
        code: Int(process.terminationStatus),
        userInfo: [
          NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"
        ]
      )
    }
  }
}
