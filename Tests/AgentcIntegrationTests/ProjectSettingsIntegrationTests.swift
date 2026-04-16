import Foundation
import Testing

/// Helper to write a project settings file into a temp directory.
private func writeProjectSettings(_ json: String, at base: URL, folderName: String = ".agentc")
  throws
{
  let dir = base.appendingPathComponent(folderName)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  try json.write(
    to: dir.appendingPathComponent("settings.json"),
    atomically: true,
    encoding: .utf8
  )
}

@Suite("Project Settings Integration Tests")
struct ProjectSettingsIntegrationTests {
  init() {
    _ = sharedProfile
  }

  // MARK: - --agentc-folder

  @Test("--agentc-folder applies agent.cpus setting")
  func agentcFolderAppliesCpus() async throws {
    let base = URL(fileURLWithPath: "/tmp/__TEST_agentc_ps_cpus.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: base) }

    let settingsDir = base.appendingPathComponent("settings")
    try writeProjectSettings(
      """
      { "agent": { "cpus": 2 } }
      """,
      at: settingsDir)

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--agentc-folder", settingsDir.appendingPathComponent(".agentc").path,
        "--", "nproc",
      ]
    )
    #expect(result.exitCode == 0)
    let reported = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(reported == "2")
  }

  @Test("--agentc-folder applies agent.memoryMiB setting")
  func agentcFolderAppliesMemory() async throws {
    let base = URL(fileURLWithPath: "/tmp/__TEST_agentc_ps_mem.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: base) }

    let settingsDir = base.appendingPathComponent("settings")
    let limitMiB = 512
    let limitBytes = limitMiB * 1024 * 1024
    try writeProjectSettings(
      """
      { "agent": { "memoryMiB": \(limitMiB) } }
      """,
      at: settingsDir)

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--agentc-folder", settingsDir.appendingPathComponent(".agentc").path,
        "--", "cat", "/sys/fs/cgroup/memory.max",
      ]
    )
    #expect(result.exitCode == 0)
    let reported = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(reported == "\(limitBytes)")
  }

  @Test("--agentc-folder applies agent.excludes setting")
  func agentcFolderAppliesExcludes() async throws {
    let base = URL(fileURLWithPath: "/tmp/__TEST_agentc_ps_excl.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: base) }

    let ws = base.appendingPathComponent("workspace")
    let secretDir = ws.appendingPathComponent("secret")
    try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
    try "sensitive".write(
      to: secretDir.appendingPathComponent("data.txt"),
      atomically: true, encoding: .utf8)

    let settingsDir = base.appendingPathComponent("settings")
    try writeProjectSettings(
      """
      { "agent": { "excludes": ["secret"] } }
      """,
      at: settingsDir)

    let containerPath = workspaceContainerPath(for: ws)

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--workspace", ws.path,
        "--no-update-image",
        "--agentc-folder", settingsDir.appendingPathComponent(".agentc").path,
        "--", "ls", "\(containerPath)/secret",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  // MARK: - CLI Override

  @Test("CLI --cpus overrides project settings agent.cpus")
  func cliOverridesProjectCpus() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_ps_ovcpus.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: base) }

    let settingsDir = base.appendingPathComponent("settings")
    try writeProjectSettings(
      """
      { "agent": { "cpus": 2 } }
      """,
      at: settingsDir)

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--agentc-folder", settingsDir.appendingPathComponent(".agentc").path,
        "--cpus", "3",
        "--", "nproc",
      ]
    )
    #expect(result.exitCode == 0)
    let reported = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(reported == "3")
  }

  // MARK: - Merge Behavior

  @Test("CLI --exclude and project excludes are both applied")
  func mergesExcludes() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_ps_merge.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: base) }

    let ws = base.appendingPathComponent("workspace")
    let secretDir = ws.appendingPathComponent("secret")
    let vendorDir = ws.appendingPathComponent("vendor")
    try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vendorDir, withIntermediateDirectories: true)
    try "secret-data".write(
      to: secretDir.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
    try "vendor-data".write(
      to: vendorDir.appendingPathComponent("v.txt"), atomically: true, encoding: .utf8)

    let settingsDir = base.appendingPathComponent("settings")
    try writeProjectSettings(
      """
      { "agent": { "excludes": ["vendor"] } }
      """,
      at: settingsDir)

    let containerPath = workspaceContainerPath(for: ws)

    // CLI excludes "secret", project settings excludes "vendor" — both should be empty
    let resultSecret = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--workspace", ws.path,
        "--no-update-image",
        "--agentc-folder", settingsDir.appendingPathComponent(".agentc").path,
        "--exclude", "secret",
        "--", "ls", "\(containerPath)/secret",
      ]
    )
    #expect(resultSecret.exitCode == 0)
    #expect(resultSecret.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

    let resultVendor = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--workspace", ws.path,
        "--no-update-image",
        "--agentc-folder", settingsDir.appendingPathComponent(".agentc").path,
        "--exclude", "secret",
        "--", "ls", "\(containerPath)/vendor",
      ]
    )
    #expect(resultVendor.exitCode == 0)
    #expect(resultVendor.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  // MARK: - CWD-based Discovery

  @Test("Settings are discovered from CWD without --agentc-folder")
  func cwdDiscovery() async throws {
    let base = URL(fileURLWithPath: "/tmp/__TEST_agentc_ps_cwd.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: base) }

    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try writeProjectSettings(
      """
      { "agent": { "cpus": 2 } }
      """,
      at: base)

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--", "nproc",
      ],
      cwd: base.path
    )
    #expect(result.exitCode == 0)
    let reported = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(reported == "2")
  }

  @Test("Settings are discovered from parent of CWD")
  func cwdParentDiscovery() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_ps_cwdp.\(UUID().uuidString.prefix(6))")
    let subdir = base.appendingPathComponent("subproject")
    defer { try? FileManager.default.removeItem(at: base) }

    try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
    try writeProjectSettings(
      """
      { "agent": { "cpus": 2 } }
      """,
      at: base)

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--", "nproc",
      ],
      cwd: subdir.path
    )
    #expect(result.exitCode == 0)
    let reported = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(reported == "2")
  }

  // MARK: - .boite preference

  @Test(".boite folder is preferred over .agentc in CWD discovery")
  func boitePreferredInCwd() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_ps_boite.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: base) }

    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

    try writeProjectSettings(
      """
      { "agent": { "cpus": 3 } }
      """,
      at: base, folderName: ".boite")

    try writeProjectSettings(
      """
      { "agent": { "cpus": 1 } }
      """,
      at: base, folderName: ".agentc")

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--", "nproc",
      ],
      cwd: base.path
    )
    #expect(result.exitCode == 0)
    let reported = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(reported == "3")
  }

  // MARK: - No settings (defaults unchanged)

  @Test("Without project settings, defaults are preserved")
  func noSettingsUsesDefaults() async throws {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_ps_noset.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    // No .agentc or .boite folder — should use default cpus=1
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--", "nproc",
      ],
      cwd: base.path
    )
    #expect(result.exitCode == 0)
    let reported = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(reported == "1")
  }
}
