import AgentIsolation
import Foundation
import Testing

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
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo", "hello"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

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
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo", "test"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    #expect(runtime.lastImageRef == "ghcr.io/test/image:v1")
  }

  @Test("Mounts profile home at /home/agent")
  func mountsProfileHome() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")
    let configsDir = URL(fileURLWithPath: "/tmp/claudec-test-configs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: configsDir, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: configsDir)
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: configsDir,
      configurations: [],
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    let mounts = runtime.lastContainerConfiguration!.mounts
    let homeMount = mounts.first { $0.containerPath == "/home/agent" }
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
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

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
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      arguments: ["pwd"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

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
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      arguments: ["ls"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    let mounts = runtime.lastContainerConfiguration!.mounts
    let excludeMounts = mounts.filter {
      $0.containerPath.contains("/secret") || $0.containerPath.contains("/node_modules")
    }
    #expect(excludeMounts.count == 2)
  }

  @Test("Bootstrap file overrides entrypoint")
  func bootstrapFileOverridesEntrypoint() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")

    let bootstrapFile = URL(fileURLWithPath: "/tmp/claudec-test-bootstrap-\(UUID().uuidString)")
    try "#!/bin/bash\necho hello".write(to: bootstrapFile, atomically: true, encoding: .utf8)
    defer {
      try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: bootstrapFile)
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      bootstrapMode: .file(bootstrapFile),
      arguments: ["sh", "echo", "ok"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    let entrypoint = runtime.lastContainerConfiguration!.entrypoint
    #expect(entrypoint.first == "/entrypoint-bootstrap/bootstrap")
    #expect(entrypoint.contains("sh"))

    // Should have a mount for the bootstrap dir
    let mounts = runtime.lastContainerConfiguration!.mounts
    let bootstrapMount = mounts.first { $0.containerPath == "/entrypoint-bootstrap" }
    #expect(bootstrapMount != nil)

    #expect(runtime.lastContainerConfiguration!.overridesImageEntrypoint == true)
  }

  @Test("imageDefault bootstrap mode uses image's own entrypoint")
  func imageDefaultBootstrap() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")
    defer { try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent()) }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      bootstrapMode: .imageDefault,
      arguments: ["echo", "hello"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    let entrypoint = runtime.lastContainerConfiguration!.entrypoint
    #expect(entrypoint == ["echo", "hello"])

    let mounts = runtime.lastContainerConfiguration!.mounts
    let bootstrapMount = mounts.first { $0.containerPath == "/entrypoint-bootstrap" }
    #expect(bootstrapMount == nil)

    #expect(runtime.lastContainerConfiguration!.overridesImageEntrypoint == false)
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
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      arguments: ["exit", "42"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    let exitCode = try await session.wait()

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
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo"],
      allocateTTY: true
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

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
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo"],
      allocateTTY: false
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

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
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: profileDir.path, isDirectory: &isDir))
    #expect(isDir.boolValue)
  }

  @Test("Passes cpuCount to container configuration")
  func passesCpuCount() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")
    defer { try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent()) }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo"],
      cpuCount: 4
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    #expect(runtime.lastContainerConfiguration?.cpuCount == 4)
  }

  @Test("Passes memoryLimitMiB to container configuration")
  func passesMemoryLimitMiB() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let profileDir = URL(fileURLWithPath: "/tmp/claudec-test-\(UUID().uuidString)/home")
    defer { try? FileManager.default.removeItem(at: profileDir.deletingLastPathComponent()) }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      arguments: ["echo"],
      memoryLimitMiB: 2048
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    #expect(runtime.lastContainerConfiguration?.memoryLimitMiB == 2048)
  }

  @Test("IsolationConfig defaults: cpuCount is 1, memoryLimitMiB is 1536")
  func isolationConfigDefaults() {
    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: URL(fileURLWithPath: "/tmp/home"),
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: URL(fileURLWithPath: "/tmp")
    )
    #expect(config.cpuCount == 1)
    #expect(config.memoryLimitMiB == 1536)
  }
}

