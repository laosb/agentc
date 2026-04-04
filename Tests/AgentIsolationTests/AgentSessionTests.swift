import AgentIsolation
import Crypto
import Foundation
import Testing

// MARK: - Mock Runtime

/// A mock container runtime that captures the configuration passed to `runContainer`
/// and returns a controllable container, for testing `AgentSession` orchestration logic.
final class MockRuntime: ContainerRuntime, @unchecked Sendable {
  typealias Image = MockImage
  typealias Container = MockContainer

  var prepareCallCount = 0
  var lastContainerConfiguration: ContainerConfiguration?
  var lastImageRef: String?
  var containerExitCode: Int32 = 0
  var removedImageRefs: [String] = []
  var removedImageDigests: [String] = []

  required init(config: ContainerRuntimeConfiguration) {}

  func prepare() async throws {
    prepareCallCount += 1
  }

  func pullImage(ref: String) async throws -> MockImage? {
    MockImage(ref: ref, digest: "sha256:mock")
  }

  func inspectImage(ref: String) async throws -> MockImage? {
    MockImage(ref: ref, digest: "sha256:mock")
  }

  func removeImage(ref: String) async throws {
    removedImageRefs.append(ref)
  }

  func removeImage(digest: String) async throws {
    removedImageDigests.append(digest)
  }

  func runContainer(
    imageRef: String,
    configuration: ContainerConfiguration
  ) async throws -> MockContainer {
    lastImageRef = imageRef
    lastContainerConfiguration = configuration
    return MockContainer(id: "mock-container", exitCode: containerExitCode)
  }

  func removeContainer(_ container: MockContainer) async throws {
    container.removed = true
  }
}

struct MockImage: ContainerRuntimeImage {
  var ref: String
  var digest: String
}

final class MockContainer: ContainerRuntimeContainer, @unchecked Sendable {
  let id: String
  let exitCode: Int32
  var stopped = false
  var removed = false

  init(id: String, exitCode: Int32) {
    self.id = id
    self.exitCode = exitCode
  }

  func wait(timeoutInSeconds: Int64?) async throws -> Int32 {
    exitCode
  }

  func stop() async throws {
    stopped = true
  }
}

// MARK: - Helper

