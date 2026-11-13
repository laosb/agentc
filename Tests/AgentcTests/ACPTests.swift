import Foundation
import Testing

@testable import agentc

@Suite("ACP proxy")
struct ACPTests {
  @Test func codableRoundTrip() throws {
    let data = Data(
      #"{"jsonrpc":"2.0","id":9007199254740993,"method":"_extension","params":{"unknown":[true,null,{"🌍":1.25}]},"extra":"keep"}"#
        .utf8)
    let value = try ACPProxy.parse(data)
    #expect(value["id"] == .number(Decimal(string: "9007199254740993")!))
    #expect(try ACPProxy.parse(ACPProxy.encode(value)) == value)
  }

  @Test func framing() throws {
    let harness = try Harness()
    try harness.initialize()
    // One byte at a time; CRLF and blank lines are tolerated.
    let input = Data("{\"jsonrpc\":\"2.0\",\"method\":\"_🌍\"}\r\n\n \r\n".utf8)
    for byte in input { try harness.proxy.receiveClient(Data([byte])) }
    #expect(harness.sent["discovery"]?.last?["method"] == "_🌍")
    #expect(harness.diagnostics.isEmpty)
    try harness.proxy.finish()
    let truncated = try Harness()
    try truncated.proxy.receiveClient(Data("partial".utf8))
    #expect(throws: ACPError.self) { try truncated.proxy.finish() }
  }

