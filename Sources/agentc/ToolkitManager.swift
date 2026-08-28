#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Subprocess

/// Locates or downloads the agentc Toolkit — the tools mounted into every session.
///
/// The toolkit is a handful of static binaries (curl, jq, ripgrep) plus a CA
/// bundle, mounted read-only at `/agent-isolation/toolkit` so that even an image
/// carrying nothing but a shell has something for `prepare.sh` to bootstrap
/// with. The bootstrap appends its `bin` to the *end* of `PATH`, so an image
/// that ships its own copies keeps using them.
///
/// It is versioned independently of agentc: a release is cut only when
/// `scripts/toolkit/manifest.sh` changes, so upgrading agentc does not re-download
/// a toolkit that did not move.
enum ToolkitManager {
  /// Toolkit release this agentc expects.
  ///
  /// Must equal `TOOLKIT_VERSION` in `scripts/toolkit/manifest.sh`;
  /// `ToolkitManifestTests` fails the build when the two drift apart.
  static let version = "1"

  /// Where an installed toolkit lives. Each version gets its own directory, so
  /// a downgrade finds its toolkit still in place.
  static var toolkitDir: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".agentc/toolkit/v\(version)")
  }

  /// Marks a directory as a complete toolkit, and records what is in it.
  private static let markerFile = "TOOLKIT"

  /// Resolve the toolkit directory, downloading it on first use of a version.
  ///
  /// Returns `nil` when no toolkit could be made available. That is deliberately
  /// not fatal: a session without one behaves exactly as it did before the
  /// toolkit existed, falling back to whatever the image ships.
  static func resolveToolkit(override: String? = nil, verbose: Bool = false) async -> URL? {
    if let override, !override.isEmpty {
      let directory = URL(fileURLWithPath: override)
      guard FileManager.default.fileExists(atPath: directory.path) else {
        writeToStderr("agentc: --toolkit \(override) does not exist; continuing without it\n")
        return nil
      }
      return directory
    }

    let directory = toolkitDir
    if FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(markerFile).path)
    {
      return directory
    }

    do {
      try await downloadToolkit(to: directory, verbose: verbose)
      return directory
    } catch {
      // Worth saying out loud even without --verbose: tools the configurations
      // expect to find may not be there.
      writeToStderr(
        "agentc: could not install the toolkit (\(error)); "
          + "continuing with the tools the image provides\n")
      return nil
    }
  }

  /// Why no toolkit could be installed. Never reaches the user as a thrown
  /// error — it is reported as a warning and the session carries on.
  private struct ToolkitUnavailable: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
  }

  private static func downloadToolkit(to destination: URL, verbose: Bool) async throws {
    let assetName = "agentc-toolkit-\(HostArchitecture.label)-linux-static.tar.gz"
    let url =
      "https://github.com/laosb/agentc/releases/download/toolkit-v\(version)/\(assetName)"

    if verbose {
      writeToStderr("agentc: downloading toolkit v\(version)...\n")
    }

    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("agentc-toolkit-dl-\(UUID().uuidString)")
    let staging = tmpDir.appendingPathComponent("toolkit")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let tarPath = tmpDir.appendingPathComponent(assetName)

    let curlResult = try await run(
      .name("curl"),
      arguments: ["-fsSL", url, "-o", tarPath.path],
      output: .discarded
    )
    guard curlResult.terminationStatus.isSuccess else {
      throw ToolkitUnavailable("failed to download \(url)")
    }

    let tarResult = try await run(
      .name("tar"),
      arguments: ["xzf", tarPath.path, "-C", staging.path],
      output: .discarded
    )
    guard tarResult.terminationStatus.isSuccess else {
      throw ToolkitUnavailable("failed to extract \(assetName)")
    }

    guard
      FileManager.default.fileExists(
        atPath: staging.appendingPathComponent(markerFile).path)
    else {
      throw ToolkitUnavailable("\(assetName) is not a toolkit bundle")
    }

    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

    do {
      try FileManager.default.moveItem(at: staging, to: destination)
    } catch {
      // Another agentc process very likely installed the same version while this
      // one was downloading; theirs is as good as ours.
      guard
        FileManager.default.fileExists(
          atPath: destination.appendingPathComponent(markerFile).path)
      else { throw error }
      return
    }

    if verbose {
      writeToStderr("agentc: toolkit installed to \(destination.path)\n")
    }
  }
}
