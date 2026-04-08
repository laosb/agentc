import ArgumentParser

@main
struct AgentcCommand: AsyncParsableCommand {
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
    subcommands: [RunCommand.self, ShellCommand.self, VersionCommand.self],
    defaultSubcommand: RunCommand.self
  )
}
