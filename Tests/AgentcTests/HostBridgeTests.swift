import AgentIsolation
import Foundation
import HostBridge
import Testing

@testable import agentc

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#else
  import Musl
#endif

@Suite("Host bridge")
struct HostBridgeTests {
  @Test func pipeDescriptorsAreCloseOnExec() throws {
    let pipe = try BridgePOSIX.pipe()
    defer { close(pipe.read); close(pipe.write) }
    #expect(fcntl(pipe.read, F_GETFD) == FD_CLOEXEC)
    #expect(fcntl(pipe.write, F_GETFD) == FD_CLOEXEC)
  }

  @Test func acceptedSocketIsCloseOnExec() throws {
    // Keep the Unix socket path below sockaddr_un's platform-specific limit.
    let directory = URL(fileURLWithPath: "/tmp/agentc-accept-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("socket").path
    let listener = try BridgePOSIX.socket(path: path, listening: true)
    defer { close(listener) }
    let client = try BridgePOSIX.socket(path: path, listening: false)
    defer { close(client) }
    let accepted = BridgePOSIX.accept(listener)
    #expect(accepted >= 0)
    guard accepted >= 0 else { return }
    defer { close(accepted) }
    #if os(Linux)
      #expect(fcntl(accepted, F_GETFD) == FD_CLOEXEC)
    #endif
    try BridgePOSIX.configureSocket(accepted)
    #expect(fcntl(accepted, F_GETFD) == FD_CLOEXEC)
    #expect(fcntl(accepted, F_GETFL) & O_NONBLOCK != 0)
  }

  @Test func framingAndLimits() throws {
    let bytes = Data((0...255).map(UInt8.init))
    let encoded = try BridgeFrame(.stdout, bytes).encoded()
    var decoder = BridgeDecoder()
    var frames: [BridgeFrame] = []
    for byte in encoded { frames += try decoder.append(Data([byte])) }
    #expect(frames.count == 1)
    #expect(frames[0].kind == .stdout)
    #expect(frames[0].data == bytes)
    try decoder.finish()
    _ = try decoder.append(Data([1, 0]))
    #expect(throws: BridgeError.self) { try decoder.finish() }
    var oversized = BridgeDecoder()
    #expect(throws: BridgeError.self) {
      _ = try oversized.append(Data([1, 0x7f, 0xff, 0xff, 0xff]))
    }
    #expect(throws: BridgeError.self) {
      _ = try BridgeFrame(.stdin, Data(repeating: 0, count: BridgeFrame.chunkSize + 1)).encoded()
    }
  }

  @Test func idleBrokersDoNotBlockNewInvocations() async throws {
    let result = try await blockingIO {
      var idle: [HostBridgeBroker] = []
      defer { for broker in idle { broker.stop() } }
      for _ in 0..<32 {
        idle.append(
          try HostBridgeBroker(
            mappings: [.init(containerPath: "/usr/local/bin/host", hostCommand: "/bin/cat")],
            workspace: "/tmp"))
      }
      return try roundTripBlocking(
        command: "/bin/cat", arguments: [], input: Data("still responsive".utf8))
    }
    #expect(result.output == Data("still responsive".utf8))
    #expect(result.termination.code == 0)
  }

  @Test func settingsAndAuthorization() throws {
    let settings = try JSONDecoder().decode(
      ProjectSettings.self,
      from: Data(
        #"{"agent":{"hostBinaries":[{"containerPath":"/usr/local/bin/host-env","hostCommand":"/usr/bin/env","forwardEnvironment":["LANG"]}]}}"#
          .utf8))
    #expect(settings.agent?.hostBinaries?.first?.forwardEnvironment == ["LANG"])
    let options = try SharedOptions.parse(["--allow-host-binaries", "--bootstrap-host-bridge"])
    #expect(options.allowHostBinaries)
    #expect(options.bootstrapHostBridge)
    #expect(try !SharedOptions.parse([]).allowHostBinaries)
    let mapping = HostBinaryMapping(
      containerPath: "/usr/local/bin/host-env", hostCommand: "/usr/bin/env",
      forwardEnvironment: ["YES"])
    let request = BridgeLaunch(
      token: "", mapping: "", arguments: [], environment: ["YES": "empty =\n🌍"])
    let environment = try HostBridgeBroker.environment(
      for: request, mapping: mapping, host: ["HOST": "kept", "YES": "old"])
    #expect(environment == ["HOST": "kept", "YES": "empty =\n🌍"])
    var invalid = request
    invalid.environment["NO"] = "secret"
    #expect(throws: BridgeError.self) {
      _ = try HostBridgeBroker.environment(for: invalid, mapping: mapping, host: [:])
    }
    #expect(throws: BridgeError.self) {
      try HostBridgeBroker.validate([mapping, mapping])
    }
    for path in ["/", "/etc/tool", "/x/../tool", "relative", "/x//tool"] {
      #expect(throws: BridgeError.self) {
        try HostBridgeBroker.validate([.init(containerPath: path, hostCommand: "/bin/cat")])
      }
    }
    #expect(throws: BridgeError.self) {
      try HostBridgeBroker.validate([
        .init(
          containerPath: "/bin/host", hostCommand: "/bin/cat", forwardEnvironment: ["*"])
      ])
    }
  }

  @Test func byteStreamsEOFAndExit() async throws {
    let payload = Data((0..<(512 * 1024)).map { UInt8($0 % 256) })
    let result = try await roundTrip(
      command: "/bin/sh", arguments: ["-c", "cat; printf 'separate stderr' >&2; exit 37"],
      input: payload)
    #expect(result.output == payload)
    #expect(result.error == Data("separate stderr".utf8))
    #expect(result.termination == .init(code: 37))
  }

  @Test func forwardsOnlyNamedEnvironmentAndLiteralArguments() async throws {
    let result = try await roundTrip(
      command: "/bin/sh",
      arguments: [
        "-c", #"printf '%s|%s|%s' "$BRIDGE_ALLOWED" "${BRIDGE_NOT_ALLOWED-unset}" "$1""#, "sh",
      ],
      input: Data(), invocation: ["; echo should-not-run"],
      environment: ["BRIDGE_ALLOWED": "forwarded\n🌍"], allowed: ["BRIDGE_ALLOWED"])
    #expect(
      String(decoding: result.output, as: UTF8.self) == "forwarded\n🌍|unset|; echo should-not-run")
  }

  @Test func signalTermination() async throws {
    let result = try await roundTrip(
      command: "/bin/sh", arguments: ["-c", "kill -TERM $$"], input: Data())
    #expect(result.termination.signal == "TERM")
  }

  @Test func childClosesInputEarly() async throws {
    let result = try await roundTrip(
      command: "/bin/sh", arguments: ["-c", "exec 0<&-; printf done; sleep 0.1"],
      input: Data(repeating: 97, count: 1024 * 1024))
    #expect(result.output == Data("done".utf8))
    #expect(result.termination.code == 0)
  }

  @Test func signalWorksWhileChildDoesNotReadInput() throws {
    let broker = try HostBridgeBroker(
      mappings: [
        .init(
          containerPath: "/usr/local/bin/host", hostCommand: "/bin/sleep",
          arguments: ["60"])
      ], workspace: "/tmp")
    defer { broker.stop() }
    let peer = BridgeConnection(
      fd: try BridgePOSIX.socket(path: broker.attachment.socket, listening: false))
    try peer.enqueue(
      .init(
        .launch,
        JSONEncoder().encode(
          BridgeLaunch(
            token: broker.manifest.token, mapping: broker.manifest.entries[0].id,
            arguments: [], environment: [:]))))
    try flush(peer)
    #expect(try receive(peer).first?.kind == .stdinReady)
    try peer.enqueue(.init(.stdin, Data(repeating: 0, count: BridgeFrame.chunkSize)))
    try peer.enqueue(.init(.signal, Data("TERM".utf8)))
    try flush(peer)
    var termination: BridgeTermination?
    while termination == nil {
      for frame in try receive(peer) where frame.kind == .exit {
        termination = try JSONDecoder().decode(BridgeTermination.self, from: frame.data)
      }
    }
    #expect(termination?.signal == "TERM")
  }

  @Test func largeStderrAndConcurrentInvocations() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<4 {
        group.addTask {
          let result = try await roundTrip(
            command: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=16384 count=32 >&2 2>/dev/null; printf done"],
            input: Data())
          #expect(result.output == Data("done".utf8))
          #expect(result.error == Data(repeating: 0, count: 512 * 1024))
        }
      }
      try await group.waitForAll()
    }
  }

  @Test func rejectsUnauthorizedPeerAndEnvironment() throws {
    let broker = try HostBridgeBroker(
      mappings: [.init(containerPath: "/usr/local/bin/host", hostCommand: "/usr/bin/env")],
      workspace: "/tmp")
    defer { broker.stop() }
    for validToken in [false, true] {
      let peer = BridgeConnection(
        fd: try BridgePOSIX.socket(path: broker.attachment.socket, listening: false))
      let launch = BridgeLaunch(
        token: validToken ? broker.manifest.token : "wrong",
        mapping: broker.manifest.entries[0].id, arguments: [],
        environment: validToken ? ["NOT_ALLOWED": "value"] : [:])
      try peer.enqueue(.init(.launch, JSONEncoder().encode(launch)))
      try flush(peer)
      let response = try receive(peer)
      #expect(response.first?.kind == .failure)
    }
  }

  @Test func disconnectAndStopReapChildren() throws {
    let broker = try HostBridgeBroker(
      mappings: [
        .init(
          containerPath: "/usr/local/bin/host", hostCommand: "/bin/sh",
          arguments: ["-c", "printf '%s' $$; exec sleep 60"])
      ],
      workspace: "/tmp")
    defer { broker.stop() }
    let peer = BridgeConnection(
      fd: try BridgePOSIX.socket(path: broker.attachment.socket, listening: false))
    try peer.enqueue(
      .init(
        .launch,
        JSONEncoder().encode(
          BridgeLaunch(
            token: broker.manifest.token, mapping: broker.manifest.entries[0].id,
            arguments: [], environment: [:]))))
    try flush(peer)
    var pid: Int32?
    while pid == nil {
      for frame in try receive(peer) where frame.kind == .stdout {
        pid = Int32(String(decoding: frame.data, as: UTF8.self))
      }
    }
    let child = try #require(pid)
    #expect(kill(child, 0) == 0)
    broker.stop()
    #expect(kill(child, 0) == -1 && errno == ESRCH)
    #expect(!FileManager.default.fileExists(atPath: broker.attachment.directory))
  }
}

