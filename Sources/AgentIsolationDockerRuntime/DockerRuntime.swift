import AgentIsolation
import Foundation
import Logging
import Synchronization

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

  public required init(config: ContainerRuntimeConfiguration) {
    self.endpoint = config.endpoint ?? "/var/run/docker.sock"
    self.client = DockerAPIClient(endpoint: self.endpoint)
  }

  // MARK: - ContainerRuntime

  public func prepare() async throws {
    try await client.ping()
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

  public func runContainer(
    imageRef: String,
    configuration: ContainerConfiguration
  ) async throws -> DockerContainer {
    let useTTY: Bool
    switch configuration.io {
    case .currentTerminal: useTTY = true
    case .custom(_, _, _, let isTerminal): useTTY = isTerminal
    default: useTTY = false
    }

    // Build bind mounts
    var binds: [String] = []
    for mount in configuration.mounts {
      let opts = mount.isReadOnly ? "ro" : "rw"
      binds.append("\(mount.hostPath):\(mount.containerPath):\(opts)")
    }

    // Build environment
    let envVars: [String]? =
      configuration.environment.isEmpty
      ? nil
      : configuration.environment.map { "\($0.key)=\($0.value)" }

    // Create container – when a custom entrypoint override is requested, set Docker's
    // Entrypoint field to replace the image's built-in ENTRYPOINT. Otherwise, use Cmd
    // so the image's ENTRYPOINT receives these as arguments.
    let entryArgs = configuration.entrypoint.isEmpty ? nil : configuration.entrypoint
    let createConfig = DockerCreateContainerRequest(
      Image: imageRef,
      Entrypoint: configuration.overridesImageEntrypoint ? entryArgs : nil,
      Cmd: configuration.overridesImageEntrypoint ? nil : entryArgs,
      Env: envVars,
      WorkingDir: configuration.workingDirectory,
      Tty: useTTY,
      OpenStdin: true,
      AttachStdin: true,
      AttachStdout: true,
      AttachStderr: true,
      HostConfig: DockerHostConfig(
        Binds: binds.isEmpty ? nil : binds,
        Memory: Int64(configuration.memoryLimitMiB) * 1024 * 1024,
        NanoCpus: Int64(configuration.cpuCount) * 1_000_000_000,
        Init: true
      )
    )

    let containerId = try await client.createContainer(config: createConfig)

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
      await conn.waitForReadCompletion()
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
    }
  }
}
