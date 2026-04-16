import Crypto
import Foundation
import Subprocess

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
    let result = try await run(
      .path(FilePath(agentcPath)),
      arguments: Arguments(args),
      environment: .inherit.updating(overrides),
      workingDirectory: cwd.map { FilePath($0) },
      output: .string(limit: 512 * 1024),
      error: .string(limit: 512 * 1024)
    )
    let exitCode: Int32
    switch result.terminationStatus {
    case .exited(let code): exitCode = code
    case .signaled(let sig): exitCode = sig
    }
    return ProcessOutput(exitCode: exitCode, stdout: result.standardOutput ?? "", stderr: result.standardError ?? "")
  } catch {
    return ProcessOutput(exitCode: -1, stdout: "", stderr: "launch error: \(error)")
  }
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
  FileManager.default.createFile(
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
