import AgentIsolation
import ArgumentParser

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

struct EnvironmentVariableOption: ExpressibleByArgument, Sendable, Equatable {
  let key: String
  let value: String

  init?(argument: String) {
    guard let separator = argument.firstIndex(of: "="), separator != argument.startIndex else {
      return nil
    }

    let key = String(argument[..<separator])
    let value = String(argument[argument.index(after: separator)...])
    guard !key.contains("\0"), !value.contains("\0") else {
      return nil
    }

    self.key = key
    self.value = value
  }
}

extension MountPathScheme: ExpressibleByArgument {}

struct SharedOptions: ParsableArguments {
  @OptionGroup var logging: LoggingOptions

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
    name: .customLong("mount-path-scheme"),
    help: "Container destination scheme for host mounts (workspace or host)."
  )
  var mountPathScheme: MountPathScheme?

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
    name: .customLong("toolkit"),
    help: ArgumentHelp(
      "Directory holding an agentc Toolkit to mount, instead of the published one.",
      valueName: "path"))
  var toolkitPath: String?

  @Flag(
    name: .customLong("no-toolkit"),
    help: "Do not mount the agentc Toolkit; use only what the image provides."
  )
  var noToolkit: Bool = false

  @Option(
    name: .long,
    help: ArgumentHelp("Additional host directory to mount in the container.", valueName: "path")
  )
  var additionalMount: [String] = []

  @Option(
    name: .shortAndLong,
    help: ArgumentHelp(
      "Set a container environment variable. Repeat to set multiple variables.",
      valueName: "KEY=VALUE")
  )
  var env: [EnvironmentVariableOption] = []

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
    name: .long,
    help: ArgumentHelp(
      "Docker runtime to run the container with (e.g. kata, runsc, runc). "
        + "Defaults to the strongest isolation the daemon offers.",
      valueName: "name")
  )
  var dockerRuntime: String?

  @Option(
    name: .customLong("cpus"),
    help: "Number of CPUs to allocate to the container (default: 1).")
  var cpuCount: Int?

  @Option(
    name: .customLong("memory-mib"),
    help: "Container memory limit in MiB (default: 1536).")
  var memoryLimitMiB: Int?

  @Flag(
    name: .customLong("no-rootfs-cache"),
    help: ArgumentHelp(
      "Unpack the image again for this session instead of reusing a cached rootfs.",
      discussion: """
        A diagnostic and rollback switch for the Apple Containerization runtime; \
        Docker manages its own image storage and ignores it. Every session gets a \
        fresh, independent writable rootfs either way — this only controls whether \
        the unpacked image is reused between them. Never persisted in project settings.
        """)
  )
  var noRootfsCache: Bool = false

  @Flag(
    name: .customLong("repair-profile-ownership"),
    help: ArgumentHelp(
      "Take exclusive access to the profile and repair its home ownership.",
      discussion: """
        Use after importing files into a profile, changing ownership by hand, or \
        restoring a profile in place — an ownership record cannot detect those. \
        Selected configuration preparation still runs; this does not bypass it. \
        Fails with an actionable error if another agentc session is using the \
        profile. One-shot, never persisted in project settings.

        On a runtime whose ownership fast path is not enabled, every start already \
        repairs ownership, so this changes nothing beyond taking the profile \
        exclusively for the duration.
        """)
  )
  var repairProfileOwnership: Bool = false

  @Flag(
    name: .customLong("profile-ownership-fast-path"),
    help: ArgumentHelp(
      "Enable the profile-ownership fast path on a runtime that has not declared it.",
      discussion: """
        Experimental. The fast path skips the per-start recursive ownership repair \
        and relies on a recorded ownership state, which is only sound once the \
        runtime's mount ownership mapping has been characterized. Use it to do \
        that characterization, not in day-to-day runs.
        """,
      visibility: .hidden)
  )
  var profileOwnershipFastPath: Bool = false

  @Flag(name: .long, help: "Skip the migration check for legacy ~/.claudec data.")
  var suppressMigrationFromClaudec: Bool = false

  var verbose: Bool { logging.verbose }

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

  /// Resolve host-backed mount destinations. CLI flag → project settings → workspace.
  func resolveMountPathScheme(projectSettings: ProjectSettings? = nil) -> MountPathScheme {
    mountPathScheme ?? projectSettings?.agent?.mountPathScheme ?? .workspace
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

  /// A bootstrap and what it is known to be able to do.
  struct ResolvedBootstrap {
    var mode: BootstrapMode
    var capabilities: BootstrapCapabilities
  }

  /// Resolve the bootstrap mode from CLI flags, project settings, and installed binary.
  ///
  /// Priority: CLI --respect-image-entrypoint → CLI --bootstrap → project settings → installed binary.
  ///
  /// Capabilities are only ever attached to the bootstrap agentc installed itself,
  /// and only when its recorded digest still matches. A user-supplied `--bootstrap`
  /// script and an image's own entrypoint declare nothing, so nothing waits on them
  /// for a protocol they do not implement.
  func resolveBootstrapMode(projectSettings: ProjectSettings? = nil) async throws
    -> ResolvedBootstrap
  {
    if respectImageEntrypoint {
      return ResolvedBootstrap(mode: .imageDefault, capabilities: [])
    }
    if let path = bootstrapScript, !path.isEmpty {
      return ResolvedBootstrap(mode: .file(URL(fileURLWithPath: path)), capabilities: [])
    }
    if let agent = projectSettings?.agent {
      if agent.respectImageEntrypoint == true {
        return ResolvedBootstrap(mode: .imageDefault, capabilities: [])
      }
      if let path = agent.bootstrap, !path.isEmpty {
        return ResolvedBootstrap(mode: .file(URL(fileURLWithPath: path)), capabilities: [])
      }
    }
    let binary = try await BootstrapManager.resolveBootstrapBinary(verbose: verbose)
    return ResolvedBootstrap(
      mode: .file(binary), capabilities: BootstrapManager.capabilities(of: binary))
  }

  /// Resolve the agentc Toolkit directory to mount, or `nil` to mount none.
  ///
  /// Nothing is mounted when the image keeps its own entrypoint: without the
  /// bootstrap there is no one to put the toolkit on `PATH`.
  func resolveToolkitDir(bootstrapMode: BootstrapMode) async -> URL? {
    guard !noToolkit else { return nil }
    guard case .file = bootstrapMode else { return nil }
    return await ToolkitManager.resolveToolkit(override: toolkitPath, verbose: verbose)
  }

  /// Resolve image reference. CLI flag → project settings → default.
  func resolveImage(projectSettings: ProjectSettings? = nil) -> String {
    image ?? projectSettings?.agent?.image ?? "ghcr.io/laosb/claudec:latest"
  }

  /// Resolve the explicit Docker runtime. CLI flag → project settings → nil (auto-select).
  ///
  /// Returns the value verbatim — runtime names are administrator-defined aliases, and
  /// Docker can invoke containerd shims that never appear in its registered-runtime list,
  /// so there is nothing here we could meaningfully validate against.
  func resolveDockerRuntime(projectSettings: ProjectSettings? = nil) -> String? {
    let value = dockerRuntime ?? projectSettings?.docker?.runtime
    guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
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

  /// Resolve container environment variables.
  /// Project settings provide defaults; CLI values override matching keys.
  func resolveEnvironment(projectSettings: ProjectSettings? = nil) -> [String: String] {
    var result = projectSettings?.agent?.environment ?? [:]
    for variable in env {
      result[variable.key] = variable.value
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
