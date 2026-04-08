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
      Without arguments, opens an interactive bash shell. With arguments \
      after '--', runs the specified command.

      Examples:
        agentc sh                           # interactive shell
        agentc sh -- echo hello             # run a command
        agentc sh -- ls -la /home/agent     # run with flags
        agentc sh -c claude -- cat file.txt # specific configuration
      """
  )

  @OptionGroup var options: SharedOptions

  @Argument(parsing: .captureForPassthrough, help: "Command and arguments to run.")
  var command: [String] = []

  mutating func run() async throws {
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

    let bootstrapScript: URL? = options.bootstrapScript.map { URL(fileURLWithPath: $0) }

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
      bootstrapScript: bootstrapScript,
      arguments: [],
      allocateTTY: allocateTTY,
      memoryLimit: options.memoryLimit,
      additionalHostMounts: options.additionalMount.map { URL(fileURLWithPath: $0) }
    )

    let exitCode = try await runShellSession(
      config: isolationConfig, entrypoint: entrypointOverride)
    throw ExitCode(exitCode)
  }

  private func runShellSession(
    config: IsolationConfig, entrypoint: [String]
  ) async throws -> Int32 {
    let runtime = RuntimeChoice.resolve(explicit: options.runtime)

    let storagePath =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("sb.lao.agentc")
      .path

    switch runtime {
    #if ContainerRuntimeAppleContainer
      case .appleContainer:
        let runtimeConfig = ContainerRuntimeConfiguration(storagePath: storagePath)
        let runtime = AppleContainerRuntime(config: runtimeConfig)
        defer { Task { try? await runtime.shutdown() } }
        let session = AgentSession(config: config, runtime: runtime)
        return try await session.run(entrypoint: entrypoint)
    #endif
    #if ContainerRuntimeDocker
      case .docker:
        let runtimeConfig = ContainerRuntimeConfiguration(
          storagePath: storagePath, endpoint: options.dockerEndpoint)
        let runtime = DockerRuntime(config: runtimeConfig)
        defer { Task { try? await runtime.shutdown() } }
        let session = AgentSession(config: config, runtime: runtime)
        return try await session.run(entrypoint: entrypoint)
    #endif
    default:
      fatalError(
        "agentc: runtime '\(runtime.rawValue)' is not available. "
          + "Rebuild with the appropriate ContainerRuntime* trait enabled."
      )
    }
  }
}
