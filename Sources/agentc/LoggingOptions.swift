import ArgumentParser
import Logging

struct LoggingOptions: ParsableArguments, Sendable {
  @Option(
    name: .long,
    help: ArgumentHelp("Append logs and stderr to a file instead of stderr.", valueName: "file"),
    completion: .file())
  var logFile: String?

  @Flag(name: .shortAndLong, help: "Log extra information (image pulls, bootstrap setup, etc.).")
  var verbose: Bool = false
}

/// Lets the entry point configure logging once, before any command starts work.
protocol LoggedCommand: ParsableCommand {
  var logging: LoggingOptions { get }
}

enum AgentcLogging {
  static func bootstrap(options: LoggingOptions) throws {
    if let path = options.logFile {
      let file = try LogFile(path: path)
      try file.redirectStandardError()
    }
    LoggingSystem.bootstrap { label in
      var handler = StreamLogHandler.standardError(label: label)
      handler.logLevel = options.verbose ? .debug : .info
      return handler
    }
  }
}

let logger = Logger(label: "agentc")
