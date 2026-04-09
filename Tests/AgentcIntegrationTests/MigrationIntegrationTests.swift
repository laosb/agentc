import Foundation
import Testing

@Suite("Migration Integration Tests")
struct MigrationIntegrationTests {

  // MARK: - Migration Check

  @Test("Migration check exits when ~/.claudec exists without ~/.agentc")
  func migrationCheckTriggered() async throws {
    let tempDir = URL(fileURLWithPath: "/tmp/__TEST_migrate_check.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Create fake home with only .claudec
    let fakeHome = tempDir.appendingPathComponent("fakehome")
    try FileManager.default.createDirectory(
      at: fakeHome.appendingPathComponent(".claudec/profiles"),
      withIntermediateDirectories: true)

    let result = await runAgentc(
      args: ["run"],
      env: ["HOME": fakeHome.path]
    )
    #expect(result.exitCode != 0)
    #expect(result.stderr.contains("migrate-from-claudec"))
  }

  @Test("No migration check when ~/.agentc exists")
  func migrationCheckSkippedWhenAgentcExists() async throws {
    let tempDir = URL(fileURLWithPath: "/tmp/__TEST_migrate_skip.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fakeHome = tempDir.appendingPathComponent("fakehome")
    // Create both .claudec and .agentc
    try FileManager.default.createDirectory(
      at: fakeHome.appendingPathComponent(".claudec/profiles"),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: fakeHome.appendingPathComponent(".agentc"),
      withIntermediateDirectories: true)

    let result = await runAgentc(
      args: ["run"],
      env: ["HOME": fakeHome.path]
    )
    // It may fail for other reasons (no configs, no Docker), but not the migration check
    #expect(!result.stderr.contains("migrate-from-claudec"))
  }

  @Test("No migration check when neither directory exists")
  func migrationCheckSkippedWhenNeitherExists() async throws {
    let tempDir = URL(fileURLWithPath: "/tmp/__TEST_migrate_none.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fakeHome = tempDir.appendingPathComponent("fakehome")
    try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)

    let result = await runAgentc(
      args: ["run"],
      env: ["HOME": fakeHome.path]
    )
    // Should not trigger migration check
    #expect(!result.stderr.contains("migrate-from-claudec"))
  }

  @Test("--suppress-migration-from-claudec skips the check")
  func suppressFlag() async throws {
    let tempDir = URL(
      fileURLWithPath: "/tmp/__TEST_migrate_suppress.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fakeHome = tempDir.appendingPathComponent("fakehome")
    // Create only .claudec (which would normally trigger migration)
    try FileManager.default.createDirectory(
      at: fakeHome.appendingPathComponent(".claudec/profiles"),
      withIntermediateDirectories: true)

    let result = await runAgentc(
      args: ["run", "--suppress-migration-from-claudec"],
      env: ["HOME": fakeHome.path]
    )
    // Migration check should be suppressed; may fail for other reasons but not migration
    #expect(!result.stderr.contains("migrate-from-claudec"))
  }

  // MARK: - Migrate Subcommand

  @Test("migrate-from-claudec copies profiles and configurations")
  func migrateCopiesToAgentc() async throws {
    let tempDir = URL(
      fileURLWithPath: "/tmp/__TEST_migrate_copy.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fakeHome = tempDir.appendingPathComponent("fakehome")
    let fm = FileManager.default

    // Set up .claudec with profiles and configurations
    let profileHome = fakeHome.appendingPathComponent(".claudec/profiles/myprofile/home")
    try fm.createDirectory(at: profileHome, withIntermediateDirectories: true)
    try "test-sentinel".write(
      to: profileHome.appendingPathComponent("sentinel.txt"),
      atomically: true, encoding: .utf8)

    let configsDir = fakeHome.appendingPathComponent(".claudec/configurations/claude")
    try fm.createDirectory(at: configsDir, withIntermediateDirectories: true)
    try "{}".write(
      to: configsDir.appendingPathComponent("settings.json"),
      atomically: true, encoding: .utf8)

    // Create old marker file
    let oldMarker = fakeHome.appendingPathComponent(".claudec/configurations/.claudec-last-pull")
    fm.createFile(atPath: oldMarker.path, contents: nil)

    let result = await runAgentc(
      args: ["migrate-from-claudec"],
      env: ["HOME": fakeHome.path]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("Successfully migrated"))
    #expect(result.stdout.contains("profiles"))
    #expect(result.stdout.contains("configurations"))

    // Verify data was copied to .agentc
    let newProfileSentinel = fakeHome.appendingPathComponent(
      ".agentc/profiles/myprofile/home/sentinel.txt")
    #expect(fm.fileExists(atPath: newProfileSentinel.path))
    let content = try String(contentsOf: newProfileSentinel, encoding: .utf8)
    #expect(content == "test-sentinel")

    let newConfig = fakeHome.appendingPathComponent(
      ".agentc/configurations/claude/settings.json")
    #expect(fm.fileExists(atPath: newConfig.path))

    // Verify marker was renamed
    let newMarker = fakeHome.appendingPathComponent(
      ".agentc/configurations/.agentc-last-pull")
    #expect(fm.fileExists(atPath: newMarker.path))
    let oldMarkerAfter = fakeHome.appendingPathComponent(
      ".agentc/configurations/.claudec-last-pull")
    #expect(!fm.fileExists(atPath: oldMarkerAfter.path))

    // Verify original .claudec is untouched
    let origSentinel = fakeHome.appendingPathComponent(
      ".claudec/profiles/myprofile/home/sentinel.txt")
    #expect(fm.fileExists(atPath: origSentinel.path))

    // Verify cleanup instructions in output
    #expect(result.stdout.contains("rm -rf ~/.claudec"))
  }

  @Test("migrate-from-claudec with no ~/.claudec")
  func migrateNoClaudec() async throws {
    let tempDir = URL(
      fileURLWithPath: "/tmp/__TEST_migrate_noclaudec.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fakeHome = tempDir.appendingPathComponent("fakehome")
    try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)

    let result = await runAgentc(
      args: ["migrate-from-claudec"],
      env: ["HOME": fakeHome.path]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("Nothing to migrate"))
  }

  @Test("migrate-from-claudec with existing ~/.agentc")
  func migrateAlreadyExists() async throws {
    let tempDir = URL(
      fileURLWithPath: "/tmp/__TEST_migrate_exists.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fakeHome = tempDir.appendingPathComponent("fakehome")
    let fm = FileManager.default
    try fm.createDirectory(
      at: fakeHome.appendingPathComponent(".claudec/profiles"),
      withIntermediateDirectories: true)
    try fm.createDirectory(
      at: fakeHome.appendingPathComponent(".agentc"),
      withIntermediateDirectories: true)

    let result = await runAgentc(
      args: ["migrate-from-claudec"],
      env: ["HOME": fakeHome.path]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("already exists"))
  }
}
