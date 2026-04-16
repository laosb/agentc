import AgentIsolation
import ArgumentParser
import Foundation

struct SharedOptions: ParsableArguments {
  @Option(name: .shortAndLong, help: "Container runtime.")
  var runtime: RuntimeChoice?

  @Option(name: .shortAndLong, help: "Profile name (stored at ~/.agentc/profiles/<name>/).")
  var profile: String?

  @Option(name: .long, help: "Custom profile directory path (overrides --profile).")
  var profileDir: String?

  @Option(
    name: .shortAndLong,
    help: "Container image reference (default: ghcr.io/laosb/claudec:latest).")
  var image: String?

  @Flag(
    name: .long,
    inversion: .prefixedNo,
    help: "Pull latest image before running."
  )
  var updateImage: Bool = false

  @Flag(name: .long, help: "Keep old image after a successful update pull.")
  var keepOldImage: Bool = false

  @Option(name: .shortAndLong, help: "Host directory to mount as the workspace.")
  var workspace: String?

  @Option(
    name: .customLong("exclude"),
    help: "Comma-separated workspace sub-folders to mask with empty overlays.")
  var excludeFolders: String?

  @Option(name: .customLong("bootstrap"), help: "Path to a custom bootstrap/entrypoint script.")
  var bootstrapScript: String?

  @Flag(
    name: .customLong("respect-image-entrypoint"),
    help: "Use the container image's built-in entrypoint instead of the agentc bootstrap."
  )
  var respectImageEntrypoint: Bool = false

  @Option(
    name: .long,
    help: ArgumentHelp("Additional host directory to mount in the container.", valueName: "path")
  )
  var additionalMount: [String] = []

  @Option(
    name: [.short, .customLong("configurations")],
    help: "Comma-separated agent configuration names."
  )
  var configurationsFlag: String?

  @Option(name: .long, help: "Path to the local configurations directory.")
  var configurationsDir: String?

  @Option(name: .long, help: "Git repo URL for agent configurations.")
  var configurationsRepo: String?

  @Option(name: .long, help: "Seconds between configuration repo update checks.")
  var configurationsUpdateInterval: Int?

  @Option(name: .long, help: "Docker Engine API endpoint (socket path or tcp://host:port).")
  var dockerEndpoint: String?

  @Option(
    name: .customLong("cpus"),
    help: "Number of CPUs to allocate to the container (default: 1).")
  var cpuCount: Int?

  @Option(
    name: .customLong("memory-mib"),
    help: "Container memory limit in MiB (default: 1536).")
  var memoryLimitMiB: Int?

  @Flag(name: .long, help: "Skip the migration check for legacy ~/.claudec data.")
  var suppressMigrationFromClaudec: Bool = false

  @Flag(name: .shortAndLong, help: "Print extra information (image pulls, bootstrap setup, etc.).")
  var verbose: Bool = false

  @Option(name: .customLong("agentc-folder"), help: "Custom project settings folder path.")
  var agentcFolder: String?
}

// MARK: - Project Settings

extension SharedOptions {
  /// Load project settings from `--agentc-folder` or by searching upward from CWD.
  func loadProjectSettings() -> ProjectSettings? {
    if let folder = agentcFolder, !folder.isEmpty {
      return ProjectSettings.load(fromFolder: URL(fileURLWithPath: folder))
    }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return ProjectSettings.find(from: cwd)
  }
}

// MARK: - Resolution helpers

extension SharedOptions {
  /// Resolve profile directory and name from options.
  func resolveProfile(projectSettings: ProjectSettings? = nil) -> (name: String, dir: URL) {
    if let dir = profileDir, !dir.isEmpty {
      let url = URL(fileURLWithPath: dir)
      return (url.lastPathComponent, url)
    }
    let name = profile ?? projectSettings?.agent?.profile ?? "default"
    let home = MigrationCheck.homeDir
    return (
      name,
      home.appending(path: ".agentc/profiles/\(name)")
    )
  }

  /// Resolve configurations directory.
  func resolveConfigurationsDir() -> URL {
    if let dir = configurationsDir, !dir.isEmpty {
      return URL(fileURLWithPath: dir)
    }
    return MigrationCheck.homeDir
      .appending(path: ".agentc/configurations")
  }