  @Test func commandOptions() throws {
    let command = try #require(
      AgentcCommand.parseAsRoot([
        "--verbose", "acp", "-c", "claude-acp", "--log-file", "agent.log",
        "--stdio-log-file", "stdio.log", "--", "--custom-agent-option",
      ]) as? ACPCommand)
    #expect(command.logging.verbose)
    #expect(command.logging.logFile == "agent.log")
    #expect(command.options.stdioLogFile == "stdio.log")
    #expect(command.entrypointArguments == ["--custom-agent-option"])
    #expect(throws: (any Error).self) {
      try AgentcCommand.parseAsRoot(["acp", "--mount-path-scheme", "workspace"])
    }
  }

  @Test func workspacePolicy() throws {
    let root = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    let shared = root.appendingPathComponent("shared")
    try FileManager.default.createDirectory(
      at: project.appendingPathComponent(".agentc"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    let file = project.appendingPathComponent(".agentc/settings.json")
    try Data(
      #"{"agent":{"additionalMounts":["../shared"],"excludes":["secret"],"image":"project-image"}}"#
        .utf8
    ).write(to: file)
    let options = try SharedOptions.parse(["--workspace", root.path])
    let workspace = try ACPWorkspace.resolve(project.path, options: options)
    #expect(workspace.settings?.agent?.image == "project-image")
    #expect(workspace.settings?.agent?.excludes == ["secret"])
    #expect(
      workspace.additionalMounts.map { $0.standardizedFileURL.path } == [
        shared.standardizedFileURL.path
      ])
    #expect(throws: ACPError.self) { try ACPWorkspace.resolve("/does-not-exist", options: options) }
    #expect(throws: ACPError.self) { try ACPWorkspace.resolve("relative", options: options) }
    let sibling = root.appendingPathComponent("project-escape")
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    let restricted = try SharedOptions.parse(["--workspace", project.path])
    #expect(throws: ACPError.self) { try ACPWorkspace.resolve(sibling.path, options: restricted) }
    try FileManager.default.createSymbolicLink(
      at: project.appendingPathComponent("escape"), withDestinationURL: shared)
    #expect(throws: ACPError.self) {
      try ACPWorkspace.resolve(project.appendingPathComponent("escape").path, options: restricted)
    }
    try Data("not JSON".utf8).write(to: file)
    #expect(throws: (any Error).self) { try ACPWorkspace.resolve(project.path, options: options) }
  }

  @Test func routesAndPreservesExtensions() throws {
    let root = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = try Harness()
    try harness.initialize()
    try harness.client("session/new", id: 2, params: ["cwd": .string(root.path)])
    #expect(harness.launched.count == 2)
    #expect(harness.launched[root.path]??.cwd.path == root.path)
    #expect(harness.sent[root.path]?.count == 1)  // initialize before session/new
    try harness.reply(root.path, result: Harness.capabilities)
    #expect(harness.sent[root.path]?.last?["method"] == "session/new")
    try harness.reply(root.path, result: ["sessionId": "native"])
    let external = try #require(harness.output.last?["result"]?.object?["sessionId"]?.string)
    #expect(try ACPProxy.decodeSession(external, workspace: root.path) == "native")
    let extensionParams: ACPProxy.Object = [
      "sessionId": .string(external), "opaque": ["nested": [1, true, .null]],
      "cwd": "/not-a-mount-request", "additionalDirectories": ["/also-not-a-mount-request"],
    ]
    try harness.client("_custom/directory_metadata", id: 3, params: extensionParams)
    var expected = extensionParams
    expected["sessionId"] = "native"
    #expect(harness.sent[root.path]?.last?["params"] == .object(expected))
    try harness.reply(root.path, result: ["opaque": ["unrecognized": true]])
    #expect(harness.output.last?["id"] == 3)
    #expect(harness.output.last?["result"] == ["opaque": ["unrecognized": true]])

    // Agent-to-client requests may reuse IDs used by other agents or the client.
    try harness.server(
      root.path,
      [
        "jsonrpc": "2.0", "id": 3, "method": "fs/read_text_file",
        "params": ["sessionId": "native", "path": "/not-an-auto-mount"],
      ])
    let callback = try #require(harness.output.last?["id"])
    #expect(harness.output.last?["params"]?.object?["sessionId"] == .string(external))
    try harness.proxy.receiveClient(
      ACPProxy.encode([
        "jsonrpc": "2.0", "id": callback, "result": ["content": "unchanged"],
      ]))
    #expect(harness.sent[root.path]?.last?["id"] == 3)
    #expect(harness.sent[root.path]?.last?["result"] == ["content": "unchanged"])
    #expect(harness.launched.count == 2)
    try harness.proxy.finish()
    #expect(harness.closed.count == 2)
  }

  @Test func isolatedSessionsAndFailureRecovery() throws {
    let first = try temporaryLogDirectory()
    let second = try temporaryLogDirectory()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    let harness = try Harness()
    try harness.initialize()
    for (index, cwd) in [first, second].enumerated() {
      try harness.client(
        "session/new", id: .number(Decimal(index + 2)), params: ["cwd": .string(cwd.path)])
      try harness.reply(cwd.path, result: Harness.capabilities)
      try harness.reply(cwd.path, result: ["sessionId": "same-native-id"])
    }
    let ids = harness.output.compactMap { $0["result"]?.object?["sessionId"]?.string }
    #expect(ids.count == 2 && ids[0] != ids[1])
    try harness.client(
      "session/add_directory", id: 4, params: ["sessionId": .string(ids[0]), "path": "/"])
    #expect(harness.output.last?["error"] != nil)
    try harness.proxy.receiveClient(Data("not-json\n".utf8))
    // Malformed client input is answered, never silently dropped.
    #expect(harness.output.last?["id"] == .null)
    #expect(harness.output.last?["error"]?.object?["code"] == -32700)
    // Intentional change: a malformed backend line used to be logged and
    // ignored. It may have been a response a client is waiting for, and it has
    // no trustworthy id, so the backend is failed and what it owes is rejected.
    try harness.client(
      "session/prompt", id: 40, params: ["sessionId": .string(ids[0]), "prompt": []])
    try harness.proxy.receiveBackend(first.path, data: Data("not-json\n".utf8))
    #expect(harness.output.last?["id"] == 40)
    #expect(harness.output.last?["error"]?.object?["code"] == -32603)
    #expect(harness.closed == [first.path])
    try harness.client(
      "session/prompt", id: 5, params: ["sessionId": .string(ids[1]), "prompt": []])
    #expect(harness.sent[second.path]?.last?["method"] == "session/prompt")
    try harness.proxy.backendEnded(first.path, reason: "test failure")
    try harness.reply(second.path, result: ["stopReason": "end_turn"])
    #expect(harness.output.last?["id"] == 5)
    #expect(harness.diagnostics.contains { $0.contains("malformed client") })
    #expect(harness.diagnostics.contains { $0.contains("malformed ACP message from backend") })
    try harness.proxy.finish()
  }

  @Test func capabilityMismatchAndStartupFailure() throws {
    let root = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = try Harness()
    try harness.initialize()
    try harness.client("session/new", id: 2, params: ["cwd": .string(root.path)])
    var incompatible = Harness.capabilities
    incompatible["protocolVersion"] = 99
    try harness.reply(root.path, result: incompatible)
    #expect(harness.output.last?["id"] == 2)
    #expect(harness.output.last?["error"] != nil)
    #expect(harness.output.filter { $0["id"] == 1 }.count == 1)
    try harness.client("session/new", id: 3, params: ["cwd": .string(root.path)])
    try harness.proxy.initializationTimedOut(root.path)
    #expect(harness.output.last?["id"] == 3)
    #expect(harness.output.last?["error"] != nil)
    try harness.proxy.finish()
  }

  @Test func settingsSnapshotAndLoadRouting() throws {
    let root = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = try Harness()
    try harness.initialize()
    try harness.client(
      "session/load", id: 2,
      params: [
        "cwd": .string(root.path),
        "sessionId": .string(ACPProxy.sessionID(workspace: root.path, native: "saved")),
      ])
    try harness.reply(root.path, result: Harness.capabilities)
    #expect(harness.sent[root.path]?.last?["params"]?.object?["sessionId"] == "saved")
    try harness.reply(root.path, result: [:])
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".agentc"), withIntermediateDirectories: true)
    try Data(#"{"agent":{"additionalMounts":["/"]}}"#.utf8).write(
      to: root.appendingPathComponent(".agentc/settings.json"))
    try harness.client("session/new", id: 3, params: ["cwd": .string(root.path)])
    #expect(harness.launched.count == 2)
    #expect(harness.sent[root.path]?.last?["method"] == "session/new")
    try harness.proxy.finish()
  }
}

