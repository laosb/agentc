import Foundation
import Testing

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
    #expect(
      FileManager.default.fileExists(
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
