import Synchronization

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Settings from an agent configuration's settings.json.
private struct AgentConfigurationSettings: Decodable {
  var additionalMounts: [String]?
}

/// Errors surfaced by ``AgentSession``.
public enum AgentSessionError: Error, Sendable {
  /// ``AgentSession/write(_:)`` or ``AgentSession/resize(cols:rows:)`` was called
  /// on a session whose ``IsolationConfig/customPTY`` is `false`.
  case customPTYNotEnabled
  /// ``AgentSession/wait()``, ``AgentSession/resize(cols:rows:)``, or
  /// ``AgentSession/write(_:)`` was called before ``AgentSession/start(entrypoint:timeout:)``.
  case notStarted
  /// ``AgentSession/start(entrypoint:timeout:)`` was called more than once.
  case alreadyStarted
}

/// Orchestrates running an isolated agent container session using a ``ContainerRuntime``.
///
/// `AgentSession` is responsible for:
/// - Preparing the runtime
/// - Computing workspace paths and directory layout
/// - Building container mounts (profile home, workspace, exclude overlays, configurations, additional mounts)
/// - Configuring and running the container
/// - Performing necessary cleanups (temp dirs)
///
/// The session is object-oriented: construct once with ``init(config:runtime:)``,
/// launch with ``start(entrypoint:timeout:)``, then drive I/O via ``rawOut``,
/// ``write(_:)``, ``resize(cols:rows:)``, and ``wait()``.
///
/// When ``IsolationConfig/customPTY`` is `false` (the default), the container
/// attaches to the current terminal (or standard streams) just like before;
/// ``rawOut`` finishes immediately on ``start(entrypoint:timeout:)`` and
/// ``write(_:)``/``resize(cols:rows:)`` throw
/// ``AgentSessionError/customPTYNotEnabled``.
public final class AgentSession<Runtime: ContainerRuntime>: Sendable {
  public let config: IsolationConfig
  public let runtime: Runtime

  private let stdinStream: AsyncStream<Data>
  private let stdinContinuation: AsyncStream<Data>.Continuation
  private let rawOutStream: AsyncStream<[UInt8]>
  private let rawOutContinuation: AsyncStream<[UInt8]>.Continuation

  private struct State: ~Copyable {
    var container: Runtime.Container? = nil
    var tempDirs: [URL] = []
    var timeoutInSeconds: Int64? = nil
    var hasStarted: Bool = false
    var waited: Bool = false
  }
  private let state = Mutex(State())

  public init(config: IsolationConfig, runtime: Runtime) {
    self.config = config
    self.runtime = runtime
    (self.stdinStream, self.stdinContinuation) = AsyncStream<Data>.makeStream(
      bufferingPolicy: .unbounded)
    (self.rawOutStream, self.rawOutContinuation) = AsyncStream<[UInt8]>.makeStream(
      bufferingPolicy: .unbounded)
  }

  /// A sequence of raw bytes produced by the container's PTY.
  ///
  /// When ``IsolationConfig/customPTY`` is `false`, iteration ends as soon as
  /// ``start(entrypoint:timeout:)`` completes. Otherwise, bytes stream in as
  /// the container writes to its terminal and the sequence finishes when the
  /// container's output closes.
  public var rawOut: some AsyncSequence<[UInt8], Never> {
    rawOutStream
  }

