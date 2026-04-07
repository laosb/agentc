import Crypto
import Foundation
import Testing

/// Integration tests for the `claudec` binary. Requires:
/// - A pre-built `claudec` binary (via `build.sh`)
/// - The `container` CLI installed
/// - The container image pulled locally
///
/// These tests run the actual binary against real containers, ported from the
/// original `test.sh` bash test suite.

// MARK: - Process Helper

struct ProcessOutput: Sendable {
  let exitCode: Int32
  let stdout: String
  let stderr: String
  /// Combined stdout + stderr for convenience.
  var output: String { stdout + stderr }
}

private func runClaudec(
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

private func sha256Hex(_ string: String) -> String {
  let data = Data(string.utf8)
  let digest = SHA256.hash(data: data)
  return digest.map { String(format: "%02x", $0) }.joined()
}

/// Compute the new workspace container path for a given workspace URL.
private func workspaceContainerPath(for ws: URL) -> String {
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
private func stubProfileHome(at homeDir: URL) throws {
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
private let sharedProfile: String = {
  let profileName = "__TEST_shared_swift"
  let profileDir = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".claudec/profiles/\(profileName)/home")
  try? stubProfileHome(at: profileDir)
  return profileName
}()

private let bootstrapScriptPath: String = {
  let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  return repoRoot.appendingPathComponent("bootstrap.sh").path
}()

// MARK: - Tests

@Suite("claudec Integration Tests")
struct ClaudecIntegrationTests {

  init() {
    // Ensure shared profile is set up
    _ = sharedProfile
  }

  @Test("sh <command> runs command in container")
  func shCommand() async throws {
    let result = await runClaudec(
      env: [
        "CLAUDEC_PROFILE": sharedProfile,
        "CLAUDEC_BOOTSTRAP_SCRIPT": bootstrapScriptPath,
      ],
      arguments: ["sh", "echo", "hello"]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("hello"))
  }

  @Test("CLAUDEC_PROFILE creates profile dir at expected path")
  func profileName() async throws {
    let profile = "__TEST_profile_name_swift"
    let profileHome = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".claudec/profiles/\(profile)/home")
    try stubProfileHome(at: profileHome)
    defer { try? FileManager.default.removeItem(at: profileHome.deletingLastPathComponent()) }

    let result = await runClaudec(
      env: [
        "CLAUDEC_PROFILE": profile,
        "CLAUDEC_BOOTSTRAP_SCRIPT": bootstrapScriptPath,
      ],
      arguments: ["sh", "echo", "ok"]
    )
    #expect(result.exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: profileHome.path))
  }

  @Test("CLAUDEC_PROFILE_DIR mounts custom home dir into container")
  func profileDir() async throws {
    let dir = URL(fileURLWithPath: "/tmp/__TEST_profile_dir_swift.\(UUID().uuidString.prefix(6))")
    let homeDir = dir.appendingPathComponent("home")
    try stubProfileHome(at: homeDir)
    try "sentinel_content".write(
      to: homeDir.appendingPathComponent("sentinel.txt"),
      atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = await runClaudec(
      env: [
        "CLAUDEC_PROFILE_DIR": dir.path,
        "CLAUDEC_BOOTSTRAP_SCRIPT": bootstrapScriptPath,
      ],
      arguments: ["sh", "cat", "/home/agent/sentinel.txt"]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("sentinel_content"))
  }

  @Test("CLAUDEC_WORKSPACE mounts custom directory as workspace")
  func workspace() async throws {
    let ws = URL(fileURLWithPath: "/tmp/__TEST_ws_swift.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    try "workspace_content".write(
      to: ws.appendingPathComponent("probe.txt"),
      atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: ws) }

    let containerPath = workspaceContainerPath(for: ws)

    let result = await runClaudec(
      env: [
        "CLAUDEC_PROFILE": sharedProfile,
        "CLAUDEC_WORKSPACE": ws.path,
        "CLAUDEC_BOOTSTRAP_SCRIPT": bootstrapScriptPath,
      ],
      arguments: ["sh", "cat", "\(containerPath)/probe.txt"]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("workspace_content"))
  }

  @Test("CLAUDEC_WORKSPACE sets container working directory correctly")
  func workspaceCwd() async throws {
    let ws = URL(fileURLWithPath: "/tmp/__TEST_ws_cwd_swift.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: ws) }

    let containerPath = workspaceContainerPath(for: ws)

    let result = await runClaudec(
      env: [
        "CLAUDEC_PROFILE": sharedProfile,
        "CLAUDEC_WORKSPACE": ws.path,
        "CLAUDEC_BOOTSTRAP_SCRIPT": bootstrapScriptPath,
      ],
      arguments: ["sh", "pwd"]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains(containerPath))
  }

  @Test("CLAUDEC_EXCLUDE_FOLDERS hides sub-folder contents")
  func excludeFolders() async throws {
    let ws = URL(fileURLWithPath: "/tmp/__TEST_excl_swift.\(UUID().uuidString.prefix(6))")
    let secretDir = ws.appendingPathComponent("secret")
    try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
    try "sensitive_data".write(
      to: secretDir.appendingPathComponent("data.txt"),
      atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: ws) }

    let containerPath = workspaceContainerPath(for: ws)

    let result = await runClaudec(
      env: [
        "CLAUDEC_PROFILE": sharedProfile,
        "CLAUDEC_WORKSPACE": ws.path,
        "CLAUDEC_EXCLUDE_FOLDERS": "secret",
        "CLAUDEC_BOOTSTRAP_SCRIPT": bootstrapScriptPath,
      ],
      arguments: ["sh", "ls", "\(containerPath)/secret"]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  @Test("CLAUDEC_EXCLUDE_FOLDERS hides multiple comma-separated folders")
  func excludeFoldersMulti() async throws {
    let ws = URL(fileURLWithPath: "/tmp/__TEST_excl_multi_swift.\(UUID().uuidString.prefix(6))")
    for folder in ["folderA", "folderB"] {
      let dir = ws.appendingPathComponent(folder)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try "data".write(
        to: dir.appendingPathComponent("file.txt"),
        atomically: true, encoding: .utf8)
    }
    defer { try? FileManager.default.removeItem(at: ws) }

    let containerPath = workspaceContainerPath(for: ws)

    let resultA = await runClaudec(
      env: [
        "CLAUDEC_PROFILE": sharedProfile,
        "CLAUDEC_WORKSPACE": ws.path,
        "CLAUDEC_EXCLUDE_FOLDERS": "folderA,folderB",
        "CLAUDEC_BOOTSTRAP_SCRIPT": bootstrapScriptPath,
      ],
      arguments: ["sh", "ls", "\(containerPath)/folderA"]
    )
    let resultB = await runClaudec(
      env: [
        "CLAUDEC_PROFILE": sharedProfile,
        "CLAUDEC_WORKSPACE": ws.path,
        "CLAUDEC_EXCLUDE_FOLDERS": "folderA,folderB",
        "CLAUDEC_BOOTSTRAP_SCRIPT": bootstrapScriptPath,
      ],
      arguments: ["sh", "ls", "\(containerPath)/folderB"]
    )

    #expect(resultA.exitCode == 0)
    #expect(resultB.exitCode == 0)
    #expect(resultA.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(resultB.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  @Test("CLAUDEC_BOOTSTRAP_SCRIPT overrides bootstrap in container")
  func bootstrapScript() async throws {
    let customBootstrap = URL(
      fileURLWithPath: "/tmp/__TEST_bootstrap_swift.\(UUID().uuidString.prefix(6))")
    try """
    #!/bin/bash
    echo "custom_bootstrap_marker"
    if [ "${1:-}" = "sh" ]; then
        shift
        exec /bin/bash -c "$*"
    fi
    """.write(to: customBootstrap, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: customBootstrap.path)
    defer { try? FileManager.default.removeItem(at: customBootstrap) }

    let result = await runClaudec(
      env: [
        "CLAUDEC_PROFILE": sharedProfile,
        "CLAUDEC_BOOTSTRAP_SCRIPT": customBootstrap.path,
      ],
      arguments: ["sh", "echo", "ok"]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("custom_bootstrap_marker"))
  }

  @Test("Bun is available on PATH inside the container")
  func bunOnPath() async throws {
    let result = await runClaudec(
      env: [
        "CLAUDEC_PROFILE": sharedProfile,
        "CLAUDEC_BOOTSTRAP_SCRIPT": bootstrapScriptPath,
      ],
      arguments: ["sh", "command", "-v", "bun"]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("bun"))
  }

  @Test("Unsupported env vars cause error exit")
  func unsupportedEnvVars() async throws {
    for envVar in [
      "CLAUDEC_CONTAINER_FLAGS",
      "CLAUDEC_CHECK_UPDATE",
    ] {
      let result = await runClaudec(
        env: [
          "CLAUDEC_PROFILE": sharedProfile,
          envVar: "1",
        ],
        arguments: ["sh", "echo", "should-not-run"]
      )
      #expect(result.exitCode != 0, "\(envVar) should cause error")
      #expect(result.stderr.contains("not supported"), "\(envVar) should mention unsupported")
    }
  }
}

// MARK: - Configuration Repo Tests

/// Creates a local git repo mimicking agent-isolation-configurations with a
/// minimal `claude` configuration (no-op prepare, no additional bin paths).
private func createLocalConfigRepo(at repoDir: URL) throws {
  let fm = FileManager.default
  let claudeDir = repoDir.appendingPathComponent("claude")
  try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

  try """
  {"v":0,"dependsOn":[],"additionalMounts":[],"additionalBinPaths":[],"entrypoint":["echo","config-ok"]}
  """.write(to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
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

@Suite("Configuration Repo Integration Tests")
struct ConfigurationRepoIntegrationTests {

  @Test("Configurations repo is cloned on first run")
  func configurationsClone() async throws {
    let tempDir = URL(fileURLWithPath: "/tmp/__TEST_cfg_clone.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configsDir = tempDir.appendingPathComponent("configurations")
    let profileDir = tempDir.appendingPathComponent("profile")
    let localRepo = tempDir.appendingPathComponent("repo")

    try stubProfileHome(at: profileDir.appendingPathComponent("home"))
    try createLocalConfigRepo(at: localRepo)

    let result = await runClaudec(
      env: [
        "CLAUDEC_PROFILE_DIR": profileDir.path,
        "CLAUDEC_CONFIGURATIONS_DIR": configsDir.path,
        "CLAUDEC_CONFIGURATIONS_REPO": localRepo.path,
        "CLAUDEC_BOOTSTRAP_SCRIPT": bootstrapScriptPath,
      ],
      arguments: ["sh", "echo", "ok"]
    )
    #expect(result.exitCode == 0)
    #expect(result.stderr.contains("cloning configurations repo"))
    #expect(result.stdout.contains("ok"))
    #expect(FileManager.default.fileExists(
      atPath: configsDir.appendingPathComponent(".git").path))
  }

  @Test("Configurations repo is not re-cloned on subsequent runs")
  func configurationsNoReClone() async throws {
    let tempDir = URL(fileURLWithPath: "/tmp/__TEST_cfg_noclone.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configsDir = tempDir.appendingPathComponent("configurations")
    let profileDir = tempDir.appendingPathComponent("profile")
    let localRepo = tempDir.appendingPathComponent("repo")

    try stubProfileHome(at: profileDir.appendingPathComponent("home"))
    try createLocalConfigRepo(at: localRepo)

    let baseEnv: [String: String] = [
      "CLAUDEC_PROFILE_DIR": profileDir.path,
      "CLAUDEC_CONFIGURATIONS_DIR": configsDir.path,
      "CLAUDEC_CONFIGURATIONS_REPO": localRepo.path,
      "CLAUDEC_BOOTSTRAP_SCRIPT": bootstrapScriptPath,
    ]

    // First run — should clone
    let result1 = await runClaudec(env: baseEnv, arguments: ["sh", "echo", "first"])
    #expect(result1.exitCode == 0)
    #expect(result1.stderr.contains("cloning configurations repo"))

    // Second run — should NOT clone (pulls instead, silently)
    let result2 = await runClaudec(env: baseEnv, arguments: ["sh", "echo", "second"])
    #expect(result2.exitCode == 0)
    #expect(!result2.stderr.contains("cloning configurations repo"))
    #expect(result2.stdout.contains("second"))
  }

  @Test("Stale marker triggers update pull without re-clone")
  func configurationsStaleUpdate() async throws {
    let tempDir = URL(fileURLWithPath: "/tmp/__TEST_cfg_stale.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configsDir = tempDir.appendingPathComponent("configurations")
    let profileDir = tempDir.appendingPathComponent("profile")
    let localRepo = tempDir.appendingPathComponent("repo")

    try stubProfileHome(at: profileDir.appendingPathComponent("home"))
    try createLocalConfigRepo(at: localRepo)

    let baseEnv: [String: String] = [
      "CLAUDEC_PROFILE_DIR": profileDir.path,
      "CLAUDEC_CONFIGURATIONS_DIR": configsDir.path,
      "CLAUDEC_CONFIGURATIONS_REPO": localRepo.path,
      "CLAUDEC_BOOTSTRAP_SCRIPT": bootstrapScriptPath,
    ]

    // First run — clones the repo
    let result1 = await runClaudec(env: baseEnv, arguments: ["sh", "echo", "ok"])
    #expect(result1.exitCode == 0)
    #expect(result1.stderr.contains("cloning configurations repo"))

    // Second run — pulls (no marker yet after clone), creates marker
    let result2 = await runClaudec(env: baseEnv, arguments: ["sh", "echo", "ok"])
    #expect(result2.exitCode == 0)

    // Marker should now exist (created by the pull in run 2)
    let markerPath = configsDir.appendingPathComponent(".claudec-last-pull")
    #expect(FileManager.default.fileExists(atPath: markerPath.path))

    // Backdate the marker to make it stale
    let staleDate = Date().addingTimeInterval(-200_000)
    try FileManager.default.setAttributes(
      [.modificationDate: staleDate], ofItemAtPath: markerPath.path)

    // Run with interval=0 — should pull again and refresh marker
    var envWithInterval = baseEnv
    envWithInterval["CLAUDEC_CONFIGURATIONS_UPDATE_INTERVAL_SECONDS"] = "0"
    let result3 = await runClaudec(env: envWithInterval, arguments: ["sh", "echo", "updated"])
    #expect(result3.exitCode == 0)
    #expect(!result3.stderr.contains("cloning configurations repo"))
    #expect(result3.stdout.contains("updated"))

    // Marker should be freshly updated
    if let attrs = try? FileManager.default.attributesOfItem(atPath: markerPath.path),
      let mtime = attrs[.modificationDate] as? Date
    {
      #expect(Date().timeIntervalSince(mtime) < 60, "Marker should be freshly updated")
    }
  }

  @Test("CLAUDEC_CONFIGURATIONS_REPO overrides clone source")
  func configurationsCustomRepo() async throws {
    let tempDir = URL(fileURLWithPath: "/tmp/__TEST_cfg_repo.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configsDir = tempDir.appendingPathComponent("configurations")
    let profileDir = tempDir.appendingPathComponent("profile")
    let localRepo = tempDir.appendingPathComponent("custom-repo")

    try stubProfileHome(at: profileDir.appendingPathComponent("home"))
    try createLocalConfigRepo(at: localRepo)

    let result = await runClaudec(
      env: [
        "CLAUDEC_PROFILE_DIR": profileDir.path,
        "CLAUDEC_CONFIGURATIONS_DIR": configsDir.path,
        "CLAUDEC_CONFIGURATIONS_REPO": localRepo.path,
        "CLAUDEC_BOOTSTRAP_SCRIPT": bootstrapScriptPath,
      ],
      arguments: ["sh", "echo", "custom-ok"]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("custom-ok"))
    // Verify configurations from the custom repo are present
    let clonedSettings = configsDir.appendingPathComponent("claude/settings.json")
    #expect(FileManager.default.fileExists(atPath: clonedSettings.path))
  }
}
