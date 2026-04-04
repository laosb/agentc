import AgentIsolation
#if ContainerRuntimeAppleContainer
  import AgentIsolationAppleContainerRuntime
#endif
#if ContainerRuntimeDocker
  import AgentIsolationDockerRuntime
#endif
import ArgumentParser
import Foundation
import Logging

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
    let profileDir: URL
    if let customDir = env["CLAUDEC_PROFILE_DIR"], !customDir.isEmpty {
      profileDir = URL(fileURLWithPath: customDir)
    } else {
      let profile = env["CLAUDEC_PROFILE"] ?? "default"
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

    // ── Resolve container runtime ──────────────────────────────────────
    let runtimeName = resolveRuntimeName(env: env)
    let dockerEndpoint = env["CLAUDEC_DOCKER_ENDPOINT"]

    // ── Set up runtime and run ─────────────────────────────────────────
    let storagePath =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("com.apple.claudec")
      .path

    let isolationConfig = IsolationConfig(
      image: image,
      profileHomeDir: profileDir.appending(path: "home"),
      workspace: workspace,
      excludeFolders: excludeFolders,
      bootstrapScript: bootstrapScript,
      arguments: arguments,
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
        exitCode = try await session.run()
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
        exitCode = try await session.run()
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
}

// MARK: - Errors

private enum ClaudecError: LocalizedError {
  case unsupportedEnvVar(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedEnvVar(let message):
      return "claudec: \(message)"
    }
  }
}
