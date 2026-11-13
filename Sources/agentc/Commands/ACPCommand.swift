import AgentIsolation
import ArgumentParser
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

struct ACPCommand: AsyncParsableCommand, LoggedCommand {
  static let configuration = CommandConfiguration(
    commandName: "acp",
    abstract: "Proxy ACP over stdio with isolated, host-path-mounted workspaces",
    discussion: """
      Each session cwd selects its own .agentc/settings.json and container. Only
      that cwd and configured additional mounts are exposed as host directories.
      --workspace optionally restricts which cwd roots the client may select.
      Mounts are fixed for the life of each workspace backend. Opt in to
      --bridge-host-stdio-mcp to execute client-provided MCP commands on the host.
      Explicit hostBinaries mappings are separately authorized with --allow-host-binaries.
      """
  )

  @OptionGroup var options: SharedOptions
  @Flag(
    name: .customLong("bridge-host-stdio-mcp"), inversion: .prefixedNo,
    help: "Run client-provided stdio MCP commands on the host, outside container isolation.")
  var bridgeHostStdioMcp: Bool?

  @Argument(parsing: .remaining, help: "Arguments forwarded to the ACP agent.")
  var entrypointArguments: [String] = []
  var logging: LoggingOptions { options.logging }

  mutating func validate() throws {
    if let scheme = options.mountPathScheme, scheme != .host {
      throw ValidationError("agentc acp requires --mount-path-scheme host")
    }
    if options.repairProfileOwnership {
      throw ValidationError("Repair profile ownership separately before starting ACP")
    }
  }

