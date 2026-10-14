import Crypto
import Foundation
import Subprocess
import Testing

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

// MARK: - Process Helper

struct ProcessOutput: Sendable {
  let exitCode: Int32
  let stdout: String
  let stderr: String
  var output: String { stdout + stderr }

  /// A one-line account of how the run ended, for ``expectSuccess(_:sourceLocation:)``
  /// to compare against.
  ///
  /// The usual way to read a run is `swift test | grep 􀢄`, and swift-testing prints
  /// an expectation's comment on the lines *after* the one carrying that marker — so
  /// a message attached there is exactly what such a filter throws away. Comparing a
  /// summary rather than the raw exit code puts the reason inside the expanded
  /// expression, which is on the marker line itself and survives the filter.
  var summary: String {
    guard exitCode != 0 else { return "exited 0" }
    let reason =
      (stderr.isEmpty ? stdout : stderr)
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .suffix(2)
      .joined(separator: " / ")
    guard !reason.isEmpty else { return "exited \(exitCode) with no output" }
    return "exited \(exitCode): \(reason.suffix(400))"
  }
}

func runAgentc(
  args: [String],
  env: [String: String] = [:],
  cwd: String? = nil
) async -> ProcessOutput {
  let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AgentcHelpers.swift
    .deletingLastPathComponent()  // AgentcIntegrationTests/
    .deletingLastPathComponent()  // Tests/
  let agentcPath = repoRoot.appendingPathComponent("agentc").path

  // Build environment overrides: remove agentc internal vars, add test-specific ones
  var overrides: [Environment.Key: String?] = [
    "AGENTC_CONFIGURATIONS": nil,
    "AGENTC_ENTRYPOINT_OVERRIDE": nil,
  ]
  for (key, value) in env {
    overrides[Environment.Key(stringLiteral: key)] = value
  }

  do {
    // Never inherit the checkout's CWD: its development .agentc settings would
    // override CLI defaults (including the image) in otherwise unrelated tests.
    // Keep explicit CWDs for tests that exercise project-settings discovery.
    let isolatedDirectory = cwd == nil
      ? FileManager.default.temporaryDirectory
        .appendingPathComponent("agentc-integration-\(UUID().uuidString)")
      : nil
    if let isolatedDirectory {
      try FileManager.default.createDirectory(
        at: isolatedDirectory, withIntermediateDirectories: true)
    }
    defer {
      if let isolatedDirectory {
        try? FileManager.default.removeItem(at: isolatedDirectory)
      }
    }
    let workingDirectory = cwd ?? isolatedDirectory!.path

    let result = try await run(
      .path(FilePath(agentcPath)),
      arguments: Arguments(args),
      environment: .inherit.updating(overrides),
      workingDirectory: FilePath(workingDirectory),
      output: .string(limit: 512 * 1024),
      error: .string(limit: 512 * 1024)
    )
    let exitCode: Int32
    var stderr = result.standardError
    switch result.terminationStatus {
    case .exited(let code):
      exitCode = code
    case .signaled(let sig):
      // A signal is not an exit code. Reporting it as one turns "the binary never
      // started" into a puzzling `exitCode == 9` with no output at all, so say what
      // happened in the text the failing expectation prints.
      exitCode = sig
      stderr += "\n<agentc was killed by signal \(sig)"
      stderr +=
        sig == SIGKILL
        ? "; on macOS a binary whose code signature no longer matches is killed at "
          + "launch — rebuild it with ./build.sh>"
        : ">"
    }
    return ProcessOutput(
      exitCode: exitCode, stdout: result.standardOutput, stderr: stderr)
  } catch {
    return ProcessOutput(exitCode: -1, stdout: "", stderr: "launch error: \(error)")
  }
}

// MARK: - Assertions

/// Assert that an `agentc` run succeeded, and say why when it did not.
///
/// `#expect(result.exitCode == 0)` prints the number and nothing else, so every
/// container failure — a boot that never came up, a mount that was refused, a
/// configuration that could not be read — arrives as the same opaque line. The
/// comparison is against ``ProcessOutput/summary`` so the reason travels on the
/// failure line itself; the whole output follows as a comment for anyone reading
/// the run unfiltered.
func expectSuccess(
  _ result: ProcessOutput,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(
    result.summary == "exited 0",
    """
    --- stdout ---
    \(result.stdout)
    --- stderr ---
    \(result.stderr)
    """,
    sourceLocation: sourceLocation)
}

