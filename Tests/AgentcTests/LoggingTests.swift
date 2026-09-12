import Foundation
import Testing

@testable import agentc

@Suite("CLI logging")
struct LoggingTests {
  @Test(
    "Logging options work across commands and positions",
    arguments: [
      ["--log-file", "agent.log", "run", "--verbose", "--stdio-log-file", "stdio.log"],
      ["run", "--log-file", "agent.log", "--verbose", "--stdio-log-file", "stdio.log"],
      ["--verbose", "sh", "--log-file", "agent.log", "--stdio-log-file", "stdio.log"],
      ["init", "--log-file", "agent.log", "--verbose"],
      ["profiles", "--log-file", "agent.log", "list", "--verbose"],
      ["profiles", "remove", "--log-file", "agent.log", "--verbose", "missing"],
      ["images", "list", "--log-file", "agent.log", "--verbose"],
      ["version", "--log-file", "agent.log", "--verbose"],
      ["migrate-from-claudec", "--log-file", "agent.log", "--verbose"],
      ["--log-file", "agent.log", "--verbose", "--stdio-log-file", "stdio.log"],
    ])
  func parsing(arguments: [String]) throws {
    let command = try AgentcCommand.parseAsRoot(arguments)
    let logged = try #require(command as? any LoggedCommand)
    #expect(logged.logging.logFile == "agent.log")
    #expect(logged.logging.verbose)
    if let run = command as? RunCommand { #expect(run.options.stdioLogFile == "stdio.log") }
    if let shell = command as? ShellCommand { #expect(shell.options.stdioLogFile == "stdio.log") }
  }

  @Test("Entrypoint logging flags remain workload arguments")
  func forwarding() throws {
    let command = try #require(
      AgentcCommand.parseAsRoot(["run", "--", "--log-file", "child.log", "--verbose"])
        as? RunCommand)
    #expect(command.logging.logFile == nil)
    #expect(!command.logging.verbose)
    #expect(command.entrypointArguments == ["--log-file", "child.log", "--verbose"])
  }

  @Test("Diagnostics go only to stderr by default")
  func stderrOnly() throws {
    let directory = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = try runCLI([
      "profiles", "remove", "--profiles-dir", directory.path, "missing",
    ])
    #expect(result.status == 1)
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.contains("does not exist"))
    #expect(result.stderr.contains("error agentc:"))
  }

  @Test("Log files append diagnostics and command failures without stdout leakage")
  func fileRedirection() throws {
    let directory = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("agent.log")
    try Data("previous run\n".utf8).write(to: log)
    for name in ["missing-one", "missing-two"] {
      let result = try runCLI([
        "--log-file", log.path, "profiles", "remove", "--profiles-dir", directory.path, name,
      ])
      #expect(result.status == 1)
      #expect(result.stdout.isEmpty)
      #expect(result.stderr.isEmpty)
    }
    let contents = try String(contentsOf: log, encoding: .utf8)
    #expect(contents.hasPrefix("previous run\n"))
    #expect(contents.contains("missing-one"))
    #expect(contents.contains("missing-two"))

    let failure = try runCLI([
      "images", "inspect", "--runtime", "docker", "--log-file", log.path, "missing:latest",
    ])
    #expect(failure.status != 0)
    #expect(failure.stdout.isEmpty)
    #expect(failure.stderr.isEmpty)
    #expect(
      try String(contentsOf: log, encoding: .utf8).contains("does not support image management"))
  }

  @Test(
    "Unusable log destinations fail before command work",
    arguments: [
      "--log-file", "--stdio-log-file",
    ])
  func invalidDestination(option: String) throws {
    let directory = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = try runCLI([
      "run", option, directory.appendingPathComponent("missing/log").path,
    ])
    #expect(result.status != 0)
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.contains("cannot open log file"))
  }

  @Test("Verbose startup diagnostics use the selected log file", arguments: [false, true])
  func startupDiagnostics(verbose: Bool) throws {
    let directory = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configurations = directory.appendingPathComponent("configurations")
    try FileManager.default.createDirectory(
      at: configurations.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try Data().write(to: configurations.appendingPathComponent(".agentc-last-pull"))
    let log = directory.appendingPathComponent("agent.log")
    let transcript = directory.appendingPathComponent("stdio.log")
    var arguments = [
      "run", "--runtime", "docker", "--docker-endpoint",
      directory.appendingPathComponent("missing.sock").path,
      "--respect-image-entrypoint", "--no-toolkit", "--suppress-migration-from-claudec",
      "--configurations-dir", configurations.path, "--configurations-update-interval", "86400",
      "--profile-dir", directory.appendingPathComponent("profile").path, "--workspace",
      directory.path,
      "--log-file", log.path, "--stdio-log-file", transcript.path,
    ]
    if verbose { arguments.append("--verbose") }
    let result = try runCLI(arguments)
    #expect(result.status != 0)  // The missing socket stops before any container starts.
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.isEmpty)
    let contents = try String(contentsOf: log, encoding: .utf8)
    #expect(contents.contains("timing phase=cli.configurations_repo") == verbose)
    #expect(contents.contains("debug agentc:") == verbose)
    #expect(try Data(contentsOf: transcript).isEmpty)
  }

  @Test("Log files reject stdout, devices, directories, and invalid paths")
  func rejectNonFiles() throws {
    for path in ["/dev/stdout", "/dev/null", "/tmp", "", "bad\0path"] {
      #expect(throws: LogFileError.self) { try LogFile(path: path) }
    }
    let result = try runCLI(["version", "--log-file", "/dev/stdout"])
    #expect(result.status != 0)
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.contains("must be a regular file"))
  }
}

func temporaryLogDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentc-log-\(UUID())")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private final class LoggingTestBundle: NSObject {}

private func runCLI(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String)
{
  #if os(macOS)
    // XCTest loads our tests into its own runner, whose argv[0] is outside
    // the build directory. Locate the loaded test bundle instead.
    var directory = Bundle(for: LoggingTestBundle.self).bundleURL
  #else
    var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
  #endif
  while !FileManager.default.isExecutableFile(
    atPath: directory.appendingPathComponent("agentc").path),
    directory.path != "/"
  {
    directory.deleteLastPathComponent()
  }
  let executable = directory.appendingPathComponent("agentc")
  try #require(
    FileManager.default.isExecutableFile(atPath: executable.path),
    "Could not locate the built agentc executable near the test bundle")
  let process = Process()
  process.executableURL = executable
  process.arguments = arguments
  process.standardInput = FileHandle.nullDevice
  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr
  try process.run()
  let out = stdout.fileHandleForReading.readDataToEndOfFile()
  let err = stderr.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (
    process.terminationStatus, String(decoding: out, as: UTF8.self),
    String(decoding: err, as: UTF8.self)
  )
}
