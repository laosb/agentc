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
      Mounts are fixed for the life of each workspace backend. Xcode's macOS
      MCP bridge is not proxied to the host by this command.
      """
  )

  @OptionGroup var options: SharedOptions
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
    var tasks: [Task<Void, Never>] = []
    var generations: [String: UUID] = [:]
    let proxy = ACPProxy(
      options: options,
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
        let (input, stdin) = AsyncStream<Data>.makeStream()
        let snapshot = ACPLaunchSnapshot(options: options, arguments: arguments, settings: settings)
        let task = Task {
          do {
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
                  stdout: ACPOutput { continuation.yield(.backend(id, generation, $0)) },
                  stderr: ACPOutput { FileHandle.standardError.write($0) })))
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
          send: { stdin.yield($0) },
          close: {
            stdin.finish()
            task.cancel()
            timeout.cancel()
          })
      },
      output: { data in
        log?.observer.stdout(data)
        try FileHandle.standardOutput.write(contentsOf: data)
      })
    FileHandle.standardInput.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        continuation.yield(.eof)
      } else {
        continuation.yield(.client(data))
      }
    }
    var failure: (any Error)?
    do {
      eventLoop: for await event in events {
        switch event {
        case .client(let data):
          log?.observer.stdin(data)
          try proxy.receiveClient(data)
        case .backend(let id, let generation, let data):
          guard generations[id] == generation else { continue }
          try proxy.receiveBackend(id, data: data)
        case .ended(let id, let generation, let reason):
          guard generations[id] == generation else { continue }
          try proxy.backendEnded(id, reason: reason)
        case .timeout(let id, let generation):
          guard generations[id] == generation else { continue }
          try proxy.initializationTimedOut(id)
        case .eof: break eventLoop
        }
      }
    } catch { failure = error }
    FileHandle.standardInput.readabilityHandler = nil
    do { try proxy.finish() } catch { logger.warning("\(error)") }
    continuation.finish()
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
    if let failure { throw failure }
  }
}

private enum ACPEvent: Sendable {
  case client(Data)
  case backend(String, UUID, Data)
  case ended(String, UUID, String)
  case timeout(String, UUID)
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

private struct ACPOutput: Writer {
  let receive: @Sendable (Data) -> Void
  init(_ receive: @escaping @Sendable (Data) -> Void) { self.receive = receive }
  func write(_ data: Data) throws { receive(data) }
  func close() throws {}
}
