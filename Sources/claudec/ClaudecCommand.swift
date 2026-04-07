import AgentIsolation
import ArgumentParser
import Foundation
import Logging

#if ContainerRuntimeAppleContainer
  import AgentIsolationAppleContainerRuntime
#endif
#if ContainerRuntimeDocker
  import AgentIsolationDockerRuntime
#endif

/// Settings from a claudec profile's settings.json.
private struct ProfileSettings: Decodable {
  var configurations: [String]?
}

@main
struct ClaudecCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "claudec",
    abstract: "Run Claude Code in an isolated container"
  )

  @Argument(
    parsing: .captureForPassthrough, help: "Arguments forwarded to the container entrypoint")
  var arguments: [String] = []

  mutating func run() async throws {
    let env = ProcessInfo.processInfo.environment

    // Reject legacy shell-script env vars that are not supported in the Swift binary.
    for unsupported in [
      "CLAUDEC_CONTAINER_FLAGS",
      "CLAUDEC_CHECK_UPDATE",
    ] {
      if let value = env[unsupported], !value.isEmpty {
        throw ClaudecError.unsupportedEnvVar(
          "\(unsupported) is not supported in the Swift implementation."
        )
      }
    }

    // ── Resolve profile directory ──────────────────────────────────────
    let profile: String
    let profileDir: URL
    if let customDir = env["CLAUDEC_PROFILE_DIR"], !customDir.isEmpty {
      profileDir = URL(fileURLWithPath: customDir)
      profile = profileDir.lastPathComponent
    } else {
      profile = env["CLAUDEC_PROFILE"] ?? "default"
      let home = URL(fileURLWithPath: NSHomeDirectory())
      profileDir =
        home
        .appending(path: ".claudec")
        .appending(path: "profiles")
        .appending(path: profile)
    }

    // ── Resolve remaining config ───────────────────────────────────────
    let image = env["CLAUDEC_IMAGE"] ?? "ghcr.io/laosb/claudec:latest"
    let workspace: URL = {
      if let ws = env["CLAUDEC_WORKSPACE"], !ws.isEmpty {
        return URL(fileURLWithPath: ws)
      }
      return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()

    let excludeFolders: [String] = {
      guard let raw = env["CLAUDEC_EXCLUDE_FOLDERS"], !raw.isEmpty else { return [] }
      return raw.split(separator: ",").map(String.init)
    }()

    let bootstrapScript: URL? = {
      guard let path = env["CLAUDEC_BOOTSTRAP_SCRIPT"], !path.isEmpty else { return nil }
      return URL(fileURLWithPath: path)
    }()

    let allocateTTY = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1

    // ── Manage configurations repo ─────────────────────────────────────
    let configurationsDir: URL
    if let customDir = env["CLAUDEC_CONFIGURATIONS_DIR"], !customDir.isEmpty {
      configurationsDir = URL(fileURLWithPath: customDir)
    } else {
      let home = URL(fileURLWithPath: NSHomeDirectory())
      configurationsDir = home.appending(path: ".claudec").appending(path: "configurations")
    }
    try ensureConfigurationsRepo(at: configurationsDir, env: env)

    // ── Resolve configurations list ────────────────────────────────────
    let configurations: [String] = {
      // 1. Override via env var
      if let raw = env["CLAUDEC_CONFIGURATIONS"], !raw.isEmpty {
        return raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
      }
      // 2. Read from profile settings.json
      let settingsURL = profileDir.appendingPathComponent("settings.json")
      if let data = try? Data(contentsOf: settingsURL),
        let settings = try? JSONDecoder().decode(ProfileSettings.self, from: data),
        let configs = settings.configurations, !configs.isEmpty
      {
        return configs
      }
      // 3. Default
      return ["claude"]
    }()

    // ── Check for legacy workspace migration ───────────────────────────
    let profileHomeDir = profileDir.appending(path: "home")
    try WorkspaceMigration.migrateIfNeeded(
      profileHomeDir: profileHomeDir,
      legacyPath: legacyWorkspaceContainerPath(for: workspace),
      newPath: workspaceContainerPath(for: workspace)
    )

    // ── Resolve container runtime ──────────────────────────────────────
    let runtimeName = resolveRuntimeName(env: env)
    let dockerEndpoint = env["CLAUDEC_DOCKER_ENDPOINT"]

    // ── Detect "sh" dispatch ──────────────────────────────────────────
    var entrypointOverride: [String]? = nil
    var forwardedArguments = arguments

    if let first = arguments.first, first == "sh" {
      let remaining = Array(arguments.dropFirst())
      if remaining.isEmpty {
        entrypointOverride = ["/bin/bash"]
      } else {
        entrypointOverride = ["/bin/bash", "-c", remaining.joined(separator: " ")]
      }
      forwardedArguments = []
    }

    // ── Set up runtime and run ─────────────────────────────────────────
    let storagePath =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("sb.lao.agentc")
      .path

    // If there's no sb.lao.agentc but there's an old (accidental) com.apple.claudec, migrate it to avoid confusion.
    let oldStoragePath =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("com.apple.claudec")
      .path
    if !FileManager.default.fileExists(atPath: storagePath),
      FileManager.default.fileExists(atPath: oldStoragePath)
    {
      try FileManager.default.moveItem(atPath: oldStoragePath, toPath: storagePath)
    }

    let isolationConfig = IsolationConfig(
      image: image,
      profileHomeDir: profileHomeDir,
      workspace: workspace,
      excludeFolders: excludeFolders,
      configurationsDir: configurationsDir,
      configurations: configurations,
      bootstrapScript: bootstrapScript,
      arguments: forwardedArguments,
      allocateTTY: allocateTTY
    )

    let autoUpdate = env["CLAUDEC_IMAGE_AUTO_UPDATE"].map { $0 != "0" } ?? true
    let removeOldImage = env["CLAUDEC_IMAGE_AUTO_UPDATE_REMOVE_OLD"].map { $0 != "0" } ?? true

    let exitCode: Int32

    switch runtimeName {
    #if ContainerRuntimeAppleContainer
      case "apple-container":
        let runtimeConfig = ContainerRuntimeConfiguration(storagePath: storagePath)
        let runtime = AppleContainerRuntime(config: runtimeConfig)
        defer { Task { try? await runtime.shutdown() } }
        if autoUpdate {
          try await runtime.prepare()
          let oldImage = try? await runtime.inspectImage(ref: image)
          let newImage = try? await runtime.pullImage(ref: image)
          if let old = oldImage, let new = newImage, old.digest != new.digest {
            print("claudec: loaded newer image for \(image)")
            if removeOldImage {
              try? await runtime.removeImage(digest: old.digest)
            }
          }
        }
        let session = AgentSession(config: isolationConfig, runtime: runtime)
        exitCode = try await session.run(entrypoint: entrypointOverride)
    #endif
    #if ContainerRuntimeDocker
      case "docker":
        let runtimeConfig = ContainerRuntimeConfiguration(
          storagePath: storagePath, endpoint: dockerEndpoint)
        let runtime = DockerRuntime(config: runtimeConfig)
        defer { Task { try? await runtime.shutdown() } }
        if autoUpdate {
          try await runtime.prepare()
          let oldImage = try? await runtime.inspectImage(ref: image)
          let newImage = try? await runtime.pullImage(ref: image)
          if let old = oldImage, let new = newImage, old.digest != new.digest {
            print("claudec: loaded newer image for \(image)")
            if removeOldImage {
              try? await runtime.removeImage(digest: old.digest)
            }
          }
        }
        let session = AgentSession(config: isolationConfig, runtime: runtime)
        exitCode = try await session.run(entrypoint: entrypointOverride)
    #endif
    default:
      fatalError(
        "claudec: runtime '\(runtimeName)' is not available. "
          + "Rebuild with the appropriate ContainerRuntime* trait enabled."
      )
    }

    throw ExitCode(exitCode)
  }

  /// Determine which container runtime to use based on env var and platform defaults.
  private func resolveRuntimeName(env: [String: String]) -> String {
    if let explicit = env["CLAUDEC_CONTAINER_RUNTIME"], !explicit.isEmpty {
      return explicit
    }

    #if os(macOS)
      #if ContainerRuntimeAppleContainer
        return "apple-container"
      #elseif ContainerRuntimeDocker
        return "docker"
      #else
        fatalError("claudec: no container runtime available. Build with a ContainerRuntime* trait.")
      #endif
    #else
      #if ContainerRuntimeDocker
        return "docker"
      #else
        fatalError("claudec: no container runtime available. Build with a ContainerRuntime* trait.")
      #endif
    #endif
  }

  // MARK: - Configurations Repo Management

  /// Ensure the configurations repo is cloned and up-to-date.
  ///
  /// Uses advisory file locking (`flock`) to prevent concurrent processes from
  /// racing on clone or pull operations.
  private func ensureConfigurationsRepo(at dir: URL, env: [String: String]) throws {
    let repoURL =
      env["CLAUDEC_CONFIGURATIONS_REPO"]
      ?? "https://github.com/laosb/agent-isolation-configurations"
    let updateInterval = Int(env["CLAUDEC_CONFIGURATIONS_UPDATE_INTERVAL_SECONDS"] ?? "") ?? 86400

    let parentDir = dir.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

    // Acquire an exclusive file lock so parallel claudec processes don't race.
    let lockPath = parentDir.appendingPathComponent(".configurations.lock").path
    let lockFD = open(lockPath, O_RDWR | O_CREAT, 0o644)
    guard lockFD >= 0 else {
      throw ClaudecError.configRepoError("Failed to create configurations lock file")
    }
    defer {
      flock(lockFD, LOCK_UN)
      close(lockFD)
    }
    guard flock(lockFD, LOCK_EX) == 0 else {
      throw ClaudecError.configRepoError("Failed to acquire configurations lock")
    }

    let gitDir = dir.appendingPathComponent(".git")

    if !FileManager.default.fileExists(atPath: gitDir.path) {
      // Remove dir if it exists but isn't a valid git repo
      if FileManager.default.fileExists(atPath: dir.path) {
        try FileManager.default.removeItem(at: dir)
      }
      FileHandle.standardError.write(
        Data("claudec: cloning configurations repo...\n".utf8))
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["clone", "--depth", "1", repoURL, dir.path]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw ClaudecError.configRepoError(
          "Failed to clone configurations repo from \(repoURL)")
      }
      return
    }

    // Check if update is needed
    let markerFile = dir.appendingPathComponent(".claudec-last-pull")
    let now = Date()
    if let attrs = try? FileManager.default.attributesOfItem(atPath: markerFile.path),
      let modified = attrs[.modificationDate] as? Date,
      now.timeIntervalSince(modified) < Double(updateInterval)
    {
      return  // Recently updated
    }

    // Pull updates
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", dir.path, "pull", "--ff-only", "--quiet"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    // Update marker regardless of pull success (avoid repeated failures)
    FileManager.default.createFile(atPath: markerFile.path, contents: nil)
  }
}

// MARK: - Errors

private enum ClaudecError: LocalizedError {
  case unsupportedEnvVar(String)
  case configRepoError(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedEnvVar(let message):
      return "claudec: \(message)"
    case .configRepoError(let message):
      return "claudec: \(message)"
    }
  }
}