private func sha256Hex(_ string: String) -> String {
  let data = Data(string.utf8)
  let digest = SHA256.hash(data: data)
  return digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Tests

@Suite("AgentSession")
struct AgentSessionTests {

  @Test("Prepares runtime before running container")
  func preparesRuntime() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")
    defer { try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent()) }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo", "hello"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    _ = try await session.run()

    #expect(runtime.prepareCallCount == 1)
  }

  @Test("Passes correct image ref to runContainer")
  func passesImageRef() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")
    defer { try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent()) }

    let config = IsolationConfig(
      image: "ghcr.io/test/image:v1",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo", "test"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    _ = try await session.run()

    #expect(runtime.lastImageRef == "ghcr.io/test/image:v1")
  }

  @Test("Mounts profile home at /home/claude")
  func mountsProfileHome() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")
    defer { try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent()) }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    _ = try await session.run()

    let mounts = runtime.lastContainerConfiguration!.mounts
    let homeMount = mounts.first { $0.containerPath == "/home/claude" }
    #expect(homeMount != nil)
    #expect(homeMount?.hostPath == profileDir.path)
  }

  @Test("Mounts workspace at /workspace/<name>-<last10sha>")
  func mountsWorkspace() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let wsDir = URL(fileURLWithPath: "/tmp/claudec-test-ws-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")
    defer {
      try? FileManager.default.removeItem(at: wsDir)
      try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent())
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: wsDir,
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    _ = try await session.run()

    let canonicalPath = wsDir.resolvingSymlinksInPath().path
    let expectedPath: String
    #if os(macOS)
      if canonicalPath.hasPrefix("/tmp") || canonicalPath.hasPrefix("/var")
        || canonicalPath.hasPrefix("/etc")
      {
        expectedPath = "/private" + canonicalPath
      } else {
        expectedPath = canonicalPath
      }
    #else
      expectedPath = canonicalPath
    #endif
    let hash = sha256Hex(expectedPath)
    let folderName = URL(fileURLWithPath: expectedPath).lastPathComponent
    let hashSuffix = String(hash.suffix(10))
    let expectedContainerPath = "/workspace/\(folderName)-\(hashSuffix)"

    let mounts = runtime.lastContainerConfiguration!.mounts
    let wsMount = mounts.first { $0.containerPath == expectedContainerPath }
    #expect(wsMount != nil, "Expected workspace mount at \(expectedContainerPath)")
  }

  @Test("Sets working directory to workspace container path")
  func setsWorkingDirectory() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let wsDir = URL(fileURLWithPath: "/tmp/claudec-test-wd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")
    defer {
      try? FileManager.default.removeItem(at: wsDir)
      try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent())
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: wsDir,
      arguments: ["pwd"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    _ = try await session.run()

    let workDir = runtime.lastContainerConfiguration!.workingDirectory
    #expect(workDir != nil)
    #expect(workDir!.hasPrefix("/workspace/"))
  }

  @Test("Creates exclude folder overlay mounts")
  func excludeFolders() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let wsDir = URL(fileURLWithPath: "/tmp/claudec-test-excl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: wsDir.appendingPathComponent("secret"),
      withIntermediateDirectories: true
    )
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")
    defer {
      try? FileManager.default.removeItem(at: wsDir)
      try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent())
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: wsDir,
      excludeFolders: ["secret", "node_modules"],
      arguments: ["ls"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    _ = try await session.run()

    let mounts = runtime.lastContainerConfiguration!.mounts
    let excludeMounts = mounts.filter {
      $0.containerPath.contains("/secret") || $0.containerPath.contains("/node_modules")
    }
    #expect(excludeMounts.count == 2)
  }

  @Test("Bootstrap script overrides entrypoint")
  func bootstrapScript() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")

    let bootstrapFile = URL(fileURLWithPath: "/tmp/claudec-test-bootstrap-\(UUID().uuidString).sh")
    try "#!/bin/bash\necho hello".write(to: bootstrapFile, atomically: true, encoding: .utf8)
    defer {
      try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: bootstrapFile)
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      bootstrapScript: bootstrapFile,
      arguments: ["sh", "echo", "ok"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    _ = try await session.run()

    let entrypoint = runtime.lastContainerConfiguration!.entrypoint
    #expect(entrypoint.first == "/entrypoint-bootstrap/entrypoint.sh")
    #expect(entrypoint.contains("sh"))

    // Should have a mount for the bootstrap dir
    let mounts = runtime.lastContainerConfiguration!.mounts
    let bootstrapMount = mounts.first { $0.containerPath == "/entrypoint-bootstrap" }
    #expect(bootstrapMount != nil)
  }

  @Test("Without bootstrap script, entrypoint is just arguments")
  func noBootstrapScript() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")
    defer { try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent()) }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo", "hello"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    _ = try await session.run()

    let entrypoint = runtime.lastContainerConfiguration!.entrypoint
    #expect(entrypoint == ["echo", "hello"])
  }

  @Test("Returns container exit code")
  func returnsExitCode() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    runtime.containerExitCode = 42
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")
    defer { try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent()) }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      arguments: ["exit", "42"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    let exitCode = try await session.run()

    #expect(exitCode == 42)
  }

  @Test("IO is currentTerminal when allocateTTY is true")
  func ttyIO() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")
    defer { try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent()) }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo"],
      allocateTTY: true
    )
    let session = AgentSession(config: config, runtime: runtime)
    _ = try await session.run()

    if case .currentTerminal = runtime.lastContainerConfiguration!.io {
      // expected
    } else {
      Issue.record("Expected .currentTerminal IO")
    }
  }

  @Test("IO is standardIO when allocateTTY is false")
  func standardIO() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")
    defer { try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent()) }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo"],
      allocateTTY: false
    )
    let session = AgentSession(config: config, runtime: runtime)
    _ = try await session.run()

    if case .standardIO = runtime.lastContainerConfiguration!.io {
      // expected
    } else {
      Issue.record("Expected .standardIO IO")
    }
  }

  @Test("Creates profile home directory if it doesn't exist")
  func createsProfileDir() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let profileDir = URL(
      fileURLWithPath: "/tmp/claudec-test-create-\(UUID().uuidString)/deep/nested/home")
    defer {
      try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: "/tmp").appendingPathComponent(
          profileDir.pathComponents[2]))
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    _ = try await session.run()

    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: profileDir.path, isDirectory: &isDir))
    #expect(isDir.boolValue)
  }
}

