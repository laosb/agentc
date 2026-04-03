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

    // CLAUDEC_CONTAINER_FLAGS is not supported in the Swift implementation.
    if let flags = env["CLAUDEC_CONTAINER_FLAGS"], !flags.isEmpty {
      throw ClaudecError.unsupportedEnvVar(
        "CLAUDEC_CONTAINER_FLAGS is not supported. "
          + "Configure container options via the supported environment variables."
      )
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

    // ── Check for script updates ───────────────────────────────────────
    let checkUpdate = env["CLAUDEC_CHECK_UPDATE"].map { $0 != "0" } ?? true
    if checkUpdate {
      let executableDir = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
      await checkForScriptUpdate(in: executableDir)
    }

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

// MARK: - Update checks

private func checkForScriptUpdate(in dir: URL) async {
  let gitDir = dir.appending(path: ".git")
  guard FileManager.default.fileExists(atPath: gitDir.path) else { return }

  let fetchResult = await runProcess(
    ["/usr/bin/git", "-C", dir.path, "fetch", "--quiet", "origin"],
    captureOutput: false
  )
  guard fetchResult.exitCode == 0 else { return }

  let localResult = await runProcess(
    ["/usr/bin/git", "-C", dir.path, "rev-parse", "HEAD"],
    captureOutput: true
  )
  guard localResult.exitCode == 0 else { return }
  let local = localResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

  let remoteResult = await runProcess(
    ["/usr/bin/git", "-C", dir.path, "rev-parse", "@{u}"],
    captureOutput: true
  )
  let remote =
    remoteResult.exitCode == 0
    ? remoteResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
    : ""

  if !remote.isEmpty && local != remote {
    print("claudec: update available — run: git -C '\(dir.path)' pull --ff-only")
  }
}

// MARK: - Process helper

private struct ProcessResult: Sendable {
  let exitCode: Int32
  let output: String
}

private func runProcess(_ args: [String], captureOutput: Bool) async -> ProcessResult {
  await withCheckedContinuation { continuation in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: args[0])
    process.arguments = Array(args.dropFirst())
    process.standardError = FileHandle.nullDevice

    let pipe = Pipe()
    if captureOutput {
      process.standardOutput = pipe
    } else {
      process.standardOutput = FileHandle.nullDevice
    }

    process.terminationHandler = { p in
      let output: String
      if captureOutput {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        output = String(data: data, encoding: .utf8) ?? ""
      } else {
        output = ""
      }
      continuation.resume(returning: ProcessResult(exitCode: p.terminationStatus, output: output))
    }

    do {
      try process.run()
    } catch {
      continuation.resume(returning: ProcessResult(exitCode: -1, output: ""))
    }
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