  /// Start the agent session.
  ///
  /// Prepares the runtime, resolves mounts, creates the container, and starts
  /// it. I/O routing depends on ``IsolationConfig/customPTY``:
  /// - `false`: attaches to the current terminal (when ``IsolationConfig/allocateTTY``
  ///   is `true`) or to the parent process's stdio.
  /// - `true`: allocates a custom PTY wired up to ``rawOut`` /
  ///   ``write(_:)`` / ``resize(cols:rows:)``.
  ///
  /// - Parameters:
  ///   - entrypointOverride: Optional entrypoint override. When non-nil, the
  ///     bootstrap executes this instead of the last configuration's entrypoint
  ///     (e.g. `["/bin/bash"]` for an interactive shell).
  ///   - timeout: Optional timeout (seconds) forwarded to ``wait()``.
  public func start(
    entrypoint entrypointOverride: [String]? = nil,
    timeout: Int64? = nil
  ) async throws {
    try state.withLock { state in
      guard !state.hasStarted else { throw AgentSessionError.alreadyStarted }
      state.hasStarted = true
      state.timeoutInSeconds = timeout
    }

    if !config.customPTY {
      // In non-custom mode, nothing will ever be fed through the rawOut/stdin
      // streams — close them up front so consumers see an immediate EOF.
      rawOutContinuation.finish()
      stdinContinuation.finish()
    }

    try await runtime.prepare()

    let canonicalWorkspace = AgentIsolationPathUtils.resolveSymlinksWithPlatformConsiderations(
      config.workspace)
    let wsContainerPath = AgentIsolationPathUtils.workspaceContainerPath(for: config.workspace)

    try FileManager.default.createDirectory(
      at: config.profileHomeDir,
      withIntermediateDirectories: true
    )

    // Build mounts list
    var mounts: [ContainerConfiguration.Mount] = []
    var tempDirs: [URL] = []

    // Profile home → /home/agent
    mounts.append(
      .init(
        hostPath: config.profileHomeDir.path,
        containerPath: "/home/agent"
      ))

    // Workspace
    mounts.append(
      .init(
        hostPath: canonicalWorkspace.path,
        containerPath: wsContainerPath
      ))

    // Excluded folders: each gets an empty temp dir mounted as a read-only overlay
    for rawFolder in config.excludeFolders {
      let folder = rawFolder.trimmingCharacters(in: .init(charactersIn: "/"))
      guard !folder.isEmpty else { continue }
      let tempDir = try makeTempDir()
      tempDirs.append(tempDir)
      mounts.append(
        .init(
          hostPath: AgentIsolationPathUtils.resolveSymlinksWithPlatformConsiderations(tempDir).path,
          containerPath: "\(wsContainerPath)/\(folder)",
          isReadOnly: true
        ))
    }

    // Configurations directory → /agent-isolation/agents (read-only)
    mounts.append(
      .init(
        hostPath: config.configurationsDir.path,
        containerPath: "/agent-isolation/agents",
        isReadOnly: true
      ))

    // Additional mounts from agent configurations
    let additionalMountsDir = config.profileHomeDir.deletingLastPathComponent()
      .appendingPathComponent("additionalMounts")
    for configName in config.configurations {
      let settingsURL = config.configurationsDir
        .appendingPathComponent(configName)
        .appendingPathComponent("settings.json")
      guard let data = try? Data(contentsOf: settingsURL) else { continue }
      guard let settings = try? JSONDecoder().decode(AgentConfigurationSettings.self, from: data)
      else { continue }
      for containerPath in settings.additionalMounts ?? [] {
        guard !containerPath.isEmpty else { continue }
        let segment = AgentIsolationPathUtils.pathIdentifier(for: containerPath)
        let hostDir = additionalMountsDir.appendingPathComponent(segment)
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
        mounts.append(
          .init(
            hostPath: hostDir.path,
            containerPath: containerPath
          ))
      }
    }

    // Additional host mounts (from CLI --additional-mount flags)
    for hostMount in config.additionalHostMounts {
      let canonical = AgentIsolationPathUtils.resolveSymlinksWithPlatformConsiderations(hostMount)
      let containerPath =
        "/workspace/\(AgentIsolationPathUtils.pathIdentifier(for: canonical.path))"
      mounts.append(
        .init(
          hostPath: canonical.path,
          containerPath: containerPath
        ))
    }

    // Bootstrap file: copy to a temp dir and mount so it can be shared as a virtiofs volume.
    var overridesEntrypoint = false
    switch config.bootstrapMode {
    case .file(let bootstrapFile):
      let tempDir = try makeTempDir()
      tempDirs.append(tempDir)
      let dest = tempDir.appendingPathComponent("bootstrap")
      try FileManager.default.copyItem(at: bootstrapFile, to: dest)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: dest.path
      )
      mounts.append(
        .init(
          hostPath: AgentIsolationPathUtils.resolveSymlinksWithPlatformConsiderations(tempDir).path,
          containerPath: "/entrypoint-bootstrap"
        ))
      overridesEntrypoint = true

    case .imageDefault:
      break
    }

    // Environment: pass configurations and optional entrypoint override to bootstrap
    var environment: [String: String] = [:]
    environment["AGENTC_CONFIGURATIONS"] = config.configurations.joined(separator: ",")
    if config.verbose {
      environment["AGENTC_VERBOSE"] = "1"
    }

    // When an entrypoint override is provided (e.g. "sh" dispatch), the override
    // args replace config.arguments as the container CMD, and a flag tells the
    // bootstrap to exec them directly instead of running the configuration entrypoint.
    var containerArgs = config.arguments
    if let override = entrypointOverride {
      containerArgs = override
      environment["AGENTC_ENTRYPOINT_OVERRIDE"] = "1"
    }

    // Build the final entrypoint (CMD args to the image's or custom ENTRYPOINT)
    let entrypoint: [String]
    if overridesEntrypoint {
      entrypoint = ["/entrypoint-bootstrap/bootstrap"] + containerArgs
    } else {
      entrypoint = containerArgs
    }

