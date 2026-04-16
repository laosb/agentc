import ArgumentParser

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
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
    let projectSettings = options.loadProjectSettings()
    let allocateTTY = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    let resolvedArguments = options.resolveArguments(
      entrypointArguments: entrypointArguments, projectSettings: projectSettings)

    let exitCode = try await SessionRunner.run(
      options: options,
      configurationsPositional: options.configurationsFlag,
      allocateTTY: allocateTTY,
      arguments: resolvedArguments
    )
    throw ExitCode(exitCode)
  }
}
