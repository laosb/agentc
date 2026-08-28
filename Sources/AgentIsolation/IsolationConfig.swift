#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Determines how the container entrypoint is configured.
public enum BootstrapMode: Sendable {
  /// Mount a file (binary or script) as the container entrypoint.
  /// The agentc-bootstrap binary is the default; users can also supply
  /// a custom binary or shell script via ``--bootstrap``.
  case file(URL)

  /// Respect the container image's built-in entrypoint; do not mount a bootstrap.
  case imageDefault
}

/// Determines how host-backed mount destinations are represented in the container.
public enum MountPathScheme: String, Codable, Sendable {
  /// Mount host paths beneath `/workspace` using a stable, canonical-path identifier.
  case workspace

  /// Preserve the caller-visible absolute host path as the container destination.
  case host
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

  /// Controls how destinations are chosen for the workspace and additional host mounts.
  public var mountPathScheme: MountPathScheme

  /// Subfolder names within the workspace to mask with empty read-only mounts.
  /// Strips leading/trailing slashes. Multiple values allowed.
  public var excludeFolders: [String]

  /// Host directory containing agent configurations (cloned repo).
  /// Mounted read-only at /agent-isolation/agents in the container.
  public var configurationsDir: URL

  /// Ordered list of configuration names to activate.
  ///
  /// Each configuration's `dependsOn` entries are expanded before the session
  /// starts, so dependencies are activated first; see ``AgentConfigurationResolver``.
  public var configurations: [String]

  /// Controls how the container entrypoint is set up.
  public var bootstrapMode: BootstrapMode

  /// Host directory holding the agentc Toolkit, mounted read-only at
  /// `/agent-isolation/toolkit`.
  ///
  /// The bootstrap appends its `bin` to the end of `PATH`, so these tools are
  /// only reached for names the image does not provide itself. `nil` mounts
  /// nothing and leaves the container with exactly what its image ships.
  public var toolkitDir: URL?

  /// Arguments forwarded to the container entrypoint.
  public var arguments: [String]

  /// User-defined environment variables passed to the container.
  /// The `AGENTC_*` namespace is reserved for internal bootstrap controls; names in it
  /// are dropped when the session starts.
  public var environment: [String: String]

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

  /// When true, the session allocates a raw PTY whose bytes flow through
  /// ``AgentSession/rawOut`` and accept input via ``AgentSession/write(_:)``,
  /// with ``AgentSession/resize(cols:rows:)`` to adjust the terminal size.
  ///
  /// When false (the default), the session attaches to the current terminal
  /// or standard streams per ``allocateTTY``; in that mode ``AgentSession/rawOut``
  /// finishes immediately on ``AgentSession/start(entrypoint:timeout:)`` and
  /// ``AgentSession/write(_:)`` / ``AgentSession/resize(cols:rows:)`` throw.
  public var customPTY: Bool

  public init(
    image: String,
    profileHomeDir: URL,
    workspace: URL,
    mountPathScheme: MountPathScheme = .workspace,
    excludeFolders: [String] = [],
    configurationsDir: URL,
    configurations: [String] = ["claude"],
    bootstrapMode: BootstrapMode = .imageDefault,
    toolkitDir: URL? = nil,
    arguments: [String] = [],
    environment: [String: String] = [:],
    allocateTTY: Bool = false,
    cpuCount: Int = 1,
    memoryLimitMiB: Int = 1536,
    additionalHostMounts: [URL] = [],
    verbose: Bool = false,
    customPTY: Bool = false
  ) {
    self.image = image
    self.profileHomeDir = profileHomeDir
    self.workspace = workspace
    self.mountPathScheme = mountPathScheme
    self.excludeFolders = excludeFolders
    self.configurationsDir = configurationsDir
    self.configurations = configurations
    self.bootstrapMode = bootstrapMode
    self.toolkitDir = toolkitDir
    self.arguments = arguments
    self.environment = environment
    self.allocateTTY = allocateTTY
    self.cpuCount = cpuCount
    self.memoryLimitMiB = memoryLimitMiB
    self.additionalHostMounts = additionalHostMounts
    self.verbose = verbose
    self.customPTY = customPTY
  }
}
