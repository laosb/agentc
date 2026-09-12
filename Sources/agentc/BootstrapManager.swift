import AgentIsolation
import Crypto
import Subprocess

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

/// Locates or downloads the agentc-bootstrap binary used as the container entrypoint.
enum BootstrapManager {
  /// Expected install location for the bootstrap binary.
  static var bootstrapBinaryPath: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".agentc/bin/bootstrap")
  }

  /// Describes exactly one installed bootstrap artifact.
  ///
  /// Written by the agentc build that installed the binary, and keyed to that
  /// binary's digest. A bootstrap agentc did not install, or one that has since
  /// been replaced, therefore declares nothing — capabilities are carried
  /// alongside the artifact, never inferred from its path or name.
  struct BootstrapDescriptor: Codable {
    var version: String
    var sha256: String
    var protocols: [String]
  }

  /// Protocol name for the profile-ownership handshake, as recorded in the
  /// descriptor and understood by this build.
  static let ownershipProtocolName = "profile-ownership-v\(ProfileOwnershipProtocol.version)"

  static var descriptorPath: URL {
    bootstrapBinaryPath.appendingPathExtension("json")
  }

  /// What the installed bootstrap can take part in.
  ///
  /// Returns nothing unless a descriptor exists *and* its recorded digest still
  /// matches the binary on disk, so swapping in a hand-built or older bootstrap
  /// silently falls back to legacy behavior instead of hanging on a handshake it
  /// cannot complete.
  static func capabilities(of binary: URL) -> BootstrapCapabilities {
    guard binary.standardizedFileURL == bootstrapBinaryPath.standardizedFileURL else {
      return []
    }
    guard let data = try? Data(contentsOf: descriptorPath),
      let descriptor = try? JSONDecoder().decode(BootstrapDescriptor.self, from: data),
      descriptor.protocols.contains(ownershipProtocolName),
      let actual = sha256Hex(of: binary),
      actual == descriptor.sha256
    else {
      return []
    }
    return [.profileOwnershipHandshake]
  }

  private static func sha256Hex(of url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func writeDescriptor(for binary: URL, version: String) {
    guard let digest = sha256Hex(of: binary) else { return }
    let descriptor = BootstrapDescriptor(
      version: version, sha256: digest, protocols: [ownershipProtocolName])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    guard let data = try? encoder.encode(descriptor) else { return }
    try? data.write(to: descriptorPath, options: .atomic)
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
    let arch = HostArchitecture.label
    let assetName = "agentc-bootstrap-\(arch)-linux-static.tar.gz"
    let url =
      "https://github.com/laosb/agentc/releases/download/v\(version)/\(assetName)"

    if verbose {
      logger.debug("Downloading bootstrap binary...")
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

    // Record what this exact artifact can do, keyed to its digest. Written last,
    // so a failed install never leaves a descriptor claiming capabilities for a
    // binary that is not there.
    writeDescriptor(for: destination, version: version)

    if verbose {
      logger.debug("Bootstrap binary installed to \(destination.path)")
    }
  }
}
