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

    let (_, profileDir) = options.resolveProfile()
    let profileHomeDir = profileDir.appending(path: "home")
    let workspace = options.resolveWorkspace()
    let configurationsDir = options.resolveConfigurationsDir()
    let configNames = options.resolveConfigurations(
      positional: options.configurationsFlag, profileDir: profileDir)
    let excludeFolders = options.resolveExcludeFolders()
    let allocateTTY = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1

    // Ensure configurations repo
    try ConfigurationsManager.ensureRepo(
      at: configurationsDir,
      repoURL: options.configurationsRepo,
      updateInterval: options.configurationsUpdateInterval
    )

    let isolationConfig = IsolationConfig(
      image: options.image,
      profileHomeDir: profileHomeDir,
      workspace: workspace,
      excludeFolders: excludeFolders,
      configurationsDir: configurationsDir,
      configurations: configNames,
      bootstrapMode: try options.resolveBootstrapMode(),
      arguments: entrypointArguments,
      allocateTTY: allocateTTY,
      cpuCount: options.cpuCount,
      memoryLimitMiB: options.memoryLimitMiB,
      additionalHostMounts: options.additionalMount.map { URL(fileURLWithPath: $0) }
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
    let runtime = DockerRuntime(config: runtimeConfig)
    defer { Task { try? await runtime.shutdown() } }
    if options.updateImage {
      try await runtime.prepare()
      let oldImage = try? await runtime.inspectImage(ref: config.image)
      let newImage = try? await runtime.pullImage(ref: config.image)
      if let oldImage, let newImage, oldImage.digest != newImage.digest {
        print("agentc: loaded newer image for \(config.image)")
        if !options.keepOldImage {
          try? await runtime.removeImage(digest: oldImage.digest)
        }
      }
    }
    let session = AgentSession(config: config, runtime: runtime)
    return try await session.run()
  }
}