// MARK: - Workspace Migration Tests

@Suite("Workspace Migration")
struct WorkspaceMigrationTests {

  /// Helper: compute the new workspace container path for a given host directory.
  private func newWorkspacePath(for hostPath: String) -> String {
    let url = URL(fileURLWithPath: hostPath)
    let resolved = url.resolvingSymlinksInPath()
    let canonical: String
    #if os(macOS)
      let parts = resolved.pathComponents
      if parts.count > 1, parts.first == "/",
        ["tmp", "var", "etc"].contains(parts[1])
      {
        canonical = "/private" + resolved.path
      } else {
        canonical = resolved.path
      }
    #else
      canonical = resolved.path
    #endif
    let hash = sha256Hex(canonical)
    let name = URL(fileURLWithPath: canonical).lastPathComponent
    return "/workspace/\(name)-\(String(hash.suffix(10)))"
  }

  /// Helper: compute the legacy workspace container path for a given host directory.
  private func legacyWorkspacePath(for hostPath: String) -> String {
    let url = URL(fileURLWithPath: hostPath)
    let resolved = url.resolvingSymlinksInPath()
    let canonical: String
    #if os(macOS)
      let parts = resolved.pathComponents
      if parts.count > 1, parts.first == "/",
        ["tmp", "var", "etc"].contains(parts[1])
      {
        canonical = "/private" + resolved.path
      } else {
        canonical = resolved.path
      }
    #else
      canonical = resolved.path
    #endif
    return "/workspace/\(sha256Hex(canonical))"
  }

  /// Encode a container path to Claude Code's project folder name (same as AgentSession).
  private func encodeProjectFolderName(_ containerPath: String) -> String {
    var result = ""
    for component in containerPath.split(separator: "/", omittingEmptySubsequences: true) {
      if component.hasPrefix(".") {
        result += "-" + String(component)
      } else {
        result += "-" + component
      }
    }
    return result
  }

  @Test("No migration when no legacy project folder exists")
  func noMigrationNeeded() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let base = URL(fileURLWithPath: "/tmp/claudec-mig-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let wsDir = base.appendingPathComponent("ws")
    try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: wsDir,
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    // Should not prompt or throw — no legacy data exists
    _ = try await session.run()

    // Verify new-format path is used
    let workDir = runtime.lastContainerConfiguration!.workingDirectory!
    #expect(workDir.contains("-"))
    #expect(workDir.hasPrefix("/workspace/"))
  }

  @Test("Skips migration if new project folder already exists alongside legacy")
  func skipsIfNewAlreadyExists() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let base = URL(fileURLWithPath: "/tmp/claudec-mig-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let wsDir = base.appendingPathComponent("ws")
    try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let legacyPath = legacyWorkspacePath(for: wsDir.path)
    let newPath = newWorkspacePath(for: wsDir.path)

    let projectsDir = profileDir.appendingPathComponent(".claude/projects")
    let legacyFolder = projectsDir.appendingPathComponent(encodeProjectFolderName(legacyPath))
    let newFolder = projectsDir.appendingPathComponent(encodeProjectFolderName(newPath))
    try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: wsDir,
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    // Should not prompt — both exist, so migration is skipped
    _ = try await session.run()

    // Both dirs should still exist
    #expect(FileManager.default.fileExists(atPath: legacyFolder.path))
    #expect(FileManager.default.fileExists(atPath: newFolder.path))
  }

  @Test("New workspace path format is folderName-last10hash")
  func newPathFormat() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let base = URL(fileURLWithPath: "/tmp/claudec-mig-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let wsDir = base.appendingPathComponent("myproject")
    try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: wsDir,
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    _ = try await session.run()

    let workDir = runtime.lastContainerConfiguration!.workingDirectory!
    // Should start with /workspace/myproject-
    #expect(workDir.hasPrefix("/workspace/myproject-"))
    // The suffix should be exactly 10 hex chars
    let parts = workDir.split(separator: "-")
    let hashPart = String(parts.last!)
    #expect(hashPart.count == 10)
    #expect(hashPart.allSatisfy { $0.isHexDigit })
  }
}