func sha256Hex(_ string: String) -> String {
  let data = Data(string.utf8)
  let digest = SHA256.hash(data: data)
  return digest.map { String(format: "%02x", $0) }.joined()
}

func workspaceContainerPath(for ws: URL) -> String {
  let canonicalPath = ws.resolvingSymlinksInPath().path
  let resolvedPath: String
  #if os(macOS)
    resolvedPath = canonicalPath.hasPrefix("/tmp") ? "/private" + canonicalPath : canonicalPath
  #else
    resolvedPath = canonicalPath
  #endif
  let hash = sha256Hex(resolvedPath)
  let folderName = URL(fileURLWithPath: resolvedPath).lastPathComponent
  return "/workspace/\(folderName)-\(String(hash.suffix(10)))"
}

// MARK: - Stub Helper

func stubProfileHome(at homeDir: URL) throws {
  let fm = FileManager.default
  try fm.createDirectory(
    at: homeDir.appendingPathComponent(".claude/bin"),
    withIntermediateDirectories: true)
  try fm.createDirectory(
    at: homeDir.appendingPathComponent(".bun/bin"),
    withIntermediateDirectories: true)

  let bunBin = homeDir.appendingPathComponent(".bun/bin/bun")
  try "#!/bin/sh\nexit 0\n".write(to: bunBin, atomically: true, encoding: .utf8)
  try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bunBin.path)

  let claudeBin = homeDir.appendingPathComponent(".claude/bin/claude")
  try "#!/bin/sh\nexit 0\n".write(to: claudeBin, atomically: true, encoding: .utf8)
  try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeBin.path)
}

// MARK: - Shared Profile

let sharedProfile: String = {
  let profileName = "__TEST_agentc_shared"
  let profileDir = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".agentc/profiles/\(profileName)/home")
  try? stubProfileHome(at: profileDir)
  return profileName
}()

// MARK: - Shared Configurations Directory

/// A stub configurations directory used by shared-profile tests so the real
/// configurations repo (which installs Bun/Claude) is never cloned.
let sharedConfigurationsDir: String = {
  let dir = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".agentc/test-configurations")
  let claudeDir = dir.appendingPathComponent("claude")
  try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

  try? """
  {"v":0,"entrypoint":["/bin/bash"],"additionalBinPaths":["$HOME/.bun/bin","$HOME/.claude/bin","$HOME/.local/bin"],"additionalMounts":[]}
  """.write(
    to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

  let prepareScript = claudeDir.appendingPathComponent("prepare.sh")
  try? "#!/bin/sh\n# No-op for tests\n".write(to: prepareScript, atomically: true, encoding: .utf8)
  try? FileManager.default.setAttributes(
    [.posixPermissions: 0o755], ofItemAtPath: prepareScript.path)

  // Create a .git directory so ConfigurationsManager.ensureRepo skips cloning.
  let gitDir = dir.appendingPathComponent(".git")
  if !FileManager.default.fileExists(atPath: gitDir.path) {
    try? FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
  }

  // Touch the pull-marker so ensureRepo doesn't try to pull (there's no remote).
  _ = FileManager.default.createFile(
    atPath: dir.appendingPathComponent(".agentc-last-pull").path, contents: nil)

  return dir.path
}()

// MARK: - Local Config Repo

func createLocalConfigRepo(at repoDir: URL) async throws {
  let fm = FileManager.default
  let claudeDir = repoDir.appendingPathComponent("claude")
  try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

  try """
  {"v":0,"dependsOn":[],"additionalMounts":[],"additionalBinPaths":[],"entrypoint":["echo","config-ok"]}
  """.write(
    to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
  try "#!/bin/bash\n".write(
    to: claudeDir.appendingPathComponent("prepare.sh"), atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755], ofItemAtPath: claudeDir.appendingPathComponent("prepare.sh").path)

  for args: [String] in [
    ["init"],
    ["add", "."],
    ["-c", "user.email=test@test.com", "-c", "user.name=Test", "commit", "-m", "init"],
  ] {
    let result = try await run(
      .path("/usr/bin/git"),
      arguments: Arguments(["-C", repoDir.path] + args),
      output: .discarded,
      error: .discarded
    )
    guard result.terminationStatus.isSuccess else {
      fatalError("git \(args.joined(separator: " ")) failed in createLocalConfigRepo")
    }
  }
}
