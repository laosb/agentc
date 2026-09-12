import Synchronization

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Errors surfaced by ``AgentSession``.
public enum AgentSessionError: Error, Sendable, Equatable {
  /// ``AgentSession/write(_:)`` or ``AgentSession/resize(cols:rows:)`` was called
  /// on a session whose ``IsolationConfig/customPTY`` is `false`.
  case customPTYNotEnabled
  /// ``AgentSession/wait()``, ``AgentSession/resize(cols:rows:)``, or
  /// ``AgentSession/write(_:)`` was called before ``AgentSession/start(entrypoint:timeout:)``.
  case notStarted
  /// ``AgentSession/start(entrypoint:timeout:)`` was called more than once.
  case alreadyStarted
  /// A host-preserving mount would replace a destination owned by agentc.
  case unsafeMountDestination(String)
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
    /// Held for the container's whole lifetime and released only after teardown,
    /// so a repair can never start while this session is still using the profile.
    var profileLease: FileLock? = nil
    /// Kept so teardown can withdraw this session's registration.
    var ownershipCoordinator: ProfileOwnershipCoordinator? = nil
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
      // streams â close them up front so consumers see an immediate EOF.
      rawOutContinuation.finish()
      stdinContinuation.finish()
    }

    guard let coordinator = makeOwnershipCoordinator() else {
      // Legacy behavior: the bootstrap repairs profile ownership itself on every
      // start, and nothing waits for a message it cannot produce.
      let launched = try await launch(entrypoint: entrypointOverride, ownership: nil)
      commit(launched, lease: nil)
      return
    }

    try await startWithOwnershipHandshake(
      coordinator: coordinator, entrypoint: entrypointOverride)
  }

  // MARK: - Profile ownership

  /// The coordinator for this session, or `nil` when the ownership fast path does
  /// not apply.
  ///
  /// It applies only when the resolved bootstrap declares the handshake *and* the
  /// runtime's ownership mapping has been characterized. Either one missing keeps
  /// the old behavior: the bootstrap repairs ownership on every start, which is
  /// slower but makes no assumptions about a mapping nobody has measured.
  private func makeOwnershipCoordinator() -> ProfileOwnershipCoordinator? {
    guard config.bootstrapCapabilities.contains(.profileOwnershipHandshake) else { return nil }
    guard let mapping = runtime.profileOwnershipMapping else { return nil }
    guard mapping.isCharacterized || config.profileOwnershipFastPathOptIn else { return nil }
    return ProfileOwnershipCoordinator(
      profileDirectory: config.profileHomeDir.deletingLastPathComponent(),
      homeDirectory: config.profileHomeDir,
      mapping: mapping)
  }

  /// Launch, then settle profile ownership with the guest before anything runs.
  ///
  /// The guest reports the identity it actually resolved; only once the host has
  /// published a record and acknowledged does the guest run preparation scripts or
  /// the workload. A shared-mode mismatch costs one restart under an exclusive
  /// lease — a shared lock is never upgraded in place, because every other session
  /// holding it could be trying to do the same thing at the same moment.
  private func startWithOwnershipHandshake(
    coordinator: ProfileOwnershipCoordinator,
    entrypoint entrypointOverride: [String]?
  ) async throws {
    var mode = coordinator.plannedMode(forceRepair: config.repairProfileOwnership)
    var hasRepaired = mode == .repair
    if mode == .repair {
      // A crashed agentc releases its lease but may leave its container running
      // with this profile still mounted. Repairing underneath it would corrupt a
      // live session.
      try coordinator.assertNoSurvivingSessions(
        liveContainerIDs: await runtime.liveContainerIDs())
    }
    var lease = try coordinator.acquireLease(for: mode)

    while true {
      let launched: Launched
      do {
        launched = try await launch(
          entrypoint: entrypointOverride, ownership: (coordinator, mode))
      } catch {
        lease.release()
        throw error
      }

      guard let controlDirectory = launched.controlDirectory else {
        // Nothing to wait for; behave as the legacy path rather than hanging.
        commit(launched, lease: lease, coordinator: coordinator)
        return
      }

      let report: ProfileOwnershipReport
      do {
        // The span covers the guest's whole ownership pass, since the report is
        // only written once that finishes.
        report = try await config.diagnostics.span(
          "profile.ownership", attributes: [.init("mode", mode.rawValue)]
        ) { context in
          let report = try await coordinator.awaitReport(controlDirectory: controlDirectory)
          context?.set("action", report.status.rawValue)
          context?.set("visited", report.visited)
          context?.set("changed", report.changed)
          return report
        }
      } catch {
        try? coordinator.acknowledge(controlDirectory: controlDirectory, decision: .abort)
        await discard(launched)
        lease.release()
        throw error
      }

      switch report.status {
      case .verified:
        try? coordinator.acknowledge(controlDirectory: controlDirectory, decision: .continue)
        commit(launched, lease: lease, coordinator: coordinator)
        return

      case .initialized, .repaired:
        // Publish only after a success, and only then release the guest.
        if let record = coordinator.makeRecord(from: report) {
          do {
            try coordinator.publish(record)
          } catch {
            try? coordinator.acknowledge(controlDirectory: controlDirectory, decision: .abort)
            await discard(launched)
            lease.release()
            throw error
          }
        }
        try? coordinator.convertToSharedLease(lease)
        try? coordinator.acknowledge(controlDirectory: controlDirectory, decision: .continue)
        commit(launched, lease: lease, coordinator: coordinator)
        return

      case .needsRepair:
        try? coordinator.acknowledge(controlDirectory: controlDirectory, decision: .abort)
        await discard(launched)
        lease.release()
        guard !hasRepaired else { throw ProfileOwnershipError.stillNeedsRepair }
        hasRepaired = true
        mode = .repair
        // The record described a state the guest does not see, so it is wrong.
        coordinator.discardRecord()
        try coordinator.assertNoSurvivingSessions(
          liveContainerIDs: await runtime.liveContainerIDs())
        lease = try coordinator.acquireLease(for: .repair)

      case .failed:
        try? coordinator.acknowledge(controlDirectory: controlDirectory, decision: .abort)
        await discard(launched)
        lease.release()
        throw ProfileOwnershipError.repairFailed(report.detail ?? "no detail reported")
      }
    }
  }

  /// Adopt a successful launch as this session's container.
  private func commit(
    _ launched: Launched,
    lease: FileLock?,
    coordinator: ProfileOwnershipCoordinator? = nil
  ) {
    // Recorded before the lease is ever released, so a crash cannot leave a live
    // container that nothing knows about.
    coordinator?.registerSession(containerID: launched.container.id)
    state.withLock { state in
      state.container = launched.container
      state.tempDirs = launched.tempDirs
      state.profileLease = lease
      state.ownershipCoordinator = coordinator
    }
  }

  /// Tear down a launch that will not become this session's container.
  private func discard(_ launched: Launched) async {
    try? await launched.container.stop()
    try? await runtime.removeContainer(launched.container)
    for dir in launched.tempDirs {
      try? FileManager.default.removeItem(at: dir)
    }
  }

  /// One container launch, before it is adopted or discarded.
  private struct Launched {
    var container: Runtime.Container
    var tempDirs: [URL]
    /// The host side of this session's control directory, when the ownership
    /// handshake is in play.
    var controlDirectory: URL?
  }

  // MARK: - Launch

  private func launch(
    entrypoint entrypointOverride: [String]?,
    ownership: (coordinator: ProfileOwnershipCoordinator, mode: ProfileOwnershipMode)?
  ) async throws -> Launched {
    // Expand `dependsOn` so dependencies are set up before the configurations
    // that require them, and the container sees the same list the host mounts for.
    // Resolved up front so a broken dependency graph fails before any runtime work.
    let configurations = try AgentConfigurationResolver.resolve(
      configurations: config.configurations,
      in: config.configurationsDir
    )

    let canonicalWorkspace = AgentIsolationPathUtils.resolveSymlinksWithPlatformConsiderations(
      config.workspace)
    let wsContainerPath = AgentIsolationPathUtils.containerMountPath(
      for: config.workspace,
      scheme: config.mountPathScheme)

    if config.mountPathScheme == .host {
      let hostDestinations =
        [wsContainerPath]
        + config.additionalHostMounts.map {
          AgentIsolationPathUtils.containerMountPath(for: $0, scheme: .host)
        }
      if let reserved = hostDestinations.first(where: {
        AgentIsolationPathUtils.isReservedHostMountDestination($0)
      }) {
        throw AgentSessionError.unsafeMountDestination(reserved)
      }
    }

    if let diagnostics = config.diagnostics {
      try await diagnostics.span("runtime.prepare") { _ in try await runtime.prepare() }
    } else {
      try await runtime.prepare()
    }

    try FileManager.default.createDirectory(
      at: config.profileHomeDir,
      withIntermediateDirectories: true
    )

    // Build mounts list
    var mounts: [ContainerConfiguration.Mount] = []
    var tempDirs: [URL] = []

    // Profile home â /home/agent
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

    // Configurations directory â /agent-isolation/agents (read-only)
    mounts.append(
      .init(
        hostPath: config.configurationsDir.path,
        containerPath: "/agent-isolation/agents",
        isReadOnly: true
      ))

    // Additional mounts from agent configurations
    let additionalMountsDir = config.profileHomeDir.deletingLastPathComponent()
      .appendingPathComponent("additionalMounts")
    for configName in configurations {
      guard
        let settings = AgentConfigurationSettings.load(
          name: configName, in: config.configurationsDir)
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
      let containerPath = AgentIsolationPathUtils.containerMountPath(
        for: hostMount,
        scheme: config.mountPathScheme)
      mounts.append(
        .init(
          hostPath: canonical.path,
          containerPath: containerPath
        ))
    }

    // agentc Toolkit → /agent-isolation/toolkit (read-only). The bootstrap puts
    // its bin directory at the very end of PATH, so these tools fill gaps in the
    // image without ever shadowing what the image itself provides.
    if let toolkitDir = config.toolkitDir {
      mounts.append(
        .init(
          hostPath: AgentIsolationPathUtils.resolveSymlinksWithPlatformConsiderations(toolkitDir)
            .path,
          containerPath: "/agent-isolation/toolkit",
          isReadOnly: true
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

    // Per-session control directory for the profile-ownership handshake. It is
    // private to this session and carries only this session's expected ownership
    // data — never the host state directory, and never its lock.
    var controlDirectory: URL?
    if ownership != nil {
      let dir = try makeTempDir()
      tempDirs.append(dir)
      controlDirectory = dir
      mounts.append(
        .init(
          hostPath: AgentIsolationPathUtils.resolveSymlinksWithPlatformConsiderations(dir).path,
          containerPath: ProfileOwnershipProtocol.controlMountPath
        ))
    }

    // Environment: start with user values, excluding reserved bootstrap controls.
    var environment = config.environment.filter { !$0.key.hasPrefix("AGENTC_") }
    environment["AGENTC_CONFIGURATIONS"] = configurations.joined(separator: ",")
    if config.verbose {
      environment["AGENTC_VERBOSE"] = "1"
    }
    if let ownership {
      for (key, value) in ownership.coordinator.guestEnvironment(mode: ownership.mode) {
        environment[key] = value
      }
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
      stdioObserver: config.stdioObserver,
      cpuCount: config.cpuCount,
      memoryLimitMiB: config.memoryLimitMiB
    )

    do {
      let container: Runtime.Container
      if let diagnostics = config.diagnostics {
        container = try await diagnostics.span(
          "session.run_container",
          attributes: [.init("mounts", String(mounts.count))]
        ) { _ in
          try await runtime.runContainer(imageRef: config.image, configuration: containerConfig)
        }
      } else {
        container = try await runtime.runContainer(
          imageRef: config.image,
          configuration: containerConfig
        )
      }
      return Launched(
        container: container, tempDirs: tempDirs, controlDirectory: controlDirectory)
    } catch {
      // Container never came up â purge temp dirs eagerly and finish streams.
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
    // Past this line the run has an answer, and teardown cannot take it back.
    //
    // The workload's exit code is already in hand, which means its init has
    // exited and the guest is halting of its own accord. A `stop()` that arrives
    // after the halt finishes reports "the virtual machine stopped unexpectedly"
    // about a machine that stopped exactly as expected — and letting that decide
    // the run would replace the container's own exit code with a failure, for a
    // container that ran correctly and whose output the user has already seen.
    // Whether the stop landed before or after that point is a matter of host
    // load, so propagating it makes an unrelated success fail at random.
    try? await container.stop()
    await cleanup(container: container)
    return exitCode
  }

  // MARK: - Helpers

  private func cleanup(container: Runtime.Container) async {
    // Signal consumers that no further IO will arrive.
    rawOutContinuation.finish()
    stdinContinuation.finish()

    try? await runtime.removeContainer(container)

    let (dirs, lease, coordinator) = state.withLock {
      state -> ([URL], FileLock?, ProfileOwnershipCoordinator?) in
      let result = (state.tempDirs, state.profileLease, state.ownershipCoordinator)
      state.tempDirs = []
      state.container = nil
      state.profileLease = nil
      state.ownershipCoordinator = nil
      return result
    }
    for dir in dirs {
      try? FileManager.default.removeItem(at: dir)
    }
    // Only now, with the container gone, may another session repair this profile.
    coordinator?.unregisterSession(containerID: container.id)
    lease?.release()
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
