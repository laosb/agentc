import ArgumentParser
import Foundation

struct SharedOptions: ParsableArguments {
  @Option(name: .long, help: "Container runtime: 'docker' or 'apple-container'.")
  var runtime: RuntimeChoice?

  @Option(name: .long, help: "Profile name (stored at ~/.agentc/profiles/<name>/).")
  var profile: String?

  @Option(name: .long, help: "Custom profile directory path (overrides --profile).")
  var profileDir: String?

  @Option(name: .long, help: "Container image reference.")
  var image: String = "ghcr.io/laosb/claudec:latest"

  @Flag(
    name: .long,
    inversion: .prefixedNo,
    help: "Pull latest image before running."
  )
  var updateImage: Bool = false

  @Flag(name: .long, help: "Keep old image after a successful update pull.")
  var keepOldImage: Bool = false

  @Option(name: .long, help: "Host directory to mount as the workspace.")
  var workspace: String?

  @Option(name: .long, help: "Comma-separated workspace sub-folders to mask with empty overlays.")
  var excludeFolders: String?

  @Option(name: .long, help: "Path to a custom bootstrap/entrypoint script.")
  var bootstrapScript: String?

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

  @Option(name: .long, help: "Container memory limit (e.g. '1536m').")
  var memoryLimit: String = "1536m"

  @Flag(name: .long, help: "Skip the migration check for legacy ~/.claudec data.")
  var suppressMigrationFromClaudec: Bool = false
}

// MARK: - Resolution helpers

extension SharedOptions {
  /// Resolve profile directory and name from options.
  func resolveProfile() -> (name: String, dir: URL) {
    if let dir = profileDir, !dir.isEmpty {
      let url = URL(fileURLWithPath: dir)
      return (url.lastPathComponent, url)
    }
    let name = profile ?? "default"
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
  func resolveExcludeFolders() -> [String] {
    guard let raw = excludeFolders, !raw.isEmpty else { return [] }
    return raw.split(separator: ",").map(String.init)
  }

  /// Resolve the ordered list of configuration names.
  ///
  /// Priority: explicit flag/positional → profile settings.json → `["claude"]` default.
  func resolveConfigurations(positional: String?, profileDir: URL) -> [String] {
    // 1. Explicit (flag or positional)
    if let explicit = configurationsFlag ?? positional, !explicit.isEmpty {
      return explicit.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }
    // 2. Profile settings.json
    let settingsURL = profileDir.appendingPathComponent("settings.json")
    if let data = try? Data(contentsOf: settingsURL),
      let settings = try? JSONDecoder().decode(ProfileSettings.self, from: data),
      let configs = settings.configurations, !configs.isEmpty
    {
      return configs
    }
    // 3. Default
    return ["claude"]
  }
}

/// Settings from a profile's settings.json.
private struct ProfileSettings: Decodable {
  var configurations: [String]?
}
