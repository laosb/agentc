import AgentIsolation
import Logging
import Synchronization

#if canImport(FoundationEssentials)
  import FoundationEssentials
  import Dispatch
#else
  import Foundation
#endif

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

// MARK: - DockerRuntime

/// Container runtime that communicates with Docker Engine via its HTTP API (v1.44).
///
/// Supports Unix domain socket (default: `/var/run/docker.sock`) and TCP connections.
/// Configure the endpoint using `ContainerRuntimeConfiguration.endpoint`.
public final class DockerRuntime: ContainerRuntime, Sendable {
  public typealias Image = DockerImage
  public typealias Container = DockerContainer

  private let client: DockerAPIClient
  private let endpoint: String
  private let logger = Logger(label: "com.agentc.docker-runtime")

  /// An explicit runtime alias from configuration. Honored verbatim, never validated.
  private let configuredRuntime: String?
  private let warningHandler: (@Sendable (String) -> Void)?
  /// Resolved once and reused, so the warning is shown at most once per runtime.
  private let selection = Mutex<DockerRuntimeSelection?>(nil)

  public required init(config: ContainerRuntimeConfiguration) {
    self.endpoint = config.endpoint ?? Self.autoDetectEndpoint()
    self.client = DockerAPIClient(endpoint: self.endpoint)
    self.configuredRuntime = config.ociRuntime
    self.warningHandler = config.warningHandler
  }

  /// Auto-detect the Docker socket path by checking common locations.
  ///
  /// Search order:
  /// 1. `DOCKER_HOST` environment variable
  /// 2. `$XDG_RUNTIME_DIR/docker.sock`
  /// 3. `/run/user/{uid}/docker.sock` (rootless Docker on Linux)
  /// 4. `~/.docker/run/docker.sock` (Docker Desktop on macOS)
  /// 5. `/var/run/docker.sock` (default)
  private static func autoDetectEndpoint() -> String {
    if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"], !host.isEmpty {
      return host
    }

    if let xdgDir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !xdgDir.isEmpty {
      let path = "\(xdgDir)/docker.sock"
      if FileManager.default.fileExists(atPath: path) {
        return path
      }
    }

    let uid = getuid()
    let userSocket = "/run/user/\(uid)/docker.sock"
    if FileManager.default.fileExists(atPath: userSocket) {
      return userSocket
    }