// MARK: - Path Segment Tests

@Suite("Path Segment")
struct PathSegmentTests {

  @Test("pathSegment format is lastComponent-last10hash")
  func format() {
    let segment = AgentIsolationPathUtils.pathIdentifier(for: "/data/models/llm")
    #expect(segment.hasPrefix("llm-"))
    let parts = segment.split(separator: "-")
    let hashPart = String(parts.last!)
    #expect(hashPart.count == 10)
    #expect(hashPart.allSatisfy { $0.isHexDigit })
  }

  @Test("pathSegment is deterministic")
  func deterministic() {
    let a = AgentIsolationPathUtils.pathIdentifier(for: "/data/models/llm")
    let b = AgentIsolationPathUtils.pathIdentifier(for: "/data/models/llm")
    #expect(a == b)
  }

  @Test("pathSegment differs for different paths")
  func different() {
    let a = AgentIsolationPathUtils.pathIdentifier(for: "/data/models/llm")
    let b = AgentIsolationPathUtils.pathIdentifier(for: "/data/models/other")
    #expect(a != b)
  }

  @Test("pathSegment used by workspaceContainerPath")
  func matchesWorkspace() throws {
    let base = URL(fileURLWithPath: "/tmp/claudec-ps-\(UUID().uuidString)")
    let wsDir = base.appendingPathComponent("myproject")
    try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let resolved = wsDir.resolvingSymlinksInPath()
    #if os(macOS)
      let canonical =
        resolved.path.hasPrefix("/tmp") ? "/private\(resolved.path)" : resolved.path
    #else
      let canonical = resolved.path
    #endif
    let expected = "/workspace/\(AgentIsolationPathUtils.pathIdentifier(for: canonical))"
    #expect(AgentIsolationPathUtils.workspaceContainerPath(for: wsDir) == expected)
  }
}

// MARK: - Configuration Mount Tests

@Suite("Configurations")
struct ConfigurationTests {

  /// Helper to create a temp configuration directory with settings.json files.
  private func makeConfigsDir(
    configs: [String: [String: Any]]
  ) throws -> URL {
    let dir = URL(fileURLWithPath: "/tmp/claudec-test-configs-\(UUID().uuidString)")
    for (name, settingsDict) in configs {
      let configDir = dir.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
      let data = try JSONSerialization.data(withJSONObject: settingsDict)
      try data.write(to: configDir.appendingPathComponent("settings.json"))
    }
    return dir
  }