private func flush(_ connection: BridgeConnection) throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while !connection.output.isEmpty {
    guard ContinuousClock.now < deadline else { throw BridgeError("Test write timeout") }
    try connection.flush()
    usleep(1000)
  }
}

private func receive(_ connection: BridgeConnection) throws -> [BridgeFrame] {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    let frames = try connection.receive()
    if !frames.isEmpty { return frames }
    usleep(1000)
  }
  throw BridgeError("Test read timeout")
}

private func roundTrip(
  command: String, arguments: [String], input: Data, invocation: [String] = [],
  environment: [String: String] = [:], allowed: [String] = []
) async throws -> (output: Data, error: Data, termination: BridgeTermination) {
  try await blockingIO {
    try roundTripBlocking(
      command: command, arguments: arguments, input: input, invocation: invocation,
      environment: environment, allowed: allowed)
  }
}

private func roundTripBlocking(
  command: String, arguments: [String], input: Data, invocation: [String] = [],
  environment: [String: String] = [:], allowed: [String] = []
) throws -> (output: Data, error: Data, termination: BridgeTermination) {
  let directory = try temporaryLogDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let broker = try HostBridgeBroker(
    mappings: [
      .init(
        containerPath: "/usr/local/bin/host", hostCommand: command,
        arguments: arguments, forwardEnvironment: allowed)
    ],
    workspace: directory.path)
  defer { broker.stop() }
  let inputFile = directory.appendingPathComponent("in")
  try input.write(to: inputFile)
  let outputFile = directory.appendingPathComponent("out")
  let errorFile = directory.appendingPathComponent("err")
  let stdin = open(inputFile.path, O_RDONLY)
  let stdout = open(outputFile.path, O_WRONLY | O_CREAT, 0o600)
  let stderr = open(errorFile.path, O_WRONLY | O_CREAT, 0o600)
  defer {
    close(stdin)
    close(stdout)
    close(stderr)
  }
  let termination = try GuestBridge.relay(
    socketPath: broker.attachment.socket,
    launch: .init(
      token: broker.manifest.token, mapping: broker.manifest.entries[0].id,
      arguments: invocation, environment: environment),
    stdinFD: stdin, stdoutFD: stdout, stderrFD: stderr, forwardSignals: false)
  return (try Data(contentsOf: outputFile), try Data(contentsOf: errorFile), termination)
}