    let homeDockerSocket =
      FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".docker/run/docker.sock").path
    if FileManager.default.fileExists(atPath: homeDockerSocket) {
      return homeDockerSocket
    }

    return "/var/run/docker.sock"
  }

  // MARK: - ContainerRuntime

  public func prepare() async throws {
    try await client.ping()
    await resolveRuntimeSelection()
  }

  // MARK: - Runtime selection

  /// The runtime this instance runs containers with, resolved on first use.
  ///
  /// Kata is preferred over gVisor over `runc`; see ``DockerRuntimeSelection/select(configured:info:)``.
  public func selectedRuntime() async -> DockerRuntimeSelection {
    await resolveRuntimeSelection()
  }

  @discardableResult
  private func resolveRuntimeSelection() async -> DockerRuntimeSelection {
    if let cached = selection.withLock({ $0 }) { return cached }

    // An explicit configuration is taken at face value, so there is nothing to discover.
    // It may well name a containerd shim the daemon never registered.
    var info: DockerInfo?
    if configuredRuntime == nil {
      do {
        info = try await client.info()
      } catch {
        // Discovery is advisory: a daemon that won't describe itself still runs containers.
        logger.debug("Failed to read Docker daemon info: \(error)")
      }
    }

    let resolved = DockerRuntimeSelection.select(configured: configuredRuntime, info: info)
    let isFirstResolution = selection.withLock { stored -> Bool in
      guard stored == nil else { return false }
      stored = resolved
      return true
    }

    guard isFirstResolution else { return selection.withLock { $0 } ?? resolved }

    if let warning = resolved.warning {
      if let warningHandler {
        warningHandler(warning)
      } else {
        logger.warning("\(warning)")
      }
    }
    return resolved
  }

  /// Shut down the HTTP client. Call when the runtime is no longer needed.
  public func shutdown() async throws {
    try await client.shutdown()
  }

  /// Platform string for the current host architecture in `os/arch` format
  /// as expected by Docker Engine API v1.44.
  static let currentPlatform: String = {
    #if arch(arm64)
      return "linux/arm64"
    #elseif arch(x86_64)
      return "linux/amd64"
    #else
      return ""
    #endif
  }()

  public func pullImage(ref: String) async throws -> DockerImage? {
    let platform = Self.currentPlatform.isEmpty ? nil : Self.currentPlatform
    do {
      try await client.pullImage(ref: ref, platform: platform)
    } catch {
      logger.error("Failed to pull image \(ref): \(error)")
      return nil
    }
    return try await inspectImage(ref: ref)
  }

  public func inspectImage(ref: String) async throws -> DockerImage? {
    guard let inspect = try await client.inspectImage(ref: ref) else {
      return nil
    }
    return DockerImage(
      ref: ref,
      digest: inspect.RepoDigests?.first ?? inspect.Id
    )
  }

  public func removeImage(ref: String) async throws {
    try await client.removeImage(nameOrDigest: ref)
  }

  public func removeImage(digest: String) async throws {
    try await client.removeImage(nameOrDigest: digest)
  }

  /// Whether the container should be created with a pseudo-TTY.
  static func usesTTY(for io: ContainerConfiguration.IO) -> Bool {
    switch io {
    case .currentTerminal: return true
    case .custom(_, _, _, let isTerminal): return isTerminal
    default: return false
    }
  }

  /// Build the Docker Engine create-container payload for a configuration.
  ///
  /// Pure translation of ``ContainerConfiguration`` to Docker's wire format, kept separate
  /// from ``runContainer(imageRef:configuration:)`` so it can be tested without a daemon.
  ///
  /// `Env` is left `nil` when no variables are set, so the image's own `ENV` is untouched.
  /// Otherwise the daemon merges these entries over the image's by name, which is why we
  /// pass them through as-is rather than reconciling anything here.
  ///
  /// `runtimeName` is the only isolation-relevant field we set; a `nil` leaves
  /// `HostConfig.Runtime` out of the payload so the daemon applies its own default.
  static func makeCreateRequest(
    imageRef: String,
    configuration: ContainerConfiguration,
    runtimeName: String? = nil
  ) -> DockerCreateContainerRequest {
    // Build bind mounts
    var binds: [String] = []
    for mount in configuration.mounts {
      let opts = mount.isReadOnly ? "ro" : "rw"
      binds.append("\(mount.hostPath):\(mount.containerPath):\(opts)")
    }

    // Build environment. Sorted so the same configuration always produces the same
    // payload — `environment` is an unordered dictionary.
    let envVars: [String]? =
      configuration.environment.isEmpty
      ? nil
      : configuration.environment.keys.sorted().map { "\($0)=\(configuration.environment[$0]!)" }

    // When a custom entrypoint override is requested, set Docker's Entrypoint field to
    // replace the image's built-in ENTRYPOINT. Otherwise, use Cmd so the image's
    // ENTRYPOINT receives these as arguments.
    let entryArgs = configuration.entrypoint.isEmpty ? nil : configuration.entrypoint
    return DockerCreateContainerRequest(
      Image: imageRef,
      Entrypoint: configuration.overridesImageEntrypoint ? entryArgs : nil,
      Cmd: configuration.overridesImageEntrypoint ? nil : entryArgs,
      Env: envVars,
      WorkingDir: configuration.workingDirectory,
      Tty: Self.usesTTY(for: configuration.io),
      OpenStdin: true,
      AttachStdin: true,
      AttachStdout: true,
      AttachStderr: true,
      HostConfig: DockerHostConfig(
        Binds: binds.isEmpty ? nil : binds,
        Memory: Int64(configuration.memoryLimitMiB) * 1024 * 1024,
        NanoCpus: Int64(configuration.cpuCount) * 1_000_000_000,
        CpusetCpus: "0-\(configuration.cpuCount - 1)",
        Init: true,
        Runtime: runtimeName
      )
    )
  }

  public func runContainer(
    imageRef: String,
    configuration: ContainerConfiguration
  ) async throws -> DockerContainer {
    let useTTY = Self.usesTTY(for: configuration.io)

    let runtime = await resolveRuntimeSelection()
    let createConfig = Self.makeCreateRequest(
      imageRef: imageRef, configuration: configuration, runtimeName: runtime.name)

    let containerId: String
    do {
      containerId = try await client.createContainer(config: createConfig)
    } catch {
      // Never retry on the daemon's default: a misconfigured Kata/gVisor runtime would
      // otherwise silently drop the isolation boundary the user is relying on.
      throw Self.surfaceRuntimeFailure(error, runtime: runtime)
    }

    // Set up terminal for TTY mode — only when using the actual current terminal
    var terminalState: DockerTerminalState?
    if case .currentTerminal = configuration.io {
      terminalState = DockerTerminalState.setRaw()
    }

    // Attach to container for I/O (before starting, so we don't miss output)
    let attachConnection: DockerStreamAttach?
    do {
      let conn = try DockerStreamAttach.attach(
        endpoint: endpoint,
        containerId: containerId,
        tty: useTTY
      )

      switch configuration.io {
      case .currentTerminal, .standardIO:
        conn.startIO(stdin: .standardInput, stdout: .standardOutput, stderr: .standardError)
      case .custom(let stdin, let stdout, let stderr, _):
        conn.startCustomIO(stdin: stdin, stdout: stdout, stderr: stderr)
      }
      attachConnection = conn
    } catch {
      // If attach fails, clean up and rethrow
      terminalState?.restore()
      try? await client.removeContainer(id: containerId)
      throw error
    }

    // Start container
    do {
      try await client.startContainer(id: containerId)
    } catch {
      attachConnection?.stop()
      terminalState?.restore()
      try? await client.removeContainer(id: containerId)
      throw error
    }

    // Initial resize for TTY
    if useTTY, let size = dockerTerminalSize() {
      try? await client.resizeContainerTTY(
        id: containerId, width: size.width, height: size.height)
    }

    return DockerContainer(
      id: containerId,
      client: client,
      attachConnection: attachConnection,
      terminalState: terminalState,
      useTTY: useTTY
    )
  }

  /// Wrap a create failure that is attributable to the selected runtime, so the user sees
  /// *which* runtime the daemon rejected — and that nothing was retried without it —
  /// rather than a bare "failed to create container".
  ///
  /// Plain `runc` selections are left alone: there is no isolation decision to explain, and
  /// the underlying error stands on its own. So are failures the daemon blames on something
  /// else (a missing image, a bad mount), which would only be muddied by runtime talk.
  static func surfaceRuntimeFailure(
    _ error: any Error, runtime: DockerRuntimeSelection
  ) -> any Error {
    guard let name = runtime.name, runtime.kind != .standard,
      case DockerRuntimeError.apiError(_, let message) = error
    else {
      return error
    }
    // Docker's wording varies ("unknown or invalid runtime name", "failed to start shim"),
    // but a runtime rejection always names one of the two.
    let lowercased = message.lowercased()
    guard lowercased.contains("runtime") || lowercased.contains("shim") else {
      return error
    }
    return DockerRuntimeError.runtimeUnavailable(runtime: name, reason: message)
  }

  public func removeContainer(_ container: DockerContainer) async throws {
    container.terminalState?.restore()
    container.attachConnection?.stop()
    try await client.removeContainer(id: container.id)
  }
}

