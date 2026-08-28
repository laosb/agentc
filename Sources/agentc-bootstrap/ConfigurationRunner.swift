#if canImport(FoundationEssentials) && canImport(Musl)
  import FoundationEssentials
  import Musl

  /// Settings from an agent configuration's settings.json.
  private struct ConfigSettings: Decodable {
    var dependsOn: [String]?
    var entrypoint: [String]?
    var additionalBinPaths: [String]?
    var additionalMounts: [String]?
  }

  enum ConfigurationRunner {
    /// Process agent configurations and exec the entrypoint. Does not return on success.
    static func run(arguments: [String]) throws {
      let configurationsDir = "/agent-isolation/agents"
      let requested =
        (Helpers.envVar("AGENTC_CONFIGURATIONS") ?? "claude")
        .split(separator: ",")
        .map { trimmingWhitespace($0) }
        .filter { !$0.isEmpty }

      // Expand `dependsOn` so every configuration is set up after the ones it
      // depends on. The host normally passes an already-expanded list; expanding
      // again is a no-op, and it keeps the bootstrap correct on its own.
      let (configurations, settingsByName) = try resolve(
        requested: requested, in: configurationsDir)

      let home = Helpers.envVar("HOME") ?? "/home/agent"

      // Build up PATH — start with ~/.local/bin prepended to current PATH.
      var path = Helpers.envVar("PATH") ?? "/usr/bin:/bin"
      path = "\(home)/.local/bin:\(path)"

      // The toolkit goes last, and everything after this point prepends, so it
      // stays last: its tools are only reached for names nothing else provides.
      Toolkit.appendToPath(&path)
      Toolkit.exportCABundleIfImageHasNone()

      var lastEntrypoint: [String]?

      for configName in configurations {
        let configDir = "\(configurationsDir)/\(configName)"
        let settings = settingsByName[configName]

        // Add additional bin paths to PATH.
        for binPath in settings?.additionalBinPaths ?? [] {
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
            try Helpers.run(command: prepareScript, arguments: [], output: .stderr)
          } else {
            let shell = access("/bin/bash", X_OK) == 0 ? "/bin/bash" : "/bin/sh"
            try Helpers.run(command: shell, arguments: [prepareScript], output: .stderr)
          }
        }

        // The last configuration that defines an entrypoint wins, so a
        // configuration may depend on another purely to extend its setup.
        if let entrypoint = settings?.entrypoint, !entrypoint.isEmpty {
          lastEntrypoint = entrypoint
        }
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

      // Execute the resolved entrypoint with remaining CLI args appended.
      guard let entrypoint = lastEntrypoint else {
        throw BootstrapError.configurationError(
          "no entrypoint defined in configurations: \(configurations.joined(separator: ","))")
      }

      // Fall back to /bin/sh when the configured entrypoint shell isn't available.
      var finalEntrypoint = entrypoint
      if finalEntrypoint[0] == "/bin/bash" && access("/bin/bash", X_OK) != 0 {
        finalEntrypoint[0] = "/bin/sh"
      }
      Helpers.execReplace(command: finalEntrypoint + arguments)
    }

    // MARK: - Dependency resolution

    /// Expand `dependsOn` into a flat activation order, loading each configuration once.
    ///
    /// Dependencies are visited depth-first and emitted before the configuration
    /// that requires them, so the requested configuration comes last and its
    /// entrypoint is the one that gets exec'd. Repeats keep their earliest position.
    private static func resolve(
      requested: [String], in configurationsDir: String
    ) throws -> (order: [String], settings: [String: ConfigSettings]) {
      var order: [String] = []
      var emitted: Set<String> = []
      var visiting: [String] = []
      var loaded: [String: ConfigSettings] = [:]

      func load(_ name: String) throws -> ConfigSettings {
        if let cached = loaded[name] { return cached }
        let settingsPath = "\(configurationsDir)/\(name)/settings.json"
        guard access(settingsPath, F_OK) == 0 else {
          throw BootstrapError.configurationError(
            "configuration '\(name)' not found at \(settingsPath)")
        }
        let settingsData = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let settings = try JSONDecoder().decode(ConfigSettings.self, from: settingsData)
        loaded[name] = settings
        return settings
      }

      func visit(_ name: String) throws {
        guard !emitted.contains(name) else { return }
        if let start = visiting.firstIndex(of: name) {
          let cycle = (visiting[start...] + [name]).joined(separator: " -> ")
          throw BootstrapError.configurationError(
            "dependency cycle in configurations: \(cycle)")
        }

        visiting.append(name)
        for dependency in try load(name).dependsOn ?? [] {
          let dependency = trimmingWhitespace(dependency[...])
          guard !dependency.isEmpty else { continue }
          try visit(dependency)
        }
        visiting.removeLast()

        emitted.insert(name)
        order.append(name)
      }

      for name in requested {
        try visit(name)
      }
      return (order, loaded)
    }

    /// Trim leading and trailing whitespace (`CharacterSet` is unavailable here).
    private static func trimmingWhitespace(_ substring: Substring) -> String {
      var slice = substring
      while slice.first?.isWhitespace == true { slice = slice.dropFirst() }
      while slice.last?.isWhitespace == true { slice = slice.dropLast() }
      return String(slice)
    }
  }
#endif
