import Foundation

/// Settings from an agent configuration's settings.json.
private struct AgentConfigurationSettings: Decodable {
  var additionalMounts: [String]?
}

/// Orchestrates running an isolated agent container session using a ``ContainerRuntime``.
///
/// `AgentSession` is responsible for:
/// - Preparing the runtime
/// - Computing workspace paths and directory layout
/// - Building container mounts (profile home, workspace, exclude overlays, configurations, additional mounts)
/// - Configuring and running the container
/// - Performing necessary cleanups (temp dirs)
public struct AgentSession<Runtime: ContainerRuntime>: Sendable {
  public let config: IsolationConfig
  public let runtime: Runtime

  public init(config: IsolationConfig, runtime: Runtime) {
    self.config = config
    self.runtime = runtime
  }

  /// Run the agent session and return the container process exit code.
  ///
  /// - Parameter entrypoint: Optional entrypoint override. When non-nil, the bootstrap
  ///   executes this instead of the last configuration's entrypoint (e.g. `["/bin/bash"]`
  ///   for an interactive shell, or `["/bin/bash", "-c", "ls -la"]` for a command).
  public func run(entrypoint entrypointOverride: [String]? = nil) async throws -> Int32 {
    try await runtime.prepare()

    let canonicalWorkspace = AgentIsolationPathUtils.resolveSymlinksWithPlatformConsiderations(
      config.workspace)
    let wsContainerPath = AgentIsolationPathUtils.workspaceContainerPath(for: config.workspace)

    try FileManager.default.createDirectory(
      at: config.profileHomeDir,
      withIntermediateDirectories: true
    )

    // Build mounts list
    var mounts: [ContainerConfiguration.Mount] = []

    // Profile home → /home/agent
    mounts.append(
      .init(
        hostPath: config.profileHomeDir.path,
        containerPath: "/home/agent"
      ))

    // Workspace
    mounts.append(
      .init(
        hostPath: canonicalWorkspace.path,
        containerPath: wsContainerPath
      ))

    // Excluded folders: each gets an empty temp dir mounted as a read-only overlay
    var tempDirs: [URL] = []
    defer {
      for dir in tempDirs {
        try? FileManager.default.removeItem(at: dir)
      }
    }

    for rawFolder in config.excludeFolders {
      let folder = rawFolder.trimmingCharacters(in: .init(charactersIn: "/"))
      guard !folder.isEmpty else { continue }
      let tempDir = try makeTempDir()
      tempDirs.append(tempDir)
      mounts.append(
        .init(
          hostPath: AgentIsolationPathUtils.resolveSymlinksWithPlatformConsiderations(tempDir).path,
          containerPath: "\(wsContainerPath)/\(folder)",
          isReadOnly: true
        ))
    }

    // Configurations directory → /agent-isolation/agents (read-only)
    mounts.append(
      .init(
        hostPath: config.configurationsDir.path,
        containerPath: "/agent-isolation/agents",
        isReadOnly: true
      ))

    // Additional mounts from agent configurations
    let additionalMountsDir = config.profileHomeDir.deletingLastPathComponent()
      .appendingPathComponent("additionalMounts")
    for configName in config.configurations {
      let settingsURL = config.configurationsDir
        .appendingPathComponent(configName)
        .appendingPathComponent("settings.json")
      guard let data = try? Data(contentsOf: settingsURL) else { continue }
      guard let settings = try? JSONDecoder().decode(AgentConfigurationSettings.self, from: data)
      else { continue }
      for containerPath in settings.additionalMounts ?? [] {
        guard !containerPath.isEmpty else { continue }
        let segment = AgentIsolationPathUtils.pathIdentifier(for: containerPath)
        let hostDir = additionalMountsDir.appendingPathComponent(segment)
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
        mounts.append(
          .init(
            hostPath: hostDir.path,
            containerPath: containerPath
          ))
      }
    }

    // Additional host mounts (from CLI --additional-mount flags)
    for hostMount in config.additionalHostMounts {
      let canonical = AgentIsolationPathUtils.resolveSymlinksWithPlatformConsiderations(hostMount)
      let containerPath = "/workspace/\(AgentIsolationPathUtils.pathIdentifier(for: canonical.path))"
      mounts.append(
        .init(
          hostPath: canonical.path,
          containerPath: containerPath
        ))
    }

    // Bootstrap script: copy to temp dir so it can be shared as a virtiofs volume
    var overridesEntrypoint = false
    if let bootstrapScript = config.bootstrapScript {
      let tempDir = try makeTempDir()
      tempDirs.append(tempDir)
      let dest = tempDir.appendingPathComponent("entrypoint.sh")
      try FileManager.default.copyItem(at: bootstrapScript, to: dest)

      let srcPerms =
        (try? FileManager.default.attributesOfItem(
          atPath: bootstrapScript.path
        )[.posixPermissions] as? Int) ?? 0o644
      try FileManager.default.setAttributes(
        [.posixPermissions: srcPerms | 0o111],
        ofItemAtPath: dest.path
      )

      mounts.append(
        .init(
          hostPath: AgentIsolationPathUtils.resolveSymlinksWithPlatformConsiderations(tempDir).path,
          containerPath: "/entrypoint-bootstrap"
        ))
      overridesEntrypoint = true
    }

    // Environment: pass configurations and optional entrypoint override to bootstrap
    var environment: [String: String] = [:]
    environment["CLAUDEC_CONFIGURATIONS"] = config.configurations.joined(separator: ",")

    // When an entrypoint override is provided (e.g. "sh" dispatch), the override
    // args replace config.arguments as the container CMD, and a flag tells the
    // bootstrap to exec them directly instead of running the configuration entrypoint.
    var containerArgs = config.arguments
    if let override = entrypointOverride {
      containerArgs = override
      environment["CLAUDEC_ENTRYPOINT_OVERRIDE"] = "1"
    }

    // Build the final entrypoint (CMD args to the image's or custom ENTRYPOINT)
    let entrypoint: [String]
    if overridesEntrypoint {
      entrypoint = ["/entrypoint-bootstrap/entrypoint.sh"] + containerArgs
    } else {
      entrypoint = containerArgs
    }

    let io: ContainerConfiguration.IO =
      config.allocateTTY ? .currentTerminal : .standardIO

    let containerConfig = ContainerConfiguration(
      entrypoint: entrypoint,
      overridesImageEntrypoint: overridesEntrypoint,
      workingDirectory: wsContainerPath,
      environment: environment,
      mounts: mounts,
      io: io
    )

    let container = try await runtime.runContainer(
      imageRef: config.image,
      configuration: containerConfig
    )
    defer { _runBlocking { try await runtime.removeContainer(container) } }

    let exitCode = try await container.wait(timeoutInSeconds: nil)
    try await container.stop()
    return exitCode
  }

  // MARK: - Helpers

  private func makeTempDir() throws -> URL {
    let dir = URL(fileURLWithPath: "/tmp/claudec-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

}

/// Fire-and-forget helper for calling async cleanup in a defer block.
private func _runBlocking(_ body: @escaping @Sendable () async throws -> Void) {
  // Best-effort cleanup — runs on a detached task since defer can't be async.
  Task { try? await body() }
}