  @Test("Mounts configurations directory at /agent-isolation/agents as read-only")
  func mountsConfigsDir() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let base = URL(fileURLWithPath: "/tmp/claudec-test-cfgmnt-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let configsDir = try makeConfigsDir(configs: [:])
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: configsDir)
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: configsDir,
      configurations: [],
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    let mounts = runtime.lastContainerConfiguration!.mounts
    let cfgMount = mounts.first { $0.containerPath == "/agent-isolation/agents" }
    #expect(cfgMount != nil)
    #expect(cfgMount?.hostPath == configsDir.path)
    #expect(cfgMount?.isReadOnly == true)
  }

  @Test("Passes AGENTC_CONFIGURATIONS environment variable")
  func passesConfigurationsEnv() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let base = URL(fileURLWithPath: "/tmp/claudec-test-cfgenv-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let configsDir = try makeConfigsDir(configs: [:])
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: configsDir)
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: configsDir,
      configurations: ["claude", "swift"],
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    let env = runtime.lastContainerConfiguration!.environment
    #expect(env["AGENTC_CONFIGURATIONS"] == "claude,swift")
  }

  @Test("Creates additional mounts from single configuration")
  func additionalMountsSingle() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let base = URL(fileURLWithPath: "/tmp/claudec-test-addmnt-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let configsDir = try makeConfigsDir(configs: [
      "myconfig": [
        "additionalMounts": ["/data/models"],
        "entrypoint": ["echo"],
      ]
    ])
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: configsDir)
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: configsDir,
      configurations: ["myconfig"],
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    let mounts = runtime.lastContainerConfiguration!.mounts
    let additionalMount = mounts.first { $0.containerPath == "/data/models" }
    #expect(additionalMount != nil)
    #expect(additionalMount?.isReadOnly == false)

    // Verify host path uses pathSegment in additionalMounts dir
    let expectedSegment = AgentIsolationPathUtils.pathIdentifier(for: "/data/models")
    #expect(additionalMount?.hostPath.contains("additionalMounts/\(expectedSegment)") == true)
  }

  @Test("Creates additional mounts from multiple configurations")
  func additionalMountsMultiple() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let base = URL(fileURLWithPath: "/tmp/claudec-test-addmnt2-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let configsDir = try makeConfigsDir(configs: [
      "base": [
        "additionalMounts": ["/opt/tools"],
        "entrypoint": ["sh"],
      ],
      "extra": [
        "additionalMounts": ["/data/cache", "/var/lib/extra"],
        "entrypoint": ["run"],
      ],
    ])
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: configsDir)
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: configsDir,
      configurations: ["base", "extra"],
      arguments: ["hello"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    let mounts = runtime.lastContainerConfiguration!.mounts
    #expect(mounts.contains { $0.containerPath == "/opt/tools" })
    #expect(mounts.contains { $0.containerPath == "/data/cache" })
    #expect(mounts.contains { $0.containerPath == "/var/lib/extra" })
  }

  @Test("Skips configurations with missing settings.json gracefully")
  func missingSettingsJson() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let base = URL(fileURLWithPath: "/tmp/claudec-test-noset-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let configsDir = URL(fileURLWithPath: "/tmp/claudec-test-configs-empty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: configsDir, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: configsDir)
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: configsDir,
      configurations: ["nonexistent"],
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    // Should not throw — missing configs are skipped
    try await session.start()
    _ = try await session.wait()

    // Still has the standard mounts
    let mounts = runtime.lastContainerConfiguration!.mounts
    #expect(mounts.contains { $0.containerPath == "/home/agent" })
    #expect(mounts.contains { $0.containerPath == "/agent-isolation/agents" })
  }

  @Test("Entrypoint override sets flag and replaces args")
  func entrypointOverride() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let base = URL(fileURLWithPath: "/tmp/claudec-test-override-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let configsDir = URL(fileURLWithPath: "/tmp/claudec-test-configs-ov-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: configsDir, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: configsDir)
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: configsDir,
      configurations: [],
      arguments: ["original", "args"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start(entrypoint: ["/bin/bash", "-c", "ls -la"])
    _ = try await session.wait()

    let env = runtime.lastContainerConfiguration!.environment
    #expect(env["AGENTC_ENTRYPOINT_OVERRIDE"] == "1")

    let entrypoint = runtime.lastContainerConfiguration!.entrypoint
    #expect(entrypoint == ["/bin/bash", "-c", "ls -la"])
  }

  @Test("Without entrypoint override, no override flag is set")
  func noEntrypointOverride() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let base = URL(fileURLWithPath: "/tmp/claudec-test-noov-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let configsDir = URL(fileURLWithPath: "/tmp/claudec-test-configs-noov-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: configsDir, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: configsDir)
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: configsDir,
      configurations: [],
      arguments: ["--print", "hello"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    let env = runtime.lastContainerConfiguration!.environment
    #expect(env["AGENTC_ENTRYPOINT_OVERRIDE"] == nil)

    let entrypoint = runtime.lastContainerConfiguration!.entrypoint
    #expect(entrypoint == ["--print", "hello"])
  }

  @Test("Entrypoint override for interactive shell")
  func entrypointOverrideInteractiveShell() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let base = URL(fileURLWithPath: "/tmp/claudec-test-shell-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let configsDir = URL(fileURLWithPath: "/tmp/claudec-test-configs-sh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: configsDir, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: configsDir)
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: configsDir,
      configurations: [],
      arguments: []
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start(entrypoint: ["/bin/bash"])
    _ = try await session.wait()

    let env = runtime.lastContainerConfiguration!.environment
    #expect(env["AGENTC_ENTRYPOINT_OVERRIDE"] == "1")

    let entrypoint = runtime.lastContainerConfiguration!.entrypoint
    #expect(entrypoint == ["/bin/bash"])
  }

  @Test("Additional mount host directories are created")
  func additionalMountHostDirsCreated() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let base = URL(fileURLWithPath: "/tmp/claudec-test-hostdir-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let configsDir = try makeConfigsDir(configs: [
      "testcfg": [
        "additionalMounts": ["/data/persistent"],
        "entrypoint": ["echo"],
      ]
    ])
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: configsDir)
    }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: configsDir,
      configurations: ["testcfg"],
      arguments: ["echo"]
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    // Verify the host directory was actually created
    let expectedSegment = AgentIsolationPathUtils.pathIdentifier(for: "/data/persistent")
    let expectedHostDir =
      base
      .appendingPathComponent("additionalMounts")
      .appendingPathComponent(expectedSegment)
    var isDir: ObjCBool = false
    #expect(
      FileManager.default.fileExists(atPath: expectedHostDir.path, isDirectory: &isDir))
    #expect(isDir.boolValue)
  }
}

