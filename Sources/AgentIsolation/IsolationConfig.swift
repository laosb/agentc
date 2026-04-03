import Foundation

/// Configuration for running an isolated agent container session.
public struct IsolationConfig: Sendable {
  /// Container image reference (e.g. "ghcr.io/laosb/claudec:latest").
  public var image: String

  /// Host directory to mount as /home/claude inside the container.
  public var profileHomeDir: URL

  /// Host workspace directory to mount inside the container.
  /// Mounted at /workspace/<sha256(canonicalPath)>.
  public var workspace: URL

  /// Subfolder names within the workspace to mask with empty read-only mounts.
  /// Strips leading/trailing slashes. Multiple values allowed.
  public var excludeFolders: [String]

  /// Optional path to a custom bootstrap/entrypoint script on the host.
  /// When set, the script is mounted into the container and used as the entrypoint,
  /// overriding the image's default entrypoint.
  public var bootstrapScript: URL?

  /// Arguments forwarded to the container entrypoint.
  public var arguments: [String]

  /// Whether to allocate a pseudo-TTY. Typically true when stdin is a terminal.
  public var allocateTTY: Bool

  /// Memory limit string understood by the container runtime (e.g. "1536m" = 1.5 GiB).
  public var memoryLimit: String

  public init(
    image: String,
    profileHomeDir: URL,
    workspace: URL,
    excludeFolders: [String] = [],
    bootstrapScript: URL? = nil,
    arguments: [String] = [],
    allocateTTY: Bool = false,
    memoryLimit: String = "1536m"
  ) {
    self.image = image
    self.profileHomeDir = profileHomeDir
    self.workspace = workspace
    self.excludeFolders = excludeFolders
    self.bootstrapScript = bootstrapScript
    self.arguments = arguments
    self.allocateTTY = allocateTTY
    self.memoryLimit = memoryLimit
  }
}
