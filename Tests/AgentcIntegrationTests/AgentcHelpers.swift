import Crypto
import Foundation

// MARK: - Process Helper

struct ProcessOutput: Sendable {
  let exitCode: Int32
  let stdout: String
  let stderr: String
  var output: String { stdout + stderr }
}

func runAgentc(
  args: [String],
  env: [String: String] = [:]
) async -> ProcessOutput {
  let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AgentcHelpers.swift
    .deletingLastPathComponent()  // AgentcIntegrationTests/
    .deletingLastPathComponent()  // Tests/
  let agentcPath = repoRoot.appendingPathComponent("agentc").path

  var environment = ProcessInfo.processInfo.environment
  // Clean environment for agentc tests
  environment.removeValue(forKey: "AGENTC_CONFIGURATIONS")
  environment.removeValue(forKey: "AGENTC_ENTRYPOINT_OVERRIDE")

  for (key, value) in env {
    environment[key] = value
  }

  return await withCheckedContinuation { continuation in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: agentcPath)
    process.arguments = args
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    process.terminationHandler = { p in
      let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
      let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
      let stderr = String(data: stderrData, encoding: .utf8) ?? ""
      continuation.resume(
        returning: ProcessOutput(exitCode: p.terminationStatus, stdout: stdout, stderr: stderr))
    }

    do {
      try process.run()
    } catch {
      continuation.resume(
        returning: ProcessOutput(exitCode: -1, stdout: "", stderr: "launch error: \(error)"))
    }
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

let bootstrapScriptPath: String = {
  let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  return repoRoot.appendingPathComponent("bootstrap.sh").path
}()

// MARK: - Local Config Repo

func createLocalConfigRepo(at repoDir: URL) throws {
  let fm = FileManager.default
  let claudeDir = repoDir.appendingPathComponent("claude")
  try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

  try """
  {"v":0,"dependsOn":[],"additionalMounts":[],"additionalBinPaths":[],"entrypoint":["echo","config-ok"]}
  """.write(
    to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
  try "#!/bin/bash\n".write(
    to: claudeDir.appendingPathComponent("prepare.sh"), atomically: true, encoding: .utf8)

  for args: [String] in [
    ["init"],
    ["add", "."],
    ["-c", "user.email=test@test.com", "-c", "user.name=Test", "commit", "-m", "init"],
  ] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", repoDir.path] + args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      fatalError("git \(args.joined(separator: " ")) failed in createLocalConfigRepo")
    }
  }
}
