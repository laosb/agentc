import FoundationEssentials
import Musl

/// Settings from an agent configuration's settings.json.
private struct ConfigSettings: Decodable {
  var entrypoint: [String]?
  var additionalBinPaths: [String]?
  var additionalMounts: [String]?
}

enum ConfigurationRunner {
  /// Process agent configurations and exec the entrypoint. Does not return on success.
  static func run(arguments: [String]) throws {
    let configurationsDir = "/agent-isolation/agents"
    let configurations =
      (Helpers.envVar("AGENTC_CONFIGURATIONS") ?? "claude")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }

    let home = Helpers.envVar("HOME") ?? "/home/agent"

    // Build up PATH — start with ~/.local/bin prepended to current PATH.
    var path = Helpers.envVar("PATH") ?? "/usr/bin:/bin"
    path = "\(home)/.local/bin:\(path)"

    var lastEntrypoint: [String]?

    for configName in configurations {
      let configDir = "\(configurationsDir)/\(configName)"
      let settingsPath = "\(configDir)/settings.json"

      guard access(settingsPath, F_OK) == 0 else {
        throw BootstrapError.configurationError(
          "configuration '\(configName)' not found at \(settingsPath)")
      }

      let settingsData = try Data(
        contentsOf: URL(fileURLWithPath: settingsPath))
      let settings = try JSONDecoder().decode(
        ConfigSettings.self, from: settingsData)

      // Add additional bin paths to PATH.
      for binPath in settings.additionalBinPaths ?? [] {
        let expanded = binPath.replacingOccurrences(of: "$HOME", with: home)
        path = "\(expanded):\(path)"
      }
      setenv("PATH", path, 1)

      // Run prepare.sh directly (kernel uses shebang for interpreter).
      let prepareScript = "\(configDir)/prepare.sh"
      if access(prepareScript, F_OK) == 0 {
        fputs(
          "==> Running prepare.sh for configuration '\(configName)'...\n",
          stderr)
        try Helpers.run(command: prepareScript, arguments: [])
      }

      lastEntrypoint = settings.entrypoint
    }

    // Finalize PATH for the exec.
    setenv("PATH", path, 1)

    // Entrypoint override (e.g. from "agentc sh" dispatch).
    if Helpers.envVar("AGENTC_ENTRYPOINT_OVERRIDE") == "1" {
      guard !arguments.isEmpty else {
        throw BootstrapError.execFailed(
          "entrypoint override requested but no arguments provided")
      }
      Helpers.execReplace(command: arguments)
    }

    // Execute the last configuration's entrypoint with remaining CLI args appended.
    guard let entrypoint = lastEntrypoint, !entrypoint.isEmpty else {
      throw BootstrapError.configurationError(
        "no entrypoint defined in last configuration")
    }

    Helpers.execReplace(command: entrypoint + arguments)
  }
}
