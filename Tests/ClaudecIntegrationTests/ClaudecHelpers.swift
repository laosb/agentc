import Crypto
import Foundation

// MARK: - Process Helper

struct ProcessOutput: Sendable {
  let exitCode: Int32
  let stdout: String
  let stderr: String
  /// Combined stdout + stderr for convenience.
  var output: String { stdout + stderr }
}

func runClaudec(
  env: [String: String] = [:],
  arguments: [String]
) async -> ProcessOutput {
  let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // ClaudecIntegrationTests.swift
    .deletingLastPathComponent()  // ClaudecIntegrationTests/
    .deletingLastPathComponent()  // Tests/
  let claudecPath = repoRoot.appendingPathComponent("claudec").path

  var environment = ProcessInfo.processInfo.environment
  // Disable unsupported legacy env vars and auto-update for tests
  environment.removeValue(forKey: "CLAUDEC_CHECK_UPDATE")
  environment.removeValue(forKey: "CLAUDEC_CONTAINER_FLAGS")
  environment["CLAUDEC_IMAGE_AUTO_UPDATE"] = "0"

  for (key, value) in env {
    environment[key] = value
  }

  return await withCheckedContinuation { continuation in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: claudecPath)
    process.arguments = arguments
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

/// Compute the new workspace container path for a given workspace URL.
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

/// Creates minimal stubs inside a profile home dir so bootstrap skips heavy installations.
func stubProfileHome(at homeDir: URL) throws {
  let fm = FileManager.default

  // The new configuration-based bootstrap reads from /agent-isolation/agents,
  // and configurations install tools as needed. For integration tests, we just
  // need the home dir to exist so the bootstrap can proceed.
  try fm.createDirectory(
    at: homeDir.appendingPathComponent(".claude/bin"),
    withIntermediateDirectories: true)
  try fm.createDirectory(
    at: homeDir.appendingPathComponent(".bun/bin"),
    withIntermediateDirectories: true)

  // Stub bun
  let bunBin = homeDir.appendingPathComponent(".bun/bin/bun")
  try "#!/bin/sh\nexit 0\n".write(to: bunBin, atomically: true, encoding: .utf8)
  try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bunBin.path)

  // Stub claude
  let claudeBin = homeDir.appendingPathComponent(".claude/bin/claude")
  try "#!/bin/sh\nexit 0\n".write(to: claudeBin, atomically: true, encoding: .utf8)
  try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeBin.path)
}

// MARK: - Shared Profile

/// Provides a shared test profile that persists across tests for speed.
let sharedProfile: String = {
  let profileName = "__TEST_shared_swift"
  let profileDir = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".claudec/profiles/\(profileName)/home")
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