  mutating func run() async throws {
    let log = try options.stdioLogFile.map { try StdioLog(path: $0) }
    defer { log?.finish() }
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("agentc-acp-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    // Private, and separate from `scratch`, which is mounted into a container.
    let limits = ACPLimits.standard
    let spool = try ACPSpool(limits: limits)
    defer { spool.remove() }
    // Every element is either a control event or holds a permit from its
    // stream's window, so the stream's contents are bounded although its type is not.
    let (events, continuation) = AsyncStream<ACPEvent>.makeStream()
    // Let EOF/signals take the same cleanup path, and turn broken stdout into a
    // write error rather than a SIGPIPE that strands the containers.
    let previousPipe = signal(SIGPIPE, SIG_IGN)
    let signals = [SIGINT, SIGTERM].map { number in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { continuation.yield(.eof) }
      source.resume()
      return source
    }
    defer {
      for source in signals { source.cancel() }
      signal(SIGINT, SIG_DFL)
      signal(SIGTERM, SIG_DFL)
      signal(SIGPIPE, previousPipe)
    }
    let baseOptions = options
    let arguments = entrypointArguments
    let bridgeOverride = bridgeHostStdioMcp
    var hostBridge: HostStdioMCPBridge?
    var tasks: [Task<Void, Never>] = []
    var generations: [String: UUID] = [:]
    let writer = ACPClientWriter(
      descriptor: STDOUT_FILENO, chunkBytes: limits.chunkBytes, observe: log?.observer.stdout,
      failed: { continuation.yield(.failed($0)) })
    let proxy = ACPProxy(
      options: options, limits: limits, spool: spool,
      launch: { id, workspace in
        let generation = UUID()
        generations[id] = generation
        var options = baseOptions
        options.mountPathScheme = .host
        options.workspace = workspace?.cwd.path ?? scratch.path
        options.stdioLogFile = nil  // Log only the client-visible stream, once.
        var settings = workspace?.settings
        if workspace == nil {
          // Discover real capabilities without exposing the launcher cwd. CLI/profile
          // agent selection applies until an ACP client supplies a project.
          options.additionalMount = []
        } else {
          options.additionalMount = workspace!.additionalMounts.map(\.path)
          settings?.agent?.additionalMounts = nil
        }
        let stdin = ACPOutboundQueue()
        let gate = ACPGate(limits: limits)
        let stdout = ACPBackendOutput(
          ingress: ACPIngress(limits: limits, spool: spool, gate: gate)
        ) { continuation.yield(.backend(id, generation, $0)) }
        let input = stdin.stream(chunkBytes: limits.chunkBytes) {
          continuation.yield(.ended(id, generation, "ACP backend input failed: \($0)"))
        }
        let snapshot = ACPLaunchSnapshot(options: options, arguments: arguments, settings: settings)
        let bridgeEnabled =
          workspace != nil
          && (bridgeOverride ?? workspace?.settings?.agent?.acp?.bridgeHostStdioMcp ?? false)
        // Proxy networking has no general route to the host. Reserve just this
        // authenticated listener before the VM starts; all other guest TCP is
        // still handled by SOCKS5. Non-proxy backends keep lazy listener startup.
        let hostMCPPort: UInt16?
        if bridgeEnabled, try options.resolveSOCKS5Proxy(projectSettings: settings) != nil {
          if hostBridge == nil { hostBridge = try HostStdioMCPBridge() }
          hostMCPPort = hostBridge!.port
        } else {
          hostMCPPort = nil
        }
        let task = Task {
          do {
            let relay =
              bridgeEnabled
              ? try await BootstrapManager.resolveMCPRelay(
                options: snapshot.options, settings: snapshot.settings)
              : nil
            let code = try await SessionRunner.run(
              options: snapshot.options,
              configurationsPositional: snapshot.options.configurationsFlag,
              allocateTTY: false,
              arguments: snapshot.options.resolveArguments(
                entrypointArguments: snapshot.arguments, projectSettings: snapshot.settings),
              context: .init(
                projectSettings: snapshot.settings,
                io: .custom(
                  stdin: ACPInput(input: input),
                  stdout: stdout,
                  stderr: ACPOutput { FileHandle.standardError.write($0) }),
                mcpRelayBootstrap: relay,
                hostMCPPort: hostMCPPort))
            continuation.yield(.ended(id, generation, "ACP backend exited with status \(code)"))
          } catch {
            continuation.yield(.ended(id, generation, "ACP backend failed: \(error)"))
          }
        }
        tasks.append(task)
        let timeout = Task {
          do {
            try await Task.sleep(for: .seconds(120))
            continuation.yield(.timeout(id, generation))
          } catch {}
        }
        tasks.append(timeout)
        return ACPProxy.Transport(
          send: { stdin.push($0) },
          close: {
            // First wake a runtime output callback blocked on the window: it
            // may hold a runtime lock that stopping the session needs.
            gate.close()
            hostBridge?.stop(backend: id)
            stdin.finish()
            task.cancel()
            timeout.cancel()
          },
          prepareSession: { message in
            guard let workspace, bridgeEnabled
            else { return message }
            // Lazy: the default mode does not open a host listener.
            guard HostStdioMCPBridge.hasStdioServers(message) else { return message }
            if hostBridge == nil { hostBridge = try HostStdioMCPBridge() }
            return try hostBridge!.rewrite(message, backend: id, cwd: workspace.cwd)
          })
      },
      output: { writer.push($0) })
    let clientGate = ACPGate(limits: limits)
    let reader = ACPClientReader(
      descriptor: STDIN_FILENO,
      ingress: ACPIngress(limits: limits, spool: spool, gate: clientGate),
      chunkBytes: limits.chunkBytes, observe: log?.observer.stdin
    ) { inbound, problem in
      if let problem { logger.warning("\(problem)") }
      continuation.yield(inbound.map { .client($0) } ?? .eof)
    }
    var failure: (any Error)?
    do {
      eventLoop: for await event in events {
        switch event {
        case .client(let inbound):
          try proxy.receiveClient(inbound)
        case .backend(let id, let generation, let inbound):
          guard generations[id] == generation else { continue }
          try proxy.receiveBackend(id, inbound)
        case .ended(let id, let generation, let reason):
          guard generations[id] == generation else { continue }
          try proxy.backendEnded(id, reason: reason)
        case .timeout(let id, let generation):
          guard generations[id] == generation else { continue }
          try proxy.initializationTimedOut(id)
        case .failed(let reason): throw ACPError(reason)
        case .eof: break eventLoop
        }
      }
    } catch { failure = error }
    // Wake every blocked producer before anything waits for a session to stop.
    reader.stop()
    clientGate.close()
    do { try proxy.finish() } catch { logger.warning("\(error)") }
    continuation.finish()
    // Flush replies already produced, without waiting on a client that has
    // stopped reading.
    await writer.finish(grace: .seconds(2))
    for task in tasks { task.cancel() }
    await hostBridge?.shutdown()
    for task in tasks { await task.value }
    if let failure { throw failure }
  }
}

private enum ACPEvent: Sendable {
  case client(ACPInbound)
  case backend(String, UUID, ACPInbound)
  case ended(String, UUID, String)
  case timeout(String, UUID)
  case failed(String)
  case eof
}

// ArgumentParser's property wrappers aren't Sendable. This immutable snapshot is
// created once per task and never shared with the mutable parser or proxy.
private struct ACPLaunchSnapshot: @unchecked Sendable {
  let options: SharedOptions
  let arguments: [String]
  let settings: ProjectSettings?
}

private struct ACPInput: ReaderStream {
  let input: AsyncStream<Data>
  func stream() -> AsyncStream<Data> { input }
}

/// Frames one backend's stdout on the runtime's I/O thread. `write` blocks
/// while that backend's window is full, which stops the runtime from reading
/// more; nothing is thrown, because runtimes may discard writer errors, so
/// every outcome is reported as an event instead.
private final class ACPBackendOutput: Writer, @unchecked Sendable {
  private let lock = NSLock()
  private let ingress: ACPIngress
  private let emit: @Sendable (ACPInbound) -> Void

  init(ingress: ACPIngress, emit: @escaping @Sendable (ACPInbound) -> Void) {
    self.ingress = ingress
    self.emit = emit
  }

  func write(_ data: Data) throws {
    lock.withLock { ingress.receive(data, emit: emit) }
  }

  func close() throws {}
}

private struct ACPOutput: Writer {
  let receive: @Sendable (Data) -> Void
  init(_ receive: @escaping @Sendable (Data) -> Void) { self.receive = receive }
  func write(_ data: Data) throws { receive(data) }
  func close() throws {}
}
