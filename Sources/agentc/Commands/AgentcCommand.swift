import ArgumentParser

@main
struct AgentcCommand: AsyncParsableCommand, LoggedCommand {
  @OptionGroup var logging: LoggingOptions

  static func main() async {
    do {
      var command = try await asyncParseAsRoot()
      // ArgumentParser resolves shared option groups across the command tree,
      // so flags work before or after a subcommand without inspecting raw argv.
      if let logged = command as? any LoggedCommand {
        try AgentcLogging.bootstrap(options: logged.logging)
      }
      if var asyncCommand = command as? any AsyncParsableCommand {
        try await asyncCommand.run()
      } else {
        try command.run()
      }
    } catch {
      exit(withError: error)
    }
  }

  static let configuration = CommandConfiguration(
    commandName: "agentc",
    abstract: "Run AI coding agents in isolated containers",
    discussion: """
      agentc manages containerised agent sessions with persistent profiles \
      and per-project isolation. It supports multiple container runtimes \
      (Docker, Apple Containerization) and pluggable agent configurations.

      The simplest invocation is just `agentc run`. Use `agentc --help` for \
      full details on each subcommand.
      """,
    subcommands: [
      RunCommand.self,
      ShellCommand.self,
      InitCommand.self,
      ImagesCommand.self,
      ProfilesCommand.self,
      VersionCommand.self,
      MigrateFromClaudecCommand.self,
    ],
    defaultSubcommand: RunCommand.self
  )
}
