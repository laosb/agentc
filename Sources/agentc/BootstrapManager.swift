#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

import Subprocess

/// Locates or downloads the agentc-bootstrap binary used as the container entrypoint.
enum BootstrapManager {
  /// Expected install location for the bootstrap binary.
  static var bootstrapBinaryPath: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".agentc/bin/bootstrap")
  }

  /// Resolve the bootstrap binary path, downloading from GitHub Releases if missing.
  static func resolveBootstrapBinary(verbose: Bool = false) async throws -> URL {
    let binaryPath = bootstrapBinaryPath

    if FileManager.default.fileExists(atPath: binaryPath.path) {
      return binaryPath
    }

    guard BuildInfo.version != "dev" else {
      throw AgentcError.bootstrapNotFound(
        """
        Bootstrap binary not found at \(binaryPath.path).
        For development builds, build it manually:
          swift build --product agentc-bootstrap --swift-sdk <linux-static-sdk> -c release
          cp .build/<sdk>/release/agentc-bootstrap ~/.agentc/bin/bootstrap
        Or use --bootstrap <path> to specify a custom bootstrap file,
        or use --respect-image-entrypoint to skip the bootstrap.
        """)
    }

    try await downloadBootstrap(version: BuildInfo.version, to: binaryPath, verbose: verbose)
    return binaryPath
  }

  private static func downloadBootstrap(
    version: String, to destination: URL, verbose: Bool
  ) async throws {
    let arch = hostArchLabel()
    let assetName = "agentc-bootstrap-\(arch)-linux-static.tar.gz"
    let url =
      "https://github.com/laosb/agentc/releases/download/v\(version)/\(assetName)"

    if verbose {
      writeToStderr("agentc: downloading bootstrap binary...\n")
    }

    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("agentc-bootstrap-dl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let tarPath = tmpDir.appendingPathComponent(assetName)

    // Download
    let curlResult = try await run(
      .name("curl"),
      arguments: ["-fsSL", url, "-o", tarPath.path],
      output: .discarded
    )
    guard curlResult.terminationStatus.isSuccess else {
      throw AgentcError.bootstrapDownloadFailed(
        "Failed to download bootstrap binary from \(url)")
    }

    // Extract
    let tarResult = try await run(
      .name("tar"),
      arguments: ["xzf", tarPath.path, "-C", tmpDir.path],
      output: .discarded
    )
    guard tarResult.terminationStatus.isSuccess else {
      throw AgentcError.bootstrapDownloadFailed(
        "Failed to extract bootstrap archive")
    }

    // Install
    let extractedBinary = tmpDir.appendingPathComponent("agentc-bootstrap")
    let destDir = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: destDir, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: extractedBinary, to: destination)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: destination.path)

    if verbose {
      writeToStderr("agentc: bootstrap binary installed to \(destination.path)\n")
    }
  }

  private static func hostArchLabel() -> String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x64"
    #else
      return "unknown"
    #endif
  }
}
