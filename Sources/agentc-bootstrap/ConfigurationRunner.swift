#if canImport(FoundationEssentials) && canImport(Musl)
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
        .map { sub -> String in
          var s = sub[...]
          while s.first?.isWhitespace == true { s = s.dropFirst() }
          while s.last?.isWhitespace == true { s = s.dropLast() }
          return String(s)
        }

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
          let expanded = binPath.replacing("$HOME", with: home)
          path = "\(expanded):\(path)"
        }
        setenv("PATH", path, 1)

        // Run prepare.sh if it exists. Prefer direct execution (kernel uses
        // shebang), but fall back to an explicit interpreter when the file
        // lacks the execute bit (e.g. read-only mount from git checkout).
        let prepareScript = "\(configDir)/prepare.sh"
        if access(prepareScript, F_OK) == 0 {
          if Helpers.envVar("AGENTC_VERBOSE") == "1" {
            fputs(
              "==> Running prepare.sh for configuration '\(configName)'...\n",
              stderr)
          }
          if access(prepareScript, X_OK) == 0 {
            try Helpers.run(command: prepareScript, arguments: [])
          } else {
            let shell = access("/bin/bash", X_OK) == 0 ? "/bin/bash" : "/bin/sh"
            try Helpers.run(command: shell, arguments: [prepareScript])
          }
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
        // The host may request /bin/bash but the container image might only
        // have /bin/sh (e.g. Alpine). Fall back when needed.
        var cmd = arguments
        if cmd[0] == "/bin/bash" && access("/bin/bash", X_OK) != 0 {
          cmd[0] = "/bin/sh"
        }
        Helpers.execReplace(command: cmd)
      }

      // Execute the last configuration's entrypoint with remaining CLI args appended.
      guard let entrypoint = lastEntrypoint, !entrypoint.isEmpty else {
        throw BootstrapError.configurationError(
          "no entrypoint defined in last configuration")
      }

      // Fall back to /bin/sh when the configured entrypoint shell isn't available.
      var finalEntrypoint = entrypoint
      if finalEntrypoint[0] == "/bin/bash" && access("/bin/bash", X_OK) != 0 {
        finalEntrypoint[0] = "/bin/sh"
      }
      Helpers.execReplace(command: finalEntrypoint + arguments)
    }
  }
#endif
