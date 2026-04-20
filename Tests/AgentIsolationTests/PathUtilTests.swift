import AgentIsolation
import Foundation
import Testing

@Suite("Path Utils")
struct PathUtilTests {
  @Test("workspaceContainerPath format is folderName-last10hash")
  func newPathFormat() throws {
    let base = URL(fileURLWithPath: "/tmp/claudec-wp-\(UUID().uuidString)")
    let wsDir = base.appendingPathComponent("myproject")
    try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let path = AgentIsolationPathUtils.workspaceContainerPath(for: wsDir)
    // Should start with /workspace/myproject-
    #expect(path.hasPrefix("/workspace/myproject-"))
    // The suffix should be exactly 10 hex chars
    let parts = path.split(separator: "-")
    let hashPart = String(parts.last!)
    #expect(hashPart.count == 10)
    #expect(hashPart.allSatisfy { $0.isHexDigit })
  }

  @Test("legacyWorkspaceContainerPath format is full sha256")
  func legacyPathFormat() throws {
    let base = URL(fileURLWithPath: "/tmp/claudec-wp-\(UUID().uuidString)")
    let wsDir = base.appendingPathComponent("myproject")
    try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let path = AgentIsolationPathUtils.legacyWorkspaceContainerPath(for: wsDir)
    #expect(path.hasPrefix("/workspace/"))
    // Legacy path should be /workspace/<64-char hex sha256>
    let hash = String(path.dropFirst("/workspace/".count))
    #expect(hash.count == 64)
    #expect(hash.allSatisfy { $0.isHexDigit })
  }

  @Test("workspaceContainerPath matches AgentSession working directory")
  func matchesAgentSession() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let base = URL(fileURLWithPath: "/tmp/claudec-wp-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let wsDir = base.appendingPathComponent("myproject")
    try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: wsDir,
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    let workDir = runtime.lastContainerConfiguration!.workingDirectory!
    #expect(workDir == AgentIsolationPathUtils.workspaceContainerPath(for: wsDir))
  }
}
