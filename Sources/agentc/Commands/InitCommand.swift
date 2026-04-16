import AgentIsolation
import ArgumentParser

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

struct InitCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "init",
    abstract: "Initialize agentc project settings and container environment",
    discussion: """
      Creates a `.agentc/settings.json` file and optionally runs the container \
      to ensure all configurations are loaded and prepared.

      Examples:
        agentc init                              # init in current directory
        agentc init ~/myproject                  # init in specified directory
        agentc init --skip-container-init        # settings only, no container
        agentc init --skip-project-settings      # container only, no settings
        agentc init --cpus 4 --memory-mib 4096   # init with custom resources
      """
  )

  @OptionGroup var options: SharedOptions

  @Argument(help: "Directory to initialize (default: current directory).")
  var directory: String?

  @Flag(name: .customLong("skip-project-settings"), help: "Skip creating .agentc/settings.json.")
  var skipProjectSettings: Bool = false

  @Flag(
    name: .customLong("skip-container-init"),
    help: "Skip running the container to prepare configurations.")
  var skipContainerInit: Bool = false

  mutating func run() async throws {
    let targetDir: URL
    if let dir = directory {
      targetDir = URL(fileURLWithPath: dir, isDirectory: true)
    } else {
      targetDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    // Step 1: Create .agentc/settings.json
    if !skipProjectSettings {
      try createProjectSettings(in: targetDir)
      print(
        "agentc: Created \(targetDir.appendingPathComponent(".agentc/settings.json").path)")
    }

    // Step 2: Container initialization — run through the full bootstrap so that
    // configurations are loaded and prepare.sh scripts execute, then exit
    // immediately via a trivial entrypoint.
    if !skipContainerInit {
      print("agentc: Initializing container environment...")
      do {
        let exitCode = try await SessionRunner.run(
          options: options,
          configurationsPositional: nil,
          allocateTTY: false,
          arguments: [],
          entrypoint: ["/bin/sh", "-c", "true"]
        )
        if exitCode == 0 {
          print("agentc: Container environment initialized successfully.")
        } else {
          print("agentc: Warning: container initialization exited with code \(exitCode).")
        }
      } catch {
        print(
          "agentc: Warning: container initialization failed: \(error.localizedDescription)")
      }
    }

    // Step 3: Getting-started info
    print()
    print("Project initialized! Get started with:")
    print()
    print("  agentc run          Start the agent")
    print("  agentc sh           Open a shell in the container")
    print("  agentc --help       Show all available options")
    print()
  }

  // MARK: - Settings file creation

  private func createProjectSettings(in targetDir: URL) throws {
    let agentcDir = targetDir.appendingPathComponent(".agentc")
    try FileManager.default.createDirectory(at: agentcDir, withIntermediateDirectories: true)

    let settings = buildSettings()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(settings)

    try data.write(to: agentcDir.appendingPathComponent("settings.json"))
  }

  private func buildSettings() -> ProjectSettings {
    let configurations: [String]
    if let raw = options.configurationsFlag, !raw.isEmpty {
      configurations = raw.split(separator: ",").map {
        String($0).trimmingCharacters(in: .whitespaces)
      }
    } else {
      configurations = ["claude"]
    }

    let excludes: [String]?
    if let raw = options.excludeFolders, !raw.isEmpty {
      excludes = raw.split(separator: ",").map(String.init)
    } else {
      excludes = nil
    }

    return ProjectSettings(
      agent: .init(
        image: options.image ?? "ghcr.io/laosb/claudec:latest",
        profile: options.profile,
        excludes: excludes,
        configurations: configurations,
        additionalMounts: options.additionalMount.isEmpty ? nil : options.additionalMount,
        cpus: options.cpuCount ?? 1,
        memoryMiB: options.memoryLimitMiB ?? 1536,
        bootstrap: options.bootstrapScript,
        respectImageEntrypoint: options.respectImageEntrypoint ? true : nil
      )
    )
  }
}
