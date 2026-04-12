import Foundation

/// Locates or downloads the agentc-bootstrap binary used as the container entrypoint.
enum BootstrapManager {
  /// Expected install location for the bootstrap binary.
  static var bootstrapBinaryPath: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".agentc/bin/bootstrap")
  }

  /// Resolve the bootstrap binary path, downloading from GitHub Releases if missing.
  static func resolveBootstrapBinary() throws -> URL {
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

    try downloadBootstrap(version: BuildInfo.version, to: binaryPath)
    return binaryPath
  }

  private static func downloadBootstrap(
    version: String, to destination: URL
  ) throws {
    let arch = hostArchLabel()
    let assetName = "agentc-bootstrap-\(arch)-linux-static.tar.gz"
    let url =
      "https://github.com/laosb/agentc/releases/download/v\(version)/\(assetName)"

    FileHandle.standardError.write(
      Data("agentc: downloading bootstrap binary...\n".utf8))

    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("agentc-bootstrap-dl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let tarPath = tmpDir.appendingPathComponent(assetName)

    // Download
    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    curl.arguments = ["curl", "-fsSL", url, "-o", tarPath.path]
    try curl.run()
    curl.waitUntilExit()
    guard curl.terminationStatus == 0 else {
      throw AgentcError.bootstrapDownloadFailed(
        "Failed to download bootstrap binary from \(url)")
    }

    // Extract
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    tar.arguments = ["tar", "xzf", tarPath.path, "-C", tmpDir.path]
    try tar.run()
    tar.waitUntilExit()
    guard tar.terminationStatus == 0 else {
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

    FileHandle.standardError.write(
      Data(
        "agentc: bootstrap binary installed to \(destination.path)\n".utf8))
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
