import Foundation

/// Determines how the container entrypoint is configured.
public enum BootstrapMode: Sendable {
  /// Mount a file (binary or script) as the container entrypoint.
  /// The agentc-bootstrap binary is the default; users can also supply
  /// a custom binary or shell script via ``--bootstrap``.
  case file(URL)

  /// Respect the container image's built-in entrypoint; do not mount a bootstrap.
  case imageDefault
}

/// Configuration for running an isolated agent container session.
public struct IsolationConfig: Sendable {
  /// Container image reference (e.g. "ghcr.io/laosb/claudec:latest").
  public var image: String

  /// Host directory to mount as /home/agent inside the container.
  public var profileHomeDir: URL

  /// Host workspace directory to mount inside the container.
  /// Mounted at /workspace/<folderName>-<last10 of sha256(canonicalPath)>.
  public var workspace: URL

  /// Subfolder names within the workspace to mask with empty read-only mounts.
  /// Strips leading/trailing slashes. Multiple values allowed.
  public var excludeFolders: [String]

  /// Host directory containing agent configurations (cloned repo).
  /// Mounted read-only at /agent-isolation/agents in the container.
  public var configurationsDir: URL

  /// Ordered list of configuration names to activate.
  public var configurations: [String]

  /// Controls how the container entrypoint is set up.
  public var bootstrapMode: BootstrapMode

  /// Arguments forwarded to the container entrypoint.
  public var arguments: [String]

  /// Whether to allocate a pseudo-TTY. Typically true when stdin is a terminal.
  public var allocateTTY: Bool

  /// Number of CPUs to allocate to the container.
  public var cpuCount: Int

  /// Memory limit for the container in mebibytes (MiB).
  public var memoryLimitMiB: Int

  /// Additional host directories to mount inside the container.
  /// Each is mounted at /workspace/<pathIdentifier(canonicalPath)>.
  public var additionalHostMounts: [URL]

  /// When true, passes `AGENTC_VERBOSE=1` to the container so that the bootstrap
  /// prints extra information (e.g. prepare.sh progress).
  public var verbose: Bool

  public init(
    image: String,
    profileHomeDir: URL,
    workspace: URL,
    excludeFolders: [String] = [],
    configurationsDir: URL,
    configurations: [String] = ["claude"],
    bootstrapMode: BootstrapMode = .imageDefault,
    arguments: [String] = [],
    allocateTTY: Bool = false,
    cpuCount: Int = 1,
    memoryLimitMiB: Int = 1536,
    additionalHostMounts: [URL] = [],
    verbose: Bool = false
  ) {
    self.image = image
    self.profileHomeDir = profileHomeDir
    self.workspace = workspace
    self.excludeFolders = excludeFolders
    self.configurationsDir = configurationsDir
    self.configurations = configurations
    self.bootstrapMode = bootstrapMode
    self.arguments = arguments
    self.allocateTTY = allocateTTY
    self.cpuCount = cpuCount
    self.memoryLimitMiB = memoryLimitMiB
    self.additionalHostMounts = additionalHostMounts
    self.verbose = verbose
  }
}
