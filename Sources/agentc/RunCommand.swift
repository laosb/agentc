import AgentIsolation
import ArgumentParser
import Foundation
import Logging

#if ContainerRuntimeAppleContainer
  import AgentIsolationAppleContainerRuntime
#endif
#if ContainerRuntimeDocker
  import AgentIsolationDockerRuntime
#endif

struct RunCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Run an agent in an isolated container",
    discussion: """
      Start an agent session using the specified (or default) configurations. \
      Arguments after '--' are forwarded to the configuration's entrypoint.

      Examples:
        agentc run                             # default configurations
        agentc run -c claude                   # use 'claude' configuration
        agentc run -c claude,copilot           # multiple configurations
        agentc run -c claude -- --model opus   # forward args to entrypoint
      """
  )

  @OptionGroup var options: SharedOptions

  @Argument(parsing: .remaining, help: "Arguments forwarded to the entrypoint.")
  var entrypointArguments: [String] = []

  mutating func run() async throws {
    // Check for legacy claudec data before proceeding
    try MigrationCheck.checkIfNeeded(suppress: options.suppressMigrationFromClaudec)

    let projectSettings = options.loadProjectSettings()

    let (_, profileDir) = options.resolveProfile(projectSettings: projectSettings)
    let profileHomeDir = profileDir.appending(path: "home")
    let workspace = options.resolveWorkspace()
    let configurationsDir = options.resolveConfigurationsDir()
    let configNames = options.resolveConfigurations(
      positional: options.configurationsFlag, profileDir: profileDir,
      projectSettings: projectSettings)
    let excludeFolders = options.resolveExcludeFolders(projectSettings: projectSettings)
    let allocateTTY = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1

    // Ensure configurations repo
    try ConfigurationsManager.ensureRepo(
      at: configurationsDir,
      repoURL: options.configurationsRepo,
      updateInterval: options.configurationsUpdateInterval
    )

    let resolvedImage = options.resolveImage(projectSettings: projectSettings)
    let resolvedArguments = options.resolveArguments(
      entrypointArguments: entrypointArguments, projectSettings: projectSettings)

    let isolationConfig = IsolationConfig(
      image: resolvedImage,
      profileHomeDir: profileHomeDir,
      workspace: workspace,
      excludeFolders: excludeFolders,
      configurationsDir: configurationsDir,
      configurations: configNames,
      bootstrapMode: try options.resolveBootstrapMode(projectSettings: projectSettings),
      arguments: resolvedArguments,
      allocateTTY: allocateTTY,
      cpuCount: options.resolveCpuCount(projectSettings: projectSettings),
      memoryLimitMiB: options.resolveMemoryLimitMiB(projectSettings: projectSettings),
      additionalHostMounts: options.resolveAdditionalMounts(projectSettings: projectSettings),
      verbose: options.verbose
    )

    let exitCode = try await runSession(config: isolationConfig)
    throw ExitCode(exitCode)
  }

  /// Set up the runtime, optionally update the image, and run the session.
  private func runSession(config: IsolationConfig) async throws -> Int32 {
    let storagePath =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("sb.lao.agentc")
      .path

    let runtimeConfig = ContainerRuntimeConfiguration(
      storagePath: storagePath, endpoint: options.dockerEndpoint)

    let choice = RuntimeChoice.resolve(explicit: options.runtime)
    return switch choice {
    case .docker:
      #if ContainerRuntimeDocker
        try await runSessionWithRuntime(
          DockerRuntime(config: runtimeConfig), config: config)
      #else
        throw AgentcError.runtimeNotAvailable("docker")
      #endif
    case .appleContainer:
      #if ContainerRuntimeAppleContainer
        try await runSessionWithRuntime(
          AppleContainerRuntime(config: runtimeConfig), config: config)
      #else
        throw AgentcError.runtimeNotAvailable("apple-container")
      #endif
    }
  }

  private func runSessionWithRuntime<R: ContainerRuntime>(
    _ runtime: R, config: IsolationConfig
  ) async throws -> Int32 {
    defer { Task { try? await runtime.shutdown() } }
    if options.updateImage {
      try await runtime.prepare()
      let oldImage = try? await runtime.inspectImage(ref: config.image)
      let newImage = try? await runtime.pullImage(ref: config.image)
      if let oldImage, let newImage, oldImage.digest != newImage.digest {
        if options.verbose {
          print("agentc: loaded newer image for \(config.image)")
        }
        if !options.keepOldImage {
          try? await runtime.removeImage(digest: oldImage.digest)
        }
      }
    }
    let session = AgentSession(config: config, runtime: runtime)
    return try await session.run()
  }
}
