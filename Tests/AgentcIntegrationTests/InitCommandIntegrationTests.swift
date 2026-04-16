import Foundation
import Testing

@Suite("Init Command Integration Tests")
struct InitCommandIntegrationTests {
  init() {
    _ = sharedProfile
  }

  // MARK: - Settings file creation

  @Test("agentc init creates .agentc/settings.json with defaults")
  func initCreatesSettingsWithDefaults() async throws {
    let base = URL(fileURLWithPath: "/tmp/__TEST_agentc_init.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let result = await runAgentc(
      args: [
        "init",
        base.path,
        "--skip-container-init",
      ]
    )
    #expect(result.exitCode == 0)

    let settingsPath = base.appendingPathComponent(".agentc/settings.json")
    #expect(FileManager.default.fileExists(atPath: settingsPath.path))

    let data = try Data(contentsOf: settingsPath)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let agent = json["agent"] as! [String: Any]
    #expect(agent["image"] as? String == "ghcr.io/laosb/claudec:latest")
    #expect(agent["configurations"] as? [String] == ["claude"])
    #expect(agent["cpus"] as? Int == 1)
    #expect(agent["memoryMiB"] as? Int == 1536)
  }

  @Test("agentc init with custom options writes them to settings")
  func initWithCustomOptions() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_init_opts.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let result = await runAgentc(
      args: [
        "init",
        base.path,
        "--skip-container-init",
        "--cpus", "4",
        "--memory-mib", "4096",
        "--image", "custom:latest",
        "--configurations", "claude,copilot",
        "--exclude", "node_modules,.git",
      ]
    )
    #expect(result.exitCode == 0)

    let settingsPath = base.appendingPathComponent(".agentc/settings.json")
    let data = try Data(contentsOf: settingsPath)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let agent = json["agent"] as! [String: Any]
    #expect(agent["image"] as? String == "custom:latest")
    #expect(agent["cpus"] as? Int == 4)
    #expect(agent["memoryMiB"] as? Int == 4096)
    #expect(agent["configurations"] as? [String] == ["claude", "copilot"])
    #expect(agent["excludes"] as? [String] == ["node_modules", ".git"])
  }

  @Test("agentc init with --profile writes profile to settings")
  func initWithProfile() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_init_prof.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let result = await runAgentc(
      args: [
        "init",
        base.path,
        "--skip-container-init",
        "--profile", "work",
      ]
    )
    #expect(result.exitCode == 0)

    let settingsPath = base.appendingPathComponent(".agentc/settings.json")
    let data = try Data(contentsOf: settingsPath)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let agent = json["agent"] as! [String: Any]
    #expect(agent["profile"] as? String == "work")
  }

  // MARK: - Skip flags

  @Test("agentc init --skip-project-settings does not create settings file")
  func skipProjectSettings() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_init_skipps.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let result = await runAgentc(
      args: [
        "init",
        base.path,
        "--skip-project-settings",
        "--skip-container-init",
      ]
    )
    #expect(result.exitCode == 0)

    let settingsPath = base.appendingPathComponent(".agentc/settings.json")
    #expect(!FileManager.default.fileExists(atPath: settingsPath.path))
  }

  // MARK: - Directory argument

  @Test("agentc init without dir argument uses current working directory")
  func initUsesCurrentDirectory() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_init_cwd.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let result = await runAgentc(
      args: [
        "init",
        "--skip-container-init",
      ],
      cwd: base.path
    )
    #expect(result.exitCode == 0)

    let settingsPath = base.appendingPathComponent(".agentc/settings.json")
    #expect(FileManager.default.fileExists(atPath: settingsPath.path))
  }

  @Test("agentc init <dir> creates settings in specified directory")
  func initCreatesSettingsInSpecifiedDir() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_init_dir.\(UUID().uuidString.prefix(6))")
    let targetDir = base.appendingPathComponent("myproject")
    try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let result = await runAgentc(
      args: [
        "init",
        targetDir.path,
        "--skip-container-init",
      ]
    )
    #expect(result.exitCode == 0)

    let settingsPath = targetDir.appendingPathComponent(".agentc/settings.json")
    #expect(FileManager.default.fileExists(atPath: settingsPath.path))
  }

  // MARK: - Output messages

  @Test("agentc init prints getting-started info")
  func initPrintsInfo() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_init_info.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let result = await runAgentc(
      args: [
        "init",
        base.path,
        "--skip-container-init",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("agentc run"))
    #expect(result.output.contains("agentc sh"))
  }

  @Test("agentc init prints settings file creation message")
  func initPrintsSettingsCreationMessage() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_init_msg.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let result = await runAgentc(
      args: [
        "init",
        base.path,
        "--skip-container-init",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains(".agentc/settings.json"))
  }

  // MARK: - Settings roundtrip

  @Test("Generated settings file is loadable and applied by agentc")
  func settingsRoundtrip() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_init_rt.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    // Create settings with cpus=2
    let initResult = await runAgentc(
      args: [
        "init",
        base.path,
        "--skip-container-init",
        "--cpus", "2",
      ]
    )
    #expect(initResult.exitCode == 0)

    // Verify agentc picks up the generated settings via CWD discovery
    let verifyResult = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--", "nproc",
      ],
      cwd: base.path
    )
    #expect(verifyResult.exitCode == 0)
    let reported = verifyResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(reported == "2")
  }

  // MARK: - Container initialization

  @Test("agentc init runs container initialization")
  func initRunsContainer() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_init_cont.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let result = await runAgentc(
      args: [
        "init",
        base.path,
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--skip-project-settings",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("Container environment initialized"))
  }

  @Test("agentc init --skip-container-init does not run container")
  func skipContainerInit() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_init_skipc.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let result = await runAgentc(
      args: [
        "init",
        base.path,
        "--skip-container-init",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(!result.output.contains("Initializing container environment"))
  }
}