// MARK: - Custom PTY Tests

@Suite("AgentSession customPTY")
struct AgentSessionCustomPTYTests {

  /// Build a minimal mock session in a scratch directory.
  private func makeSession(
    customPTY: Bool,
    runtime: MockRuntime = MockRuntime(config: .init(storagePath: "/tmp"))
  ) throws -> (AgentSession<MockRuntime>, URL) {
    let base = URL(fileURLWithPath: "/tmp/claudec-test-custompty-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let configsDir = base.appendingPathComponent("configurations")
    try FileManager.default.createDirectory(at: configsDir, withIntermediateDirectories: true)

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: configsDir,
      configurations: [],
      arguments: ["echo"],
      customPTY: customPTY
    )
    return (AgentSession(config: config, runtime: runtime), base)
  }

  @Test("customPTY defaults to false")
  func customPTYDefault() {
    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: URL(fileURLWithPath: "/tmp/home"),
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: URL(fileURLWithPath: "/tmp")
    )
    #expect(config.customPTY == false)
  }

  @Test("Without customPTY, write throws customPTYNotEnabled")
  func writeWithoutCustomPTY() async throws {
    let (session, base) = try makeSession(customPTY: false)
    defer { try? FileManager.default.removeItem(at: base) }
    try await session.start()

    #expect(throws: AgentSessionError.customPTYNotEnabled) {
      try session.write(Data("hello".utf8))
    }

    _ = try await session.wait()
  }

  @Test("Without customPTY, resize throws customPTYNotEnabled")
  func resizeWithoutCustomPTY() async throws {
    let (session, base) = try makeSession(customPTY: false)
    defer { try? FileManager.default.removeItem(at: base) }
    try await session.start()

    await #expect(throws: AgentSessionError.customPTYNotEnabled) {
      try await session.resize(cols: 80, rows: 24)
    }

    _ = try await session.wait()
  }

  @Test("Without customPTY, rawOut finishes immediately on start")
  func rawOutFinishesWithoutCustomPTY() async throws {
    let (session, base) = try makeSession(customPTY: false)
    defer { try? FileManager.default.removeItem(at: base) }
    try await session.start()

    var collected: [[UInt8]] = []
    for await chunk in session.rawOut {
      collected.append(chunk)
    }
    #expect(collected.isEmpty)

    _ = try await session.wait()
  }

  @Test("Without customPTY, IO honors allocateTTY (standardIO when false)")
  func standardIOWhenCustomPTYFalse() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let base = URL(fileURLWithPath: "/tmp/claudec-test-custompty-std-\(UUID().uuidString)")
    let profileDir = base.appendingPathComponent("home")
    let configsDir = base.appendingPathComponent("configurations")
    try FileManager.default.createDirectory(at: configsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profileDir,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: configsDir,
      configurations: [],
      arguments: ["echo"],
      allocateTTY: false,
      customPTY: false
    )
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    if case .standardIO = runtime.lastContainerConfiguration!.io {
      // expected
    } else {
      Issue.record("Expected .standardIO")
    }
  }

  @Test("With customPTY, IO is .custom with isTerminal=true")
  func customIOWhenCustomPTYTrue() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let (session, base) = try makeSession(customPTY: true, runtime: runtime)
    defer { try? FileManager.default.removeItem(at: base) }

    try await session.start()

    if case .custom(_, _, _, let isTerminal) = runtime.lastContainerConfiguration!.io {
      #expect(isTerminal == true)
    } else {
      Issue.record("Expected .custom IO in customPTY mode")
    }

    _ = try await session.wait()
  }

  @Test("With customPTY, resize forwards to container")
  func resizeForwarded() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let (session, base) = try makeSession(customPTY: true, runtime: runtime)
    defer { try? FileManager.default.removeItem(at: base) }

    try await session.start()
    try await session.resize(cols: 120, rows: 40)

    let container = try #require(runtime.lastContainer)
    #expect(container.resizeCalls.count == 1)
    #expect(container.resizeCalls.first?.cols == 120)
    #expect(container.resizeCalls.first?.rows == 40)

    _ = try await session.wait()
  }

  @Test("Operations on an unstarted session throw notStarted")
  func notStartedErrors() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let (session, base) = try makeSession(customPTY: true, runtime: runtime)
    defer { try? FileManager.default.removeItem(at: base) }

    #expect(throws: AgentSessionError.notStarted) {
      try session.write(Data("x".utf8))
    }
    await #expect(throws: AgentSessionError.notStarted) {
      try await session.resize(cols: 80, rows: 24)
    }
    await #expect(throws: AgentSessionError.notStarted) {
      _ = try await session.wait()
    }
  }

  @Test("start cannot be called twice")
  func startTwice() async throws {
    let (session, base) = try makeSession(customPTY: false)
    defer { try? FileManager.default.removeItem(at: base) }

    try await session.start()
    await #expect(throws: AgentSessionError.alreadyStarted) {
      try await session.start()
    }
    _ = try await session.wait()
  }

  @Test("timeout passed to start is forwarded to container.wait")
  func timeoutForwarded() async throws {
    let runtime = MockRuntime(config: .init(storagePath: "/tmp"))
    let (session, base) = try makeSession(customPTY: false, runtime: runtime)
    defer { try? FileManager.default.removeItem(at: base) }

    try await session.start(timeout: 42)
    _ = try await session.wait()

    let container = try #require(runtime.lastContainer)
    #expect(container.lastTimeoutInSeconds == 42)
  }
}

// MARK: - Container Resize Default Tests

@Suite("ContainerRuntimeContainer default resize")
struct ContainerResizeDefaultTests {

  final class MinimalContainer: ContainerRuntimeContainer, @unchecked Sendable {
    var id: String { "mock" }
    func wait(timeoutInSeconds: Int64?) async throws -> Int32 { 0 }
    func stop() async throws {}
    // No resize override — inherits the protocol default.
  }

  @Test("Default resize throws resizeNotSupported")
  func defaultResizeThrows() async {
    let container = MinimalContainer()
    await #expect(throws: ContainerRuntimeError.resizeNotSupported) {
      try await container.resize(cols: 80, rows: 24)
    }
  }
}
