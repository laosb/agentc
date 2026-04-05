import Crypto
import Foundation

/// Orchestrates running an isolated agent container session using a ``ContainerRuntime``.
///
/// `AgentSession` is responsible for:
/// - Preparing the runtime
/// - Computing workspace paths and directory layout
/// - Building container mounts (profile home, workspace, exclude overlays, bootstrap script)
/// - Migrating legacy workspace mappings when detected
/// - Configuring and running the container
/// - Performing necessary cleanups (temp dirs)
public struct AgentSession<Runtime: ContainerRuntime>: Sendable {
  public let config: IsolationConfig
  public let runtime: Runtime

  public init(config: IsolationConfig, runtime: Runtime) {
    self.config = config
    self.runtime = runtime
  }

  /// Run the agent session and return the container process exit code.
  public func run() async throws -> Int32 {
    try await runtime.prepare()

    let canonicalWorkspace = resolveSymlinksWithPrivate(config.workspace)
    let workspaceHash = sha256Hex(canonicalWorkspace.path)
    let folderName = canonicalWorkspace.lastPathComponent
    let hashSuffix = String(workspaceHash.suffix(10))

    let workspaceContainerPath = "/workspace/\(folderName)-\(hashSuffix)"
    let legacyContainerPath = "/workspace/\(workspaceHash)"

    try FileManager.default.createDirectory(
      at: config.profileHomeDir,
      withIntermediateDirectories: true
    )

    // Check for legacy workspace mapping and offer migration
    try WorkspaceMigration.migrateIfNeeded(
      profileHomeDir: config.profileHomeDir,
      legacyPath: legacyContainerPath,
      newPath: workspaceContainerPath
    )

    // Build mounts list
    var mounts: [ContainerConfiguration.Mount] = []

    // Profile home → /home/claude
    mounts.append(
      .init(
        hostPath: config.profileHomeDir.path,
        containerPath: "/home/claude"
      ))

    // Workspace
    mounts.append(
      .init(
        hostPath: canonicalWorkspace.path,
        containerPath: workspaceContainerPath
      ))

    // Excluded folders: each gets an empty temp dir mounted as a read-only overlay
    var tempDirs: [URL] = []
    defer {
      for dir in tempDirs {
        try? FileManager.default.removeItem(at: dir)
      }
    }

    for rawFolder in config.excludeFolders {
      let folder = rawFolder.trimmingCharacters(in: .init(charactersIn: "/"))
      guard !folder.isEmpty else { continue }
      let tempDir = try makeTempDir()
      tempDirs.append(tempDir)
      mounts.append(
        .init(
          hostPath: resolveSymlinksWithPrivate(tempDir).path,
          containerPath: "\(workspaceContainerPath)/\(folder)",
          isReadOnly: true
        ))
    }

    // Bootstrap script: copy to temp dir so it can be shared as a virtiofs volume
    var entrypoint = config.arguments
    if let bootstrapScript = config.bootstrapScript {
      let tempDir = try makeTempDir()
      tempDirs.append(tempDir)
      let dest = tempDir.appendingPathComponent("entrypoint.sh")
      try FileManager.default.copyItem(at: bootstrapScript, to: dest)

      let srcPerms =
        (try? FileManager.default.attributesOfItem(
          atPath: bootstrapScript.path
        )[.posixPermissions] as? Int) ?? 0o644
      try FileManager.default.setAttributes(
        [.posixPermissions: srcPerms | 0o111],
        ofItemAtPath: dest.path
      )

      mounts.append(
        .init(
          hostPath: resolveSymlinksWithPrivate(tempDir).path,
          containerPath: "/entrypoint-bootstrap"
        ))
      entrypoint = ["/entrypoint-bootstrap/entrypoint.sh"] + config.arguments
    }

    let io: ContainerConfiguration.IO =
      config.allocateTTY ? .currentTerminal : .standardIO

    let containerConfig = ContainerConfiguration(
      entrypoint: entrypoint,
      overridesImageEntrypoint: config.bootstrapScript != nil,
      workingDirectory: workspaceContainerPath,
      mounts: mounts,
      io: io
    )

    let container = try await runtime.runContainer(
      imageRef: config.image,
      configuration: containerConfig
    )
    defer { _runBlocking { try await runtime.removeContainer(container) } }

    let exitCode = try await container.wait(timeoutInSeconds: nil)
    try await container.stop()
    return exitCode
  }

  // MARK: - Helpers

  private func sha256Hex(_ string: String) -> String {
    let data = Data(string.utf8)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func makeTempDir() throws -> URL {
    let dir = URL(fileURLWithPath: "/tmp/claudec-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Resolve symlinks and handle macOS `/tmp`, `/var`, `/etc` → `/private/...` mapping.
  private func resolveSymlinksWithPrivate(_ url: URL) -> URL {
    let resolved = url.resolvingSymlinksInPath()
    #if os(macOS)
      let parts = resolved.pathComponents
      if parts.count > 1, parts.first == "/",
        ["tmp", "var", "etc"].contains(parts[1])
      {
        if let withPrivate = NSURL.fileURL(
          withPathComponents: ["/", "private"] + parts[1...]
        ) {
          return withPrivate
        }
      }
    #endif
    return resolved
  }
}

/// Fire-and-forget helper for calling async cleanup in a defer block.
private func _runBlocking(_ body: @escaping @Sendable () async throws -> Void) {
  // Best-effort cleanup — runs on a detached task since defer can't be async.
  Task { try? await body() }
}
