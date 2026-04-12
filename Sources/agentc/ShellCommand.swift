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

struct ShellCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sh",
    abstract: "Open a shell or run a command inside the container",
    discussion: """
      Without arguments, opens an interactive bash shell. With arguments, runs the specified command.

      Examples:
        agentc sh                           # interactive shell
        agentc sh echo hello                # run a command
        agentc sh -- ls -la /home/agent     # run with flags
        agentc sh -c claude cat file.txt    # specific configuration
      """
  )

  @OptionGroup var options: SharedOptions

  @Argument(parsing: .remaining, help: "Command and arguments to run.")
  var command: [String] = []

  mutating func run() async throws {
    // Check for legacy claudec data before proceeding
    try MigrationCheck.checkIfNeeded(suppress: options.suppressMigrationFromClaudec)

    let (_, profileDir) = options.resolveProfile()
    let profileHomeDir = profileDir.appending(path: "home")
    let workspace = options.resolveWorkspace()
    let configurationsDir = options.resolveConfigurationsDir()
    let configNames = options.resolveConfigurations(
      positional: nil, profileDir: profileDir)
    let excludeFolders = options.resolveExcludeFolders()

    // sh is interactive when no command is given
    let allocateTTY: Bool
    if command.isEmpty {
      allocateTTY = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    } else {
      allocateTTY = false
    }

    // Ensure configurations repo
    try ConfigurationsManager.ensureRepo(
      at: configurationsDir,
      repoURL: options.configurationsRepo,
      updateInterval: options.configurationsUpdateInterval
    )

    // Build the entrypoint override for shell dispatch
    let entrypointOverride: [String]
    if command.isEmpty {
      entrypointOverride = ["/bin/bash"]
    } else {
      entrypointOverride = ["/bin/bash", "-c", command.joined(separator: " ")]
    }

    let isolationConfig = IsolationConfig(
      image: options.image,
      profileHomeDir: profileHomeDir,
      workspace: workspace,
      excludeFolders: excludeFolders,
      configurationsDir: configurationsDir,
      configurations: configNames,
      bootstrapMode: try options.resolveBootstrapMode(),
      arguments: [],
      allocateTTY: allocateTTY,
      cpuCount: options.cpuCount,
      memoryLimitMiB: options.memoryLimitMiB,
      additionalHostMounts: options.additionalMount.map { URL(fileURLWithPath: $0) }
    )

    let exitCode = try await runShellSession(
      config: isolationConfig, entrypoint: entrypointOverride)
    throw ExitCode(exitCode)
  }

  private func runShellSession(
    config: IsolationConfig, entrypoint: [String]
  ) async throws -> Int32 {
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
        try await runShellSessionWithRuntime(
          DockerRuntime(config: runtimeConfig), config: config, entrypoint: entrypoint)
      #else
        throw AgentcError.runtimeNotAvailable("docker")
      #endif
    case .appleContainer:
      #if ContainerRuntimeAppleContainer
        try await runShellSessionWithRuntime(
          AppleContainerRuntime(config: runtimeConfig), config: config, entrypoint: entrypoint)
      #else
        throw AgentcError.runtimeNotAvailable("apple-container")
      #endif
    }
  }

  private func runShellSessionWithRuntime<R: ContainerRuntime>(
    _ runtime: R, config: IsolationConfig, entrypoint: [String]
  ) async throws -> Int32 {
    defer { Task { try? await runtime.shutdown() } }
    let session = AgentSession(config: config, runtime: runtime)
    return try await session.run(entrypoint: entrypoint)
  }
}