// MARK: - Associated Types

public struct DockerImage: ContainerRuntimeImage {
  public var ref: String
  public var digest: String

  public init(ref: String, digest: String) {
    self.ref = ref
    self.digest = digest
  }
}

public final class DockerContainer: ContainerRuntimeContainer, Sendable {
  public let id: String
  let client: DockerAPIClient
  let attachConnection: DockerStreamAttach?
  let terminalState: DockerTerminalState?
  let useTTY: Bool

  /// Wrapper to satisfy Mutex's Sendable overload for DispatchSource.
  private struct SigwinchState: @unchecked Sendable {
    var source: DispatchSourceSignal?
  }

  private let _sigwinchSource = Mutex(SigwinchState())

  init(
    id: String,
    client: DockerAPIClient,
    attachConnection: DockerStreamAttach?,
    terminalState: DockerTerminalState?,
    useTTY: Bool
  ) {
    self.id = id
    self.client = client
    self.attachConnection = attachConnection
    self.terminalState = terminalState
    self.useTTY = useTTY

    if useTTY {
      setupSIGWINCH()
    }
  }

  public func wait(timeoutInSeconds: Int64?) async throws -> Int32 {
    let statusCode = try await client.waitContainer(id: id)
    // Wait for the attach stream to finish reading all container output
    // before returning, so nothing is lost when the caller proceeds to stop.
    if let conn = attachConnection {
      // When AttachStdin=true + TTY=true, Docker may keep the attach socket
      // open after the container exits, waiting for the client to close its
      // write half. Do that now so Docker closes its side and we observe EOF.
      conn.closeStdinHalf()
      await withReadCompletionTimeout(conn: conn, seconds: 5)
    }
    return Int32(statusCode)
  }