final class Harness {
  static let capabilities: ACPProxy.Object = [
    "protocolVersion": 1,
    "agentCapabilities": [
      "loadSession": true,
      "sessionCapabilities": ["list": [:], "fork": [:], "additionalDirectories": [:]],
    ],
    "authMethods": [],
  ]
  var launched: [String: ACPWorkspace?] = [:]
  var sent: [String: [ACPProxy.Object]] = [:]
  var raw: [String: [Data]] = [:]
  var output: [ACPProxy.Object] = []
  var rawOutput: [Data] = []
  /// Outbound messages kept alive, as a stalled backend would keep them.
  var hold = false
  var held: [ACPOutbound] = []
  var spooled = 0
  var closed: [String] = []
  var diagnostics: [String] = []
  var proxy: ACPProxy!

  init(limits: ACPLimits = .standard, spool: ACPSpool? = nil) throws {
    proxy = ACPProxy(
      options: try SharedOptions.parse([]), limits: limits, spool: spool,
      launch: { [unowned self] id, workspace in
        launched[id] = .some(workspace)
        return .init(
          send: { [unowned self] in
            if case .spooled = $0.body { spooled += 1 }
            if hold { held.append($0) }
            let data = try! $0.materialize()
            raw[id, default: []].append(data)
            // Large payloads are compared as bytes; a tree of one is only slow.
            sent[id, default: []].append(
              data.count > 1 << 20 ? ["large": true] : try! ACPProxy.parse(data))
          }, close: { [unowned self] in closed.append(id) })
      }, output: { [unowned self] in
        let data = try $0.materialize()
        rawOutput.append(data)
        output.append(try ACPProxy.parse(data))
      },
      diagnostic: { [unowned self] in diagnostics.append($0) })
  }

  func initialize() throws {
    try client("initialize", id: 1, params: ["protocolVersion": 1])
    try reply("discovery", result: Self.capabilities)
    #expect(
      output.last?["result"]?.object?["agentCapabilities"]?.object?["sessionCapabilities"] == [:])
  }

  func client(_ method: String, id: ACPValue, params: ACPProxy.Object) throws {
    try proxy.receiveClient(
      ACPProxy.encode([
        "jsonrpc": "2.0", "method": .string(method), "id": id, "params": .object(params),
      ]))
  }

  func server(_ backend: String, _ message: ACPProxy.Object) throws {
    try proxy.receiveBackend(backend, data: ACPProxy.encode(message))
  }

  func reply(_ backend: String, result: ACPProxy.Object) throws {
    let id = try #require(sent[backend]?.last?["id"])
    try server(backend, ["jsonrpc": "2.0", "id": id, "result": .object(result)])
  }
}
