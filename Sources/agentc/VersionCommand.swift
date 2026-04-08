import ArgumentParser

struct VersionCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "version",
    abstract: "Print the agentc version"
  )

  func run() throws {
    if BuildInfo.gitSHA != "unknown" {
      print("agentc \(BuildInfo.version) (\(BuildInfo.gitSHA))")
    } else {
      print("agentc \(BuildInfo.version)")
    }
  }
}