  public func stop() async throws {
    _sigwinchSource.withLock { state in
      state.source?.cancel()
      state.source = nil
    }
    terminalState?.restore()
    attachConnection?.stop()
    try await client.stopContainer(id: id)
  }

  public func resize(cols: Int, rows: Int) async throws {
    try await client.resizeContainerTTY(id: id, width: cols, height: rows)
  }

  /// Wait for the attach read loop to complete, but give up after `seconds`
  /// if Docker never closes the socket. Returning early is safe: we only
  /// lose trailing bytes Docker never delivered.
  private func withReadCompletionTimeout(conn: DockerStreamAttach, seconds: Int) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await conn.waitForReadCompletion() }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
      }
      _ = await group.next()
      group.cancelAll()
    }
  }

  private func setupSIGWINCH() {
    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
      signal(SIGWINCH, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
      source.setEventHandler { [weak self] in
        guard let self = self, let size = dockerTerminalSize() else { return }
        Task {
          try? await self.client.resizeContainerTTY(
            id: self.id, width: size.width, height: size.height)
        }
      }
      source.resume()
      self._sigwinchSource.withLock { $0.source = source }
    #endif
  }
}

// MARK: - Errors

public enum DockerRuntimeError: LocalizedError {
  case dockerNotAccessible(String)
  case pullFailed(String)
  case imageNotFound(String)
  case apiError(Int, String)
  case attachFailed(String)
  case socketError(String)
  /// The daemon refused to create a container with the selected non-default runtime.
  case runtimeUnavailable(runtime: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .dockerNotAccessible(let msg):
      return "Docker is not accessible: \(msg)"
    case .pullFailed(let msg):
      return "Failed to pull image: \(msg)"
    case .imageNotFound(let ref):
      return "Image not found: \(ref)"
    case .apiError(let code, let msg):
      return "Docker API error (\(code)): \(msg)"
    case .attachFailed(let msg):
      return "Failed to attach to container: \(msg)"
    case .socketError(let msg):
      return "Socket error: \(msg)"
    case .runtimeUnavailable(let runtime, let reason):
      return """
        Docker refused to create a container with the `\(runtime)` runtime: \(reason)
        Falling back to the default runtime would remove the isolation boundary this \
        runtime was chosen for, so the container was not started. Fix the runtime on the \
        Docker host, or select a different one with `--docker-runtime <name>`.
        """
    }
  }
}
