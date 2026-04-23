import Foundation
import Testing

@Suite("Profiles Command Integration Tests")
struct ProfilesCommandIntegrationTests {

  // MARK: - Helpers

  private func makeStorage() -> URL {
    let base = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_profiles.\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  private func createProfile(_ name: String, in storage: URL, with content: String = "hi\n") throws
  {
    let home = storage.appendingPathComponent("\(name)/home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try content.write(
      to: home.appendingPathComponent(".bashrc"), atomically: true, encoding: .utf8)
  }

  // MARK: - list

  @Test("agentc profiles lists profile names")
  func listProfileNames() async throws {
    let storage = makeStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    try createProfile("alice", in: storage)
    try createProfile("bob", in: storage)

    let result = await runAgentc(args: ["profiles", "--profiles-dir", storage.path])
    #expect(result.exitCode == 0)
    let names =
      result.stdout
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    #expect(names == ["alice", "bob"])
  }

  @Test("agentc profiles list with no profiles shows helpful message")
  func listEmptyShowsMessage() async throws {
    let storage = makeStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    let result = await runAgentc(args: ["profiles", "list", "--profiles-dir", storage.path])
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("No profiles found"))
  }

  @Test("agentc profiles --verbose prints home/size/modified")
  func listVerbosePrintsDetails() async throws {
    let storage = makeStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    try createProfile("alice", in: storage, with: "hello world")  // 11 bytes

    let result = await runAgentc(
      args: ["profiles", "list", "--profiles-dir", storage.path, "--verbose"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("name:          alice"))
    #expect(result.stdout.contains("home:"))
    #expect(result.stdout.contains("size:"))
    #expect(result.stdout.contains("lastModified:"))
    #expect(result.stdout.contains("/alice/home"))
  }

  @Test("agentc profiles <name> inspects a single profile")
  func inspectSingleProfile() async throws {
    let storage = makeStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    try createProfile("alice", in: storage)
    try createProfile("bob", in: storage)

    let result = await runAgentc(
      args: ["profiles", "list", "alice", "--profiles-dir", storage.path])
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("name:          alice"))
    #expect(!result.stdout.contains("name:          bob"))
  }

  @Test("agentc profiles <name> on missing profile errors out")
  func inspectMissingProfileFails() async throws {
    let storage = makeStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    let result = await runAgentc(
      args: ["profiles", "list", "ghost", "--profiles-dir", storage.path])
    #expect(result.exitCode != 0)
  }

  // MARK: - remove / rm

  @Test("agentc profiles remove deletes the profile")
  func removeDeletesProfile() async throws {
    let storage = makeStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    try createProfile("alice", in: storage)
    try createProfile("bob", in: storage)

    let result = await runAgentc(
      args: ["profiles", "remove", "--profiles-dir", storage.path, "alice"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("removed profile \"alice\""))

    #expect(!FileManager.default.fileExists(atPath: storage.appendingPathComponent("alice").path))
    #expect(FileManager.default.fileExists(atPath: storage.appendingPathComponent("bob").path))
  }

  @Test("agentc profiles rm (alias) deletes the profile")
  func rmAliasDeletes() async throws {
    let storage = makeStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    try createProfile("alice", in: storage)

    let result = await runAgentc(
      args: ["profiles", "rm", "--profiles-dir", storage.path, "alice"])
    #expect(result.exitCode == 0)
    #expect(!FileManager.default.fileExists(atPath: storage.appendingPathComponent("alice").path))
  }

  @Test("agentc profiles rm fails when the profile is missing")
  func rmMissingFails() async throws {
    let storage = makeStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    let result = await runAgentc(
      args: ["profiles", "rm", "--profiles-dir", storage.path, "ghost"])
    #expect(result.exitCode != 0)
    #expect(result.stderr.contains("does not exist"))
  }

  @Test("agentc profiles rm --force silently ignores missing profiles")
  func rmForceSwallowsMissing() async throws {
    let storage = makeStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    let result = await runAgentc(
      args: ["profiles", "rm", "--profiles-dir", storage.path, "--force", "ghost"])
    #expect(result.exitCode == 0)
  }

  @Test("agentc profiles rm accepts multiple names")
  func rmMultiple() async throws {
    let storage = makeStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    try createProfile("alice", in: storage)
    try createProfile("bob", in: storage)
    try createProfile("charlie", in: storage)

    let result = await runAgentc(
      args: ["profiles", "rm", "--profiles-dir", storage.path, "alice", "charlie"])
    #expect(result.exitCode == 0)

    #expect(!FileManager.default.fileExists(atPath: storage.appendingPathComponent("alice").path))
    #expect(FileManager.default.fileExists(atPath: storage.appendingPathComponent("bob").path))
    #expect(!FileManager.default.fileExists(atPath: storage.appendingPathComponent("charlie").path))
  }

  @Test("agentc profiles rm rejects names with path separators")
  func rmRejectsTraversal() async throws {
    let storage = makeStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    // Create a sibling directory outside storage that a path-traversal would target
    let outside = storage.deletingLastPathComponent().appendingPathComponent(
      "__TEST_agentc_outside.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }

    let result = await runAgentc(
      args: [
        "profiles", "rm", "--profiles-dir", storage.path, "../\(outside.lastPathComponent)",
      ])
    #expect(result.exitCode != 0)
    #expect(FileManager.default.fileExists(atPath: outside.path))
  }
}
