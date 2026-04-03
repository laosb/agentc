import AgentIsolation
import AgentIsolationAppleContainerRuntime
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

    // ── Set up runtime ─────────────────────────────────────────────────
    let storagePath =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("com.apple.claudec")
      .path

    let runtimeConfig = ContainerRuntimeConfiguration(storagePath: storagePath)
    let runtime = AppleContainerRuntime(config: runtimeConfig)

    // ── Auto-update image ──────────────────────────────────────────────
    let autoUpdate = env["CLAUDEC_IMAGE_AUTO_UPDATE"].map { $0 != "0" } ?? true
    if autoUpdate {
      try await runtime.prepare()
      let oldImage = try? await runtime.inspectImage(ref: image)
      let newImage = try? await runtime.pullImage(ref: image)
      if let old = oldImage, let new = newImage, old.digest != new.digest {
        print("claudec: loaded newer image for \(image)")
      }
    }

    // ── Run container via AgentSession ─────────────────────────────────
    let config = IsolationConfig(
      image: image,
      profileHomeDir: profileDir.appending(path: "home"),
      workspace: workspace,
      excludeFolders: excludeFolders,
      bootstrapScript: bootstrapScript,
      arguments: arguments,
      allocateTTY: allocateTTY
    )

    let session = AgentSession(config: config, runtime: runtime)
    let exitCode = try await session.run()
    throw ExitCode(exitCode)
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