    let io: ContainerConfiguration.IO
    if config.customPTY {
      io = .custom(
        stdin: AgentSessionStdinReader(inner: stdinStream),
        stdout: AgentSessionRawOutWriter(continuation: rawOutContinuation),
        stderr: AgentSessionNullWriter(),
        isTerminal: true
      )
    } else {
      io = config.allocateTTY ? .currentTerminal : .standardIO
    }

    let containerConfig = ContainerConfiguration(
      entrypoint: entrypoint,
      overridesImageEntrypoint: overridesEntrypoint,
      workingDirectory: wsContainerPath,
      environment: environment,
      mounts: mounts,
      io: io,
      cpuCount: config.cpuCount,
      memoryLimitMiB: config.memoryLimitMiB
    )

    do {
      let container = try await runtime.runContainer(
        imageRef: config.image,
        configuration: containerConfig
      )
      state.withLock { state in
        state.container = container
        state.tempDirs = tempDirs
      }
    } catch {
      // Container never came up — purge temp dirs eagerly and finish streams.
      for dir in tempDirs {
        try? FileManager.default.removeItem(at: dir)
      }
      rawOutContinuation.finish()
      stdinContinuation.finish()
      throw error
    }
  }

  /// Push bytes into the container's PTY input.
  ///
  /// Throws ``AgentSessionError/customPTYNotEnabled`` when ``IsolationConfig/customPTY``
  /// is `false`, or ``AgentSessionError/notStarted`` if called before
  /// ``start(entrypoint:timeout:)``.
  public func write(_ data: Data) throws {
    guard config.customPTY else { throw AgentSessionError.customPTYNotEnabled }
    let started = state.withLock { $0.hasStarted }
    guard started else { throw AgentSessionError.notStarted }
    stdinContinuation.yield(data)
  }

  /// Resize the container's PTY.
  ///
  /// Throws ``AgentSessionError/customPTYNotEnabled`` when ``IsolationConfig/customPTY``
  /// is `false`, or ``AgentSessionError/notStarted`` if called before
  /// ``start(entrypoint:timeout:)``.
  public func resize(cols: Int, rows: Int) async throws {
    guard config.customPTY else { throw AgentSessionError.customPTYNotEnabled }
    let container = state.withLock { $0.container }
    guard let container else { throw AgentSessionError.notStarted }
    try await container.resize(cols: cols, rows: rows)
  }

  /// Wait for the container to exit, then clean up temporary resources and
  /// return the exit code.
  public func wait() async throws -> Int32 {
    let (container, timeout, alreadyWaited) = state.withLock {
      state -> (Runtime.Container?, Int64?, Bool) in
      let result = (state.container, state.timeoutInSeconds, state.waited)
      state.waited = true
      return result
    }
    guard !alreadyWaited else {
      // Idempotent: a second wait just throws `notStarted` if nothing is live.
      throw AgentSessionError.notStarted
    }
    guard let container else {
      throw AgentSessionError.notStarted
    }

    let exitCode: Int32
    do {
      exitCode = try await container.wait(timeoutInSeconds: timeout)
    } catch {
      await cleanup(container: container)
      throw error
    }
    try await container.stop()
    await cleanup(container: container)
    return exitCode
  }

  // MARK: - Helpers

  private func cleanup(container: Runtime.Container) async {
    // Signal consumers that no further IO will arrive.
    rawOutContinuation.finish()
    stdinContinuation.finish()

    try? await runtime.removeContainer(container)

    let dirs = state.withLock { state -> [URL] in
      let d = state.tempDirs
      state.tempDirs = []
      state.container = nil
      return d
    }
    for dir in dirs {
      try? FileManager.default.removeItem(at: dir)
    }
  }

  private func makeTempDir() throws -> URL {
    let dir = URL(fileURLWithPath: "/tmp/agentc-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}

// MARK: - Custom IO plumbing

/// Adapts ``AgentSession``'s internal stdin stream to the runtime's
/// ``ReaderStream`` protocol. `stream()` must only be called once.
private struct AgentSessionStdinReader: ReaderStream {
  let inner: AsyncStream<Data>

  func stream() -> AsyncStream<Data> {
    inner
  }
}

/// A ``Writer`` that pushes bytes into an ``AsyncStream`` continuation so
/// they surface via ``AgentSession/rawOut``.
private struct AgentSessionRawOutWriter: Writer {
  let continuation: AsyncStream<[UInt8]>.Continuation

  func write(_ data: Data) throws {
    continuation.yield(Array(data))
  }

  func close() throws {
    continuation.finish()
  }
}

/// A ``Writer`` that discards everything. Used for the stderr slot in raw-PTY
/// mode, where a terminal merges stderr into stdout anyway.
private struct AgentSessionNullWriter: Writer {
  func write(_ data: Data) throws {}
  func close() throws {}
}
