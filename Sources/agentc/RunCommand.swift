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
        agentc run                          # default configurations
        agentc run claude                   # use 'claude' configuration
        agentc run claude,copilot           # multiple configurations
        agentc run claude -- --model opus   # forward args to entrypoint
      """
  )

  @OptionGroup var options: SharedOptions

  @Argument(help: "Comma-separated configuration names (default: from profile or 'claude').")
  var configurations: String?

  @Argument(parsing: .captureForPassthrough, help: "Arguments forwarded to the entrypoint.")
  var entrypointArguments: [String] = []

  mutating func run() async throws {
    let (_, profileDir) = options.resolveProfile()
    let profileHomeDir = profileDir.appending(path: "home")
    let workspace = options.resolveWorkspace()
    let configurationsDir = options.resolveConfigurationsDir()
    let configNames = options.resolveConfigurations(
      positional: configurations, profileDir: profileDir)
    let excludeFolders = options.resolveExcludeFolders()
    let allocateTTY = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1

    // Ensure configurations repo
    try ConfigurationsManager.ensureRepo(
      at: configurationsDir,
      repoURL: options.configurationsRepo,
      updateInterval: options.configurationsUpdateInterval
    )

    let bootstrapScript: URL? = options.bootstrapScript.map { URL(fileURLWithPath: $0) }

    let isolationConfig = IsolationConfig(
      image: options.image,
      profileHomeDir: profileHomeDir,
      workspace: workspace,
      excludeFolders: excludeFolders,
      configurationsDir: configurationsDir,
      configurations: configNames,
      bootstrapScript: bootstrapScript,
      arguments: entrypointArguments,
      allocateTTY: allocateTTY,
      memoryLimit: options.memoryLimit,
      additionalHostMounts: options.additionalMount.map { URL(fileURLWithPath: $0) }
    )

    let exitCode = try await runSession(config: isolationConfig)
    throw ExitCode(exitCode)
  }

  /// Set up the runtime, optionally update the image, and run the session.
  private func runSession(config: IsolationConfig) async throws -> Int32 {
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
        if options.updateImage {
          try await runtime.prepare()
          let oldImage = try? await runtime.inspectImage(ref: config.image)
          let newImage = try? await runtime.pullImage(ref: config.image)
          if let old = oldImage, let new = newImage, old.digest != new.digest {
            print("agentc: loaded newer image for \(config.image)")
            if !options.keepOldImage {
              try? await runtime.removeImage(digest: old.digest)
            }
          }
        }
        let session = AgentSession(config: config, runtime: runtime)
        return try await session.run()
    #endif
    #if ContainerRuntimeDocker
      case .docker:
        let runtimeConfig = ContainerRuntimeConfiguration(
          storagePath: storagePath, endpoint: options.dockerEndpoint)
        let runtime = DockerRuntime(config: runtimeConfig)
        defer { Task { try? await runtime.shutdown() } }
        if options.updateImage {
          try await runtime.prepare()
          let oldImage = try? await runtime.inspectImage(ref: config.image)
          let newImage = try? await runtime.pullImage(ref: config.image)
          if let old = oldImage, let new = newImage, old.digest != new.digest {
            print("agentc: loaded newer image for \(config.image)")
            if !options.keepOldImage {
              try? await runtime.removeImage(digest: old.digest)
            }
          }
        }
        let session = AgentSession(config: config, runtime: runtime)
        return try await session.run()
    #endif
    default:
      fatalError(
        "agentc: runtime '\(runtime.rawValue)' is not available. "
          + "Rebuild with the appropriate ContainerRuntime* trait enabled."
      )
    }
  }
}
