import AgentIsolation
import Foundation
import Testing

@Suite("AgentConfigurationResolver")
struct AgentConfigurationResolverTests {

  /// Create a temp configurations directory holding one `settings.json` per configuration.
  private func makeConfigsDir(_ configs: [String: [String: Any]]) throws -> URL {
    let dir = URL(fileURLWithPath: "/tmp/agentc-test-deps-\(UUID().uuidString)")
    for (name, settings) in configs {
      let configDir = dir.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
      let data = try JSONSerialization.data(withJSONObject: settings)
      try data.write(to: configDir.appendingPathComponent("settings.json"))
    }
    return dir
  }

  @Test("Keeps requested order when nothing declares dependencies")
  func noDependencies() throws {
    let dir = try makeConfigsDir([
      "claude": ["entrypoint": ["claude"]],
      "copilot": ["entrypoint": ["copilot"]],
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    let resolved = try AgentConfigurationResolver.resolve(
      configurations: ["claude", "copilot"], in: dir)
    #expect(resolved == ["claude", "copilot"])
  }

  @Test("Activates dependencies before the configuration that requires them")
  func expandsDependencies() throws {
    let dir = try makeConfigsDir([
      "base": [:],
      "claude": ["dependsOn": ["base"], "entrypoint": ["claude"]],
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    let resolved = try AgentConfigurationResolver.resolve(configurations: ["claude"], in: dir)
    #expect(resolved == ["base", "claude"])
  }

  @Test("Expands transitive dependencies depth-first")
  func expandsTransitively() throws {
    let dir = try makeConfigsDir([
      "os": [:],
      "node": ["dependsOn": ["os"]],
      "claude": ["dependsOn": ["node"], "entrypoint": ["claude"]],
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    let resolved = try AgentConfigurationResolver.resolve(configurations: ["claude"], in: dir)
    #expect(resolved == ["os", "node", "claude"])
  }

  @Test("Emits a shared dependency once, in dependency order")
  func deduplicatesDiamond() throws {
    let dir = try makeConfigsDir([
      "os": [:],
      "node": ["dependsOn": ["os"]],
      "python": ["dependsOn": ["os"]],
      "agent": ["dependsOn": ["node", "python"], "entrypoint": ["agent"]],
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    let resolved = try AgentConfigurationResolver.resolve(configurations: ["agent"], in: dir)
    #expect(resolved == ["os", "node", "python", "agent"])
  }

  @Test("An explicitly requested dependency is not activated twice")
  func deduplicatesExplicitRequest() throws {
    let dir = try makeConfigsDir([
      "base": [:],
      "claude": ["dependsOn": ["base"], "entrypoint": ["claude"]],
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(
      try AgentConfigurationResolver.resolve(configurations: ["base", "claude"], in: dir)
        == ["base", "claude"])
    // Requesting the dependency last still leaves it deduplicated at its earliest position.
    #expect(
      try AgentConfigurationResolver.resolve(configurations: ["claude", "base"], in: dir)
        == ["base", "claude"])
  }

  @Test("Requested configuration stays last so its entrypoint wins")
  func requestedConfigurationStaysLast() throws {
    let dir = try makeConfigsDir([
      "claude": ["entrypoint": ["claude"]],
      "myteam": ["dependsOn": ["claude"]],
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    let resolved = try AgentConfigurationResolver.resolve(configurations: ["myteam"], in: dir)
    #expect(resolved == ["claude", "myteam"])
  }

  @Test("Throws on a dependency cycle")
  func detectsCycle() throws {
    let dir = try makeConfigsDir([
      "a": ["dependsOn": ["b"]],
      "b": ["dependsOn": ["c"]],
      "c": ["dependsOn": ["a"]],
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(throws: AgentConfigurationError.dependencyCycle(["a", "b", "c", "a"])) {
      try AgentConfigurationResolver.resolve(configurations: ["a"], in: dir)
    }
  }

  @Test("Throws on a self-dependency")
  func detectsSelfCycle() throws {
    let dir = try makeConfigsDir(["loop": ["dependsOn": ["loop"]]])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(throws: AgentConfigurationError.dependencyCycle(["loop", "loop"])) {
      try AgentConfigurationResolver.resolve(configurations: ["loop"], in: dir)
    }
  }

  @Test("Passes unknown configurations through for the bootstrap to report")
  func passesUnknownThrough() throws {
    let dir = try makeConfigsDir(["claude": ["dependsOn": ["ghost"]]])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(try AgentConfigurationResolver.resolve(configurations: ["nope"], in: dir) == ["nope"])
    #expect(
      try AgentConfigurationResolver.resolve(configurations: ["claude"], in: dir)
        == ["ghost", "claude"])
  }

  @Test("Ignores blank names and trims whitespace")
  func trimsNames() throws {
    let dir = try makeConfigsDir([
      "base": [:],
      "claude": ["dependsOn": [" base ", ""], "entrypoint": ["claude"]],
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    let resolved = try AgentConfigurationResolver.resolve(
      configurations: [" claude ", "  "], in: dir)
    #expect(resolved == ["base", "claude"])
  }
}