  /// Resolve workspace URL.
  func resolveWorkspace() -> URL {
    if let ws = workspace, !ws.isEmpty {
      return URL(fileURLWithPath: ws)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  }

  /// Resolve excluded folders list.
  /// When both CLI and project settings specify excludes, both sets are merged.
  func resolveExcludeFolders(projectSettings: ProjectSettings? = nil) -> [String] {
    var result = [String]()
    if let raw = excludeFolders, !raw.isEmpty {
      result.append(contentsOf: raw.split(separator: ",").map(String.init))
    }
    if let extras = projectSettings?.agent?.excludes {
      result.append(contentsOf: extras)
    }
    return result
  }

  /// Resolve the ordered list of configuration names.
  ///
  /// Priority: explicit flag → project settings → profile settings.json → `["claude"]` default.
  func resolveConfigurations(
    positional: String?, profileDir: URL, projectSettings: ProjectSettings? = nil
  ) -> [String] {
    // 1. Explicit (flag or positional)
    if let explicit = configurationsFlag ?? positional, !explicit.isEmpty {
      return explicit.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }
    // 2. Project settings
    if let configs = projectSettings?.agent?.configurations, !configs.isEmpty {
      return configs
    }
    // 3. Profile settings.json
    let settingsURL = profileDir.appendingPathComponent("settings.json")
    if let data = try? Data(contentsOf: settingsURL),
      let settings = try? JSONDecoder().decode(ProfileSettings.self, from: data),
      let configs = settings.configurations, !configs.isEmpty
    {
      return configs
    }
    // 4. Default
    return ["claude"]
  }

  /// Resolve the bootstrap mode from CLI flags, project settings, and installed binary.
  ///
  /// Priority: CLI --respect-image-entrypoint → CLI --bootstrap → project settings → installed binary.
  func resolveBootstrapMode(projectSettings: ProjectSettings? = nil) throws -> BootstrapMode {
    if respectImageEntrypoint {
      return .imageDefault
    }
    if let path = bootstrapScript, !path.isEmpty {
      return .file(URL(fileURLWithPath: path))
    }
    if let agent = projectSettings?.agent {
      if agent.respectImageEntrypoint == true {
        return .imageDefault
      }
      if let path = agent.bootstrap, !path.isEmpty {
        return .file(URL(fileURLWithPath: path))
      }
    }
    let binary = try BootstrapManager.resolveBootstrapBinary(verbose: verbose)
    return .file(binary)
  }

  /// Resolve image reference. CLI flag → project settings → default.
  func resolveImage(projectSettings: ProjectSettings? = nil) -> String {
    image ?? projectSettings?.agent?.image ?? "ghcr.io/laosb/claudec:latest"
  }

  /// Resolve CPU count. CLI flag → project settings → 1.
  func resolveCpuCount(projectSettings: ProjectSettings? = nil) -> Int {
    cpuCount ?? projectSettings?.agent?.cpus ?? 1
  }

  /// Resolve memory limit. CLI flag → project settings → 1536.
  func resolveMemoryLimitMiB(projectSettings: ProjectSettings? = nil) -> Int {
    memoryLimitMiB ?? projectSettings?.agent?.memoryMiB ?? 1536
  }

  /// Resolve additional host mounts.
  /// When both CLI flags and project settings specify mounts, both sets are mounted.
  func resolveAdditionalMounts(projectSettings: ProjectSettings? = nil) -> [URL] {
    var result = additionalMount.map { URL(fileURLWithPath: $0) }
    if let extras = projectSettings?.agent?.additionalMounts {
      result.append(contentsOf: extras.map { URL(fileURLWithPath: $0) })
    }
    return result
  }

  /// Resolve entrypoint arguments.
  ///
  /// - `defaultArguments`: used when no CLI rest arguments are given; CLI overrides.
  /// - `additionalArguments`: always appended regardless.
  func resolveArguments(
    entrypointArguments: [String], projectSettings: ProjectSettings? = nil
  ) -> [String] {
    var args: [String]
    if entrypointArguments.isEmpty {
      args = projectSettings?.agent?.defaultArguments ?? []
    } else {
      args = entrypointArguments
    }
    if let additional = projectSettings?.agent?.additionalArguments {
      args.append(contentsOf: additional)
    }
    return args
  }
}

/// Settings from a profile's settings.json.
private struct ProfileSettings: Decodable {
  var configurations: [String]?
}
