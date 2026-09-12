import AgentIsolation

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if os(macOS) && ContainerRuntimeAppleContainer
  import AgentIsolationAppleContainerRuntime
#endif
#if ContainerRuntimeDocker
  import AgentIsolationDockerRuntime
#endif

/// Shared logic for commands that resolve configuration, set up a container
/// runtime, and run an agent session.
enum SessionRunner {

  /// Resolve all configuration from `options`, set up the container runtime,
  /// and run an agent session.
  ///
  /// - Parameters:
  ///   - options: The shared CLI options.
  ///   - configurationsPositional: Optional positional override for configuration names.
  ///   - allocateTTY: Whether to attach a TTY to the container.
  ///   - arguments: Pre-resolved arguments forwarded to the entrypoint.
  ///   - entrypoint: Optional entrypoint override (e.g. for shell commands).
  static func run(
    options: SharedOptions,
    configurationsPositional: String?,
    allocateTTY: Bool,
    arguments: [String],
    entrypoint: [String]? = nil
  ) async throws -> Int32 {
    let stdioLog = try options.stdioLogFile.map { try StdioLog(path: $0) }
    defer { stdioLog?.finish() }

    // Check for legacy claudec data before proceeding
    try MigrationCheck.checkIfNeeded(suppress: options.suppressMigrationFromClaudec)

    // Use the same stderr-only backend as CLI and dependency logs.
    let diagnostics: StartupDiagnostics? =
      options.verbose
      ? StartupDiagnostics(emit: { logger.debug("\(StartupDiagnostics.format($0))") })
      : nil

    let projectSettings = options.loadProjectSettings()

    let (_, profileDir) = options.resolveProfile(projectSettings: projectSettings)
    let profileHomeDir = profileDir.appending(path: "home")
    let workspace = options.resolveWorkspace()
    let configurationsDir = options.resolveConfigurationsDir()
    let configNames = options.resolveConfigurations(
      positional: configurationsPositional, profileDir: profileDir,
      projectSettings: projectSettings)
    let excludeFolders = options.resolveExcludeFolders(projectSettings: projectSettings)

    // Ensure configurations repo
    try await diagnostics.span("cli.configurations_repo") { _ in
      try await ConfigurationsManager.ensureRepo(
        at: configurationsDir,
        repoURL: options.configurationsRepo,
        updateInterval: options.configurationsUpdateInterval
      )
    }

    let resolvedImage = options.resolveImage(projectSettings: projectSettings)
    let bootstrap = try await diagnostics.span("cli.bootstrap_resolve") { context in
      let resolved = try await options.resolveBootstrapMode(projectSettings: projectSettings)
      context?.set("mode", resolved.mode.diagnosticLabel)
      context?.set(
        "ownership_handshake",
        resolved.capabilities.contains(.profileOwnershipHandshake))
      return resolved
    }
    let toolkitDir = await diagnostics.span("cli.toolkit_resolve") { context in
      let dir = await options.resolveToolkitDir(bootstrapMode: bootstrap.mode)
      context?.set("mounted", dir != nil)
      return dir
    }

    let isolationConfig = IsolationConfig(
      image: resolvedImage,
      profileHomeDir: profileHomeDir,
      workspace: workspace,
      mountPathScheme: options.resolveMountPathScheme(projectSettings: projectSettings),
      excludeFolders: excludeFolders,
      configurationsDir: configurationsDir,
      configurations: configNames,
      bootstrapMode: bootstrap.mode,
      toolkitDir: toolkitDir,
      arguments: arguments,
      environment: options.resolveEnvironment(projectSettings: projectSettings),
      allocateTTY: allocateTTY,
      cpuCount: options.resolveCpuCount(projectSettings: projectSettings),
      memoryLimitMiB: options.resolveMemoryLimitMiB(projectSettings: projectSettings),
      additionalHostMounts: options.resolveAdditionalMounts(projectSettings: projectSettings),
      verbose: options.verbose,
      diagnostics: diagnostics,
      stdioObserver: stdioLog?.observer,
      bootstrapCapabilities: bootstrap.capabilities,
      repairProfileOwnership: options.repairProfileOwnership,
      profileOwnershipFastPathOptIn: options.profileOwnershipFastPath
    )

    return try await dispatchToRuntime(
      options: options, config: isolationConfig, entrypoint: entrypoint,
      projectSettings: projectSettings, diagnostics: diagnostics)
  }

  // MARK: - Runtime dispatch

  private static func dispatchToRuntime(
    options: SharedOptions,
    config: IsolationConfig,
    entrypoint: [String]?,
    projectSettings: ProjectSettings?,
    diagnostics: StartupDiagnostics?
  ) async throws -> Int32 {
    let storagePath =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("sb.lao.agentc")
      .path

    let runtimeConfig = ContainerRuntimeConfiguration(
      storagePath: storagePath,
      endpoint: options.dockerEndpoint,
      ociRuntime: options.resolveDockerRuntime(projectSettings: projectSettings),
      warningHandler: { message in
        logger.warning("\(message)")
      },
      diagnostics: diagnostics,
      rootfsCacheEnabled: !options.noRootfsCache)

    let choice = RuntimeChoice.resolve(explicit: options.runtime)
    return switch choice {
    case .docker:
      #if ContainerRuntimeDocker
        try await executeSession(
          runtime: DockerRuntime(config: runtimeConfig),
          config: config,
          options: options,
          entrypoint: entrypoint)
      #else
        throw AgentcError.runtimeNotAvailable("docker")
      #endif
    case .appleContainer:
      #if os(macOS) && ContainerRuntimeAppleContainer
        try await executeSession(
          runtime: AppleContainerRuntime(config: runtimeConfig),
          config: config,
          options: options,
          entrypoint: entrypoint)
      #else
        throw AgentcError.runtimeNotAvailable("apple-container")
      #endif
    }
  }

  private static func executeSession<R: ContainerRuntime>(
    runtime: R,
    config: IsolationConfig,
    options: SharedOptions,
    entrypoint: [String]?
  ) async throws -> Int32 {
    defer { Task { try? await runtime.shutdown() } }
    if options.updateImage {
      try await runtime.prepare()
      let oldImage = try? await runtime.inspectImage(ref: config.image)
      let newImage = try? await runtime.pullImage(ref: config.image)
      if let oldImage, let newImage, oldImage.digest != newImage.digest {
        if options.verbose {
          logger.debug("Loaded newer image for \(config.image)")
        }
        if !options.keepOldImage {
          try? await runtime.removeImage(digest: oldImage.digest)
        }
      }
    }
    let session = AgentSession(config: config, runtime: runtime)
    do {
      try await session.start(entrypoint: entrypoint)
    } catch let error as ProfileOwnershipError {
      // Already phrased for a user; wrap it so it prints as an agentc message
      // rather than a Foundation placeholder.
      throw AgentcError.profileOwnership(error.description)
    }
    return try await session.wait()
  }
}
