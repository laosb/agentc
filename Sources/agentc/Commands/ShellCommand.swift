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
    // sh is interactive when no command is given
    let allocateTTY: Bool
    if command.isEmpty {
      allocateTTY = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    } else {
      allocateTTY = false
    }

    // Build the entrypoint override for shell dispatch
    let entrypointOverride: [String]
    if command.isEmpty {
      entrypointOverride = ["/bin/bash"]
    } else {
      entrypointOverride = ["/bin/bash", "-c", command.joined(separator: " ")]
    }

    let exitCode = try await SessionRunner.run(
      options: options,
      configurationsPositional: nil,
      allocateTTY: allocateTTY,
      arguments: [],
      entrypoint: entrypointOverride
    )
    throw ExitCode(exitCode)
  }
}
