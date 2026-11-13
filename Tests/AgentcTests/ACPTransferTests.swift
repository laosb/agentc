import Foundation
import Testing

@testable import agentc

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

private final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value { lock.withLock { stored } }
  func with<Result>(_ body: (inout Value) -> Result) -> Result { lock.withLock { body(&stored) } }
}

private func waitUntil(_ what: String, _ condition: @Sendable () -> Bool) async throws {
  for _ in 0..<2000 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw ACPError("Timed out waiting until \(what)")
}

/// Synthetic base64-looking bytes; never real user content.
private func syntheticPayload(_ count: Int) -> Data {
  let unit = Data("QUdFTlRDK3N5bnRoZXRpYy9wYXlsb2FkMDEyMzQ1Njc4OQ==".utf8.dropLast(2))
  var data = Data(capacity: count + unit.count)
  while data.count < count { data.append(unit) }
  return data.prefix(count)
}

private func feed(_ harness: Harness, _ data: Data, chunk: Int = 64 * 1024 + 1) throws {
  var start = 0
  while start < data.count {
    let end = min(start + chunk, data.count)
    try harness.proxy.receiveClient(data.subdata(in: start..<end))
    start = end
  }
}

/// Opens a session in `root`, starting its backend, and returns the external id.
private func openSession(_ harness: Harness, _ root: URL, id: ACPValue = 2) throws -> String {
  let started = harness.launched[root.path] != nil
  try harness.client("session/new", id: id, params: ["cwd": .string(root.path)])
  if !started { try harness.reply(root.path, result: Harness.capabilities) }
  try harness.reply(root.path, result: ["sessionId": "native"])
  return try #require(harness.output.last?["result"]?.object?["sessionId"]?.string)
}

private func lastKey(_ harness: Harness, _ backend: String) throws -> String {
  let data = try #require(harness.raw[backend]?.last)
  // The key is near one end; the payload in between is never searched.
  let text = String(decoding: data.prefix(64) + data.suffix(200), as: UTF8.self)
  let match = try #require(text.range(of: #""agentc-\d+""#, options: [.regularExpression, .backwards]))
  return String(text[match])
}

@Suite("ACP large messages")
struct ACPTransferTests {
  @Test func forwardsLargeMessagesByteForByteWithMetadataLast() throws {
    let root = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = try ACPSpool(limits: .standard)
    defer { spool.remove() }
    let harness = try Harness(spool: spool)
    try harness.initialize()
    let external = try openSession(harness, root)

    // The reproduced failure: far beyond the old 16 MiB cap, an image block the
    // proxy must not interpret, and every routing field after the payload.
    var body = Data(
      #"{ "params":{"prompt":[{"type":"image","mimeType":"image/vnd.adobe.photoshop","precise":1.00000000000000000000000001e400,"data":""#
        .utf8)
    body.append(syntheticPayload(20 * 1024 * 1024))
    let prefix = body
    body.append(
      Data(
        #""}],"sessionId":"\#(external)"}, "method":"session/prompt","jsonrpc":"2.0","id":9007199254740993}"#
          .utf8))
    body.append(0x0A)
    try feed(harness, body)
    let key = try lastKey(harness, root.path)
    var expected = prefix
    expected.append(
      Data(
        #""}],"sessionId":"native"}, "method":"session/prompt","jsonrpc":"2.0","id":\#(key)}"#.utf8))
    expected.append(0x0A)
    #expect(harness.raw[root.path]?.last == expected)
    #expect(harness.spooled == 1)
    #expect(harness.output.count == 2)
    // Nothing is retained while the request is outstanding.
    #expect(spool.openFiles == 0 && spool.usedBytes == 0)

    // A large response: the id returns as the client's exact token.
    var response = Data(#"{"result":{"blob":""#.utf8)
    response.append(syntheticPayload(2 * 1024 * 1024))
    let responsePrefix = response
    response.append(Data(#"","sessionId":"native"},"id":\#(key),"jsonrpc":"2.0"}"#.utf8))
    response.append(0x0A)
    try harness.proxy.receiveBackend(root.path, data: response)
    var expectedResponse = responsePrefix
    expectedResponse.append(
      Data(#"","sessionId":"\#(external)"},"id":9007199254740993,"jsonrpc":"2.0"}"#.utf8))
    expectedResponse.append(0x0A)
    #expect(harness.rawOutput.last == expectedResponse)

    // A large agent request, and the client's large reply to it.
    var callback = Data(#"{"jsonrpc":"2.0","method":"_agent/ask","params":{"blob":""#.utf8)
    callback.append(syntheticPayload(300 * 1024))
    callback.append(Data(#"","sessionId":"native"},"id":null}"#.utf8))
    callback.append(0x0A)
    try harness.proxy.receiveBackend(root.path, data: callback)
    let delivered = try #require(harness.output.last)
    #expect(delivered["params"]?.object?["sessionId"] == .string(external))
    let callbackKey = try #require(delivered["id"]?.string)
    var reply = Data(#"{"result":{"blob":""#.utf8)
    reply.append(syntheticPayload(300 * 1024))
    let replyPrefix = reply
    reply.append(Data(#""},"jsonrpc":"2.0","id":"\#(callbackKey)"}"#.utf8))
    reply.append(0x0A)
    try feed(harness, reply)
    var expectedReply = replyPrefix
    expectedReply.append(Data(#""},"jsonrpc":"2.0","id":null}"#.utf8))
    expectedReply.append(0x0A)
    #expect(harness.raw[root.path]?.last == expectedReply)
    #expect(harness.diagnostics.isEmpty)
    #expect(spool.openFiles == 0 && spool.usedBytes == 0)
    try harness.proxy.finish()
  }

  @Test func workspacesKeepSeparateSessionAndIDNamespaces() throws {
    let first = try temporaryLogDirectory()
    let second = try temporaryLogDirectory()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    var limits = ACPLimits()
    limits.inlineBytes = 512  // Spool even modest messages.
    let harness = try Harness(limits: limits)
    try harness.initialize()
    let externals = [try openSession(harness, first, id: 2), try openSession(harness, second, id: 3)]
    #expect(externals[0] != externals[1])
    let blob = String(decoding: syntheticPayload(4096), as: UTF8.self)
    var keys: [String] = []
    // The client reuses one id; both sessions share the native id "native".
    for (root, external) in zip([first, second], externals) {
      try harness.proxy.receiveClient(
        Data(
          (#"{"id":"same","params":{"blob":"\#(blob)","sessionId":"\#(external)"},"method":"session/prompt","jsonrpc":"2.0"}"#
            + "\n").utf8))
      let sent = try #require(harness.raw[root.path]?.last)
      keys.append(try lastKey(harness, root.path))
      #expect(
        String(decoding: sent, as: UTF8.self)
          == #"{"id":\#(keys.last!),"params":{"blob":"\#(blob)","sessionId":"native"},"method":"session/prompt","jsonrpc":"2.0"}"#
          + "\n")
    }
    #expect(keys[0] != keys[1] && harness.spooled == 2)
    // Both agents call back with the same id, and each answer finds its agent.
    var callbacks: [String] = []
    for root in [first, second] {
      try harness.proxy.receiveBackend(
        root.path,
        data: Data(
          (#"{"jsonrpc":"2.0","id":3,"method":"fs/read_text_file","params":{"sessionId":"native"}}"#
            + "\n").utf8))
      callbacks.append(try #require(harness.output.last?["id"]?.string))
    }
    #expect(callbacks[0] != callbacks[1])
    for (index, root) in [second, first].enumerated() {
      try harness.proxy.receiveClient(
        Data((#"{"jsonrpc":"2.0","id":"\#(callbacks[1 - index])","result":"\#(root.lastPathComponent)"}"# + "\n").utf8))
      #expect(
        String(decoding: try #require(harness.raw[root.path]?.last), as: UTF8.self)
          == #"{"jsonrpc":"2.0","id":3,"result":"\#(root.lastPathComponent)"}"# + "\n")
    }
    // Responses arrive in the other order and keep the client's id.
    for (index, root) in [second, first].enumerated() {
      try harness.proxy.receiveBackend(
        root.path,
        data: Data((#"{"jsonrpc":"2.0","result":{"n":\#(index)},"id":\#(keys[1 - index])}"# + "\n").utf8))
      #expect(
        String(decoding: try #require(harness.rawOutput.last), as: UTF8.self)
          == #"{"jsonrpc":"2.0","result":{"n":\#(index)},"id":"same"}"# + "\n")
    }
    // A session id from one workspace is unknown to no backend but its own.
    try harness.proxy.backendEnded(first.path, reason: "test")
    try harness.proxy.receiveClient(
      Data((#"{"jsonrpc":"2.0","id":9,"method":"session/prompt","params":{"sessionId":"\#(externals[0])"}}"# + "\n").utf8))
    #expect(harness.output.last?["id"] == 9 && harness.output.last?["error"] != nil)
    try harness.proxy.finish()
  }

  @Test func clientRejectionsAreExplicitAndNeverRouted() throws {
    let root = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var limits = ACPLimits()
    limits.inlineBytes = 1024
    limits.controlBytes = 4096
    limits.messageBytes = 64 * 1024
    let harness = try Harness(limits: limits)
    try harness.initialize()
    let external = try openSession(harness, root)
    let big = String(decoding: syntheticPayload(limits.messageBytes), as: UTF8.self)
    let control = String(decoding: syntheticPayload(limits.controlBytes), as: UTF8.self)
    let sentBefore = harness.raw.mapValues(\.count)

    func expectError(_ line: String, id: ACPValue, code: Int, _ text: String) throws {
      let before = harness.output.count
      try feed(harness, Data((line + "\n").utf8), chunk: 4099)
      #expect(harness.output.count == before + 1, "exactly one reply")
      #expect(harness.output.last?["id"] == id)
      #expect(harness.output.last?["error"]?.object?["code"] == .number(Decimal(code)))
      let message = harness.output.last?["error"]?.object?["message"]?.string ?? ""
      #expect(message.contains(text), "\(message)")
    }
    // Oversized, with the id only at the very end: still answered by id.
    try expectError(
      #"{"jsonrpc":"2.0","method":"session/prompt","params":{"sessionId":"\#(external)","blob":"\#(big)"},"id":41}"#,
      id: 41, code: -32600, "exceeds the 65536-byte limit")
    // Not JSON: no field can be trusted, so the reply has a null id.
    try expectError(#"{"jsonrpc":"2.0","id":42,"method":"m""#, id: .null, code: -32700, "Parse error")
    try expectError(
      #"{"jsonrpc":"2.0","id":43,"method":"m","params":{"x":"\ud800"}}"#, id: .null, code: -32700,
      "surrogate")
    try expectError(
      #"{"jsonrpc":"2.0","method":"m","params":{"blob":"\#(big)\#(big)"},"id":44"#, id: .null,
      code: -32700, "Parse error")
    // Duplicate routing members never select a backend.
    try expectError(
      #"{"jsonrpc":"2.0","id":45,"method":"session/prompt","params":{"sessionId":"\#(external)","sessionId":"\#(external)"}}"#,
      id: 45, code: -32600, "Duplicate")
    try expectError(
      #"{"jsonrpc":"2.0","id":46,"id":47,"method":"session/prompt","params":{"sessionId":"\#(external)"}}"#,
      id: .null, code: -32600, "Duplicate")
    try expectError("[1,2,3]", id: .null, code: -32600, "JSON-RPC 2.0 object")
    try expectError(#"{"id":48,"method":"m"}"#, id: 48, code: -32600, "JSON-RPC 2.0 object")
    // Messages the proxy must decode stay small.
    try expectError(
      #"{"jsonrpc":"2.0","id":49,"method":"session/new","params":{"cwd":"\#(root.path)","pad":"\#(control)"}}"#,
      id: 49, code: -32602, "control message exceeds")
    try expectError(#"{"jsonrpc":"2.0","id":50,"method":5}"#, id: 50, code: -32602, "method")
    #expect(harness.raw.mapValues(\.count) == sentBefore, "no rejected message reached a backend")

    // An oversized notification has nobody waiting; it is logged, not answered.
    let outputs = harness.output.count
    try feed(
      harness, Data((#"{"jsonrpc":"2.0","method":"_note","params":{"blob":"\#(big)"}}"# + "\n").utf8))
    #expect(harness.output.count == outputs)
    #expect(harness.diagnostics.last?.contains("exceeds") == true)

    // A rejected reply to an agent request is turned into an error for the agent.
    try harness.server(root.path, ["jsonrpc": "2.0", "id": 77, "method": "fs/read_text_file"])
    let callback = try #require(harness.output.last?["id"]?.string)
    try feed(
      harness,
      Data((#"{"jsonrpc":"2.0","result":{"blob":"\#(big)"},"id":"\#(callback)"}"# + "\n").utf8))
    #expect(harness.sent[root.path]?.last?["id"] == 77)
    #expect(harness.sent[root.path]?.last?["error"] != nil)
    // The session still works after every rejection.
    try harness.client("session/prompt", id: 60, params: ["sessionId": .string(external)])
    #expect(harness.sent[root.path]?.last?["method"] == "session/prompt")
    try harness.proxy.finish()
  }

  @Test func backendRejectionsFailOnlyWhatCannotBeCorrelated() throws {
    let root = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var limits = ACPLimits()
    limits.inlineBytes = 1024
    limits.messageBytes = 64 * 1024
    let harness = try Harness(limits: limits)
    try harness.initialize()
    let external = try openSession(harness, root)
    let big = String(decoding: syntheticPayload(limits.messageBytes), as: UTF8.self)
    func backend(_ line: String) throws {
      try harness.proxy.receiveBackend(root.path, data: Data((line + "\n").utf8))
    }
    // An oversized response still identifies its request.
    try harness.client("session/prompt", id: 5, params: ["sessionId": .string(external)])
    try backend(#"{"jsonrpc":"2.0","result":{"blob":"\#(big)"},"id":\#(try lastKey(harness, root.path))}"#)
    #expect(harness.output.last?["id"] == 5)
    #expect(harness.output.last?["error"]?.object?["code"] == -32603)
    // An oversized agent request is refused to the agent; a notification is dropped.
    try backend(#"{"jsonrpc":"2.0","method":"_ask","params":{"blob":"\#(big)"},"id":8}"#)
    #expect(harness.sent[root.path]?.last?["id"] == 8)
    #expect(harness.sent[root.path]?.last?["error"] != nil)
    let outputs = harness.output.count
    try backend(#"{"jsonrpc":"2.0","method":"session/update","params":{"blob":"\#(big)"}}"#)
    #expect(harness.output.count == outputs && harness.closed.isEmpty)
    // A line that cannot be attributed fails the backend and all it owes.
    try harness.client("session/prompt", id: 6, params: ["sessionId": .string(external)])
    try backend(#"{"jsonrpc":"2.0","id":1,"id":2,"result":{}}"#)
    #expect(harness.output.last?["id"] == 6)
    #expect(harness.output.last?["error"]?.object?["code"] == -32603)
    #expect(harness.closed == [root.path])
    try harness.proxy.finish()
  }

  @Test func spoolIsPrivateBoundedAndReleasedOnEveryPath() throws {
    var limits = ACPLimits()
    limits.inlineBytes = 1024
    limits.spoolBytes = 1024 * 1024  // Room for one in-flight spooled message.
    let spool = try ACPSpool(limits: limits)
    let attributes = try FileManager.default.attributesOfItem(atPath: spool.directory)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let harness = try Harness(limits: limits, spool: spool)
    try harness.initialize()
    harness.hold = true
    let blob = String(decoding: syntheticPayload(100 * 1024), as: UTF8.self)
    func request(_ id: Int) throws {
      try feed(
        harness,
        Data((#"{"jsonrpc":"2.0","method":"_big","params":{"blob":"\#(blob)"},"id":\#(id)}"# + "\n").utf8))
    }
    try request(10)
    #expect(harness.held.count == 1 && spool.openFiles == 1 && spool.usedBytes == 1024 * 1024)
    // Even while in use, a spooled message has no name on disk.
    #expect(try FileManager.default.contentsOfDirectory(atPath: spool.directory).isEmpty)
    // Quota exhaustion is an explicit failure of the new message, not a wait.
    try request(11)
    #expect(harness.held.count == 1)
    #expect(harness.output.last?["id"] == 11)
    #expect(
      harness.output.last?["error"]?.object?["message"]?.string?.contains("spool quota") == true)
    harness.held.removeAll()
    #expect(spool.openFiles == 0 && spool.usedBytes == 0)
    try request(12)
    #expect(harness.held.count == 1 && spool.openFiles == 1)
    harness.held.removeAll()
    // A partially received message is released when the proxy goes away.
    try feed(harness, Data((#"{"jsonrpc":"2.0","method":"_big","params":{"blob":"\#(blob)"#).utf8))
    #expect(spool.openFiles == 1)
    #expect(throws: ACPError.self) { try harness.proxy.finish() }
    harness.proxy = nil
    #expect(spool.openFiles == 0 && spool.usedBytes == 0)
    spool.remove()
    #expect(!FileManager.default.fileExists(atPath: spool.directory))
  }

  @Test func fullWindowBlocksTheReaderUntilOutputDrains() async throws {
    var limits = ACPLimits()
    limits.windowFrames = 4
    let spool = try ACPSpool(limits: limits)
    defer { spool.remove() }
    let gate = ACPGate(limits: limits)
    let held = Locked<[ACPInbound]>([])
    let seen = Locked(0)
    let finished = Locked(false)
    var input = Data()
    // Rejections count against the window like any other message.
    for index in 0..<20 {
      input.append(Data((index % 3 == 0 ? "garbage\n" : "{\"jsonrpc\":\"2.0\",\"id\":\(index)}\n").utf8))
    }
    let bytes = input
    let frameLimits = limits
    Thread.detachNewThread {
      let ingress = ACPIngress(limits: frameLimits, spool: spool, gate: gate)
      ingress.receive(bytes) { inbound in
        held.with { $0.append(inbound) }
        seen.with { $0 += 1 }
      }
      finished.with { $0 = true }
    }
    try await waitUntil("the window fills") { seen.value == 4 }
    try await Task.sleep(for: .milliseconds(100))
    #expect(seen.value == 4 && gate.inFlight.frames == 4 && !finished.value)
    // Each completed output admits exactly one more input.
    held.with { _ = $0.removeFirst() }
    try await waitUntil("one more is admitted") { seen.value == 5 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(seen.value == 5 && gate.inFlight.frames == 4)
    while !finished.value {
      held.with { $0.removeAll() }
      try await Task.sleep(for: .milliseconds(2))
    }
    held.with { $0.removeAll() }
    #expect(seen.value == 20 && gate.inFlight.frames == 0 && gate.inFlight.bytes == 0)

    // The byte window bounds in-memory messages independently of their count.
    limits.windowFrames = 64
    limits.windowBytes = 10 * 1024
    let byteGate = ACPGate(limits: limits)
    let blocked = Locked(false)
    let large = Data(
      String(
        repeating: #"{"jsonrpc":"2.0","x":""# + String(repeating: "a", count: 4000) + "\"}\n", count: 5
      ).utf8)
    let byteLimits = limits
    Thread.detachNewThread {
      let ingress = ACPIngress(limits: byteLimits, spool: spool, gate: byteGate)
      ingress.receive(large) { inbound in held.with { $0.append(inbound) } }
      blocked.with { $0 = true }
    }
    try await waitUntil("the byte window fills") { held.value.count == 2 }
    try await Task.sleep(for: .milliseconds(100))
    #expect(held.value.count == 2 && !blocked.value)
    // Closing the gate wakes a blocked reader, which then stops producing.
    byteGate.close()
    try await waitUntil("the reader stops") { blocked.value }
    #expect(held.value.count == 2)
    held.with { $0.removeAll() }
  }

  @Test func pullStreamProducesChunksOnDemand() async throws {
    var limits = ACPLimits()
    limits.inlineBytes = 16
    let spool = try ACPSpool(limits: limits)
    defer { spool.remove() }
    let gate = ACPGate(limits: limits)
    let blob = String(decoding: syntheticPayload(10_000), as: UTF8.self)
    func spooled(_ id: Int) throws -> ACPOutbound {
      let ingress = ACPIngress(limits: limits, spool: spool, gate: gate)
      var received: [ACPInbound] = []
      ingress.receive(
        Data((#"{"jsonrpc":"2.0","id":\#(id),"params":{"sessionId":"s","blob":"\#(blob)"},"method":"m"}"# + "\n").utf8)
      ) { received.append($0) }
      guard case .message(let frame, let permit) = try #require(received.first) else {
        throw ACPError("expected a message")
      }
      let envelope = frame.envelope
      return ACPOutbound(
        body: frame.body,
        edits: [
          .init(range: try #require(envelope.idRange), replacement: Data(#""agentc-9""#.utf8)),
          .init(range: try #require(envelope.paramsSessionRange), replacement: Data(#""native""#.utf8)),
        ], permit: permit)
    }
    let expected = Data(
      (#"{"jsonrpc":"2.0","id":"agentc-9","params":{"sessionId":"native","blob":"\#(blob)"},"method":"m"}"#
        + "\n").utf8)
    #expect(try spooled(1).materialize() == expected)
    #expect(try spooled(1).count == expected.count)
    #expect(gate.inFlight.frames == 0 && spool.openFiles == 0)

    let queue = ACPOutboundQueue()
    let failures = Locked<[String]>([])
    queue.push(try spooled(1))
    queue.push(ACPOutbound(body: .inline(Data("second".utf8))))
    var iterator = queue.stream(chunkBytes: 1000) { reason in failures.with { $0.append(reason) } }
      .makeAsyncIterator()
    var first = Data()
    var chunks = 0
    while first.last != 0x0A {
      let chunk = try #require(await iterator.next())
      #expect(chunk.count <= 1000 + 16)
      first.append(chunk)
      chunks += 1
    }
    #expect(first == expected && chunks >= 10)
    // The consumer may still be writing the last chunk: nothing is released.
    #expect(gate.inFlight.frames == 1 && spool.openFiles == 1)
    #expect(await iterator.next() == Data("second\n".utf8))
    #expect(gate.inFlight.frames == 0 && spool.openFiles == 0)
    #expect(queue.isEmpty)

    // An idle consumer suspends, wakes on a push, and ends on finish.
    let idle = ACPOutboundQueue()
    let stream = idle.stream(chunkBytes: 1000) { _ in }
    let consumer = Task { () -> [Data] in
      var chunks: [Data] = []
      for await chunk in stream { chunks.append(chunk) }
      return chunks
    }
    try await Task.sleep(for: .milliseconds(50))
    idle.push(ACPOutbound(body: .inline(Data("a".utf8))))
    try await waitUntil("the first message is taken") { idle.isEmpty }
    idle.push(ACPOutbound(body: .inline(Data("b".utf8))))
    try await waitUntil("the second message is taken") { idle.isEmpty }
    try await Task.sleep(for: .milliseconds(50))
    idle.finish()
    #expect(await consumer.value == [Data("a\n".utf8), Data("b\n".utf8)])

    // Cancelling a suspended consumer resumes it; later and queued output is
    // dropped and gives back what it held.
    let cancelled = ACPOutboundQueue()
    let cancelledStream = cancelled.stream(chunkBytes: 1000) { _ in }
    let waiting = Task { for await _ in cancelledStream {} }
    try await Task.sleep(for: .milliseconds(50))
    waiting.cancel()
    await waiting.value
    cancelled.push(try spooled(2))
    #expect(gate.inFlight.frames == 0 && spool.openFiles == 0)
    let closed = ACPOutboundQueue()
    closed.push(try spooled(3))
    #expect(gate.inFlight.frames == 1 && spool.openFiles == 1)
    closed.finish()
    #expect(gate.inFlight.frames == 0 && spool.openFiles == 0 && spool.usedBytes == 0)
    #expect(failures.value.isEmpty)

    // Finishing in the middle of a multi-chunk message: the next pull ends the
    // stream with no further bytes, and the active message is released.
    let active = ACPOutboundQueue()
    active.push(try spooled(4))
    active.push(try spooled(5))
    var activeIterator = active.stream(chunkBytes: 1000) { _ in }.makeAsyncIterator()
    #expect(await activeIterator.next()?.count == 1000)
    #expect(gate.inFlight.frames == 2 && spool.openFiles == 2)
    active.finish()
    #expect(gate.inFlight.frames == 1 && spool.openFiles == 1)
    #expect(await activeIterator.next() == nil)
    #expect(gate.inFlight.frames == 0 && spool.openFiles == 0 && spool.usedBytes == 0)

    // The same when the consuming task is cancelled mid-message.
    let interrupted = ACPOutboundQueue()
    interrupted.push(try spooled(6))
    let interruptedStream = interrupted.stream(chunkBytes: 1000) { _ in }
    let taken = Locked(0)
    let consumerTask = Task { () -> Int in
      var iterator = interruptedStream.makeAsyncIterator()
      var later = 0
      if await iterator.next() != nil { taken.with { $0 += 1 } }
      try? await Task.sleep(for: .seconds(30))
      while await iterator.next() != nil { later += 1 }
      return later
    }
    try await waitUntil("the first chunk is taken") { taken.value == 1 }
    #expect(gate.inFlight.frames == 1 && spool.openFiles == 1)
    consumerTask.cancel()
    #expect(await consumerTask.value == 0)
    #expect(gate.inFlight.frames == 0 && spool.openFiles == 0 && spool.usedBytes == 0)

    // A fully written message is released while later ones are still queued.
    let backlog = ACPOutboundQueue()
    for id in 7...9 { backlog.push(try spooled(id)) }
    var backlogIterator = backlog.stream(chunkBytes: 1000) { _ in }.makeAsyncIterator()
    var written = Data()
    while written.last != 0x0A { written.append(try #require(await backlogIterator.next())) }
    #expect(gate.inFlight.frames == 3 && spool.openFiles == 3)
    _ = try #require(await backlogIterator.next())  // First chunk of the second message.
    #expect(gate.inFlight.frames == 2 && spool.openFiles == 2 && !backlog.isEmpty)
    backlog.finish()
    #expect(await backlogIterator.next() == nil)
    #expect(gate.inFlight.frames == 0 && spool.openFiles == 0)
  }

  @Test func spoolDirectoryIsRemovedWithItsLastReference() throws {
    var limits = ACPLimits()
    limits.inlineBytes = 16
    var spool: ACPSpool? = try ACPSpool(limits: limits)
    let directory = try #require(spool?.directory)
    var file: ACPSpoolFile? = try #require(spool).makeFile()
    try Data("spooled".utf8).withUnsafeBytes { try file!.append($0) }
    spool!.remove()
    spool!.remove()  // Idempotent.
    #expect(!FileManager.default.fileExists(atPath: directory))
    #expect(try file!.read(0..<7) == Data("spooled".utf8))
    file = nil
    spool = nil
    // Without an explicit remove(), dropping the spool cleans up.
    spool = try ACPSpool(limits: limits)
    let second = try #require(spool?.directory)
    file = try spool!.makeFile()
    spool = nil
    #expect(FileManager.default.fileExists(atPath: second))  // Still referenced by the file.
    file = nil
    #expect(!FileManager.default.fileExists(atPath: second))
  }

  @Test func clientWriterKeepsOrderAndNeverHoldsUpShutdown() async throws {
    signal(SIGPIPE, SIG_IGN)
    func makePipe() -> (read: Int32, write: Int32) {
      var descriptors: [Int32] = [0, 0]
      precondition(pipe(&descriptors) == 0)
      return (descriptors[0], descriptors[1])
    }
    @Sendable func drain(_ descriptor: Int32, idle: Int32) -> Data {
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 65536)
      while true {
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&event, 1, idle) > 0 else { return data }
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return data }
        data.append(contentsOf: buffer[..<count])
      }
    }
    let failures = Locked<[String]>([])
    let observed = Locked(Data())
    let first = makePipe()
    let writer = ACPClientWriter(
      descriptor: first.write, chunkBytes: 4096, observe: { data in observed.with { $0.append(data) } },
      failed: { reason in failures.with { $0.append(reason) } })
    var expected = Data()
    for index in 0..<50 {
      let body = Data(#"{"n":\#(index),"id":"x"}"#.utf8)
      let range = body.count - 4..<body.count - 1
      writer.push(
        ACPOutbound(body: .inline(body), edits: [.init(range: range, replacement: Data("\(index)".utf8))]))
      expected.append(Data((#"{"n":\#(index),"id":\#(index)}"# + "\n").utf8))
    }
    await writer.finish(grace: .seconds(10))
    #expect(drain(first.read, idle: 100) == expected)
    #expect(observed.value == expected)

    // A client that has stopped reading: shutdown still completes promptly,
    // and output that was never started is dropped rather than leaked.
    let stalled = makePipe()
    let gate = ACPGate(frames: 8, bytes: .max / 2)
    let blocked = ACPClientWriter(
      descriptor: stalled.write, chunkBytes: 4096,
      failed: { reason in failures.with { $0.append(reason) } })
    blocked.push(
      ACPOutbound(body: .inline(Data(repeating: 0x61, count: 4 * 1024 * 1024)), permit: gate.acquire(bytes: 1)))
    blocked.push(ACPOutbound(body: .inline(Data("never".utf8)), permit: gate.acquire(bytes: 1)))
    try await waitUntil("the pipe fills") { gate.inFlight.frames == 2 }
    let start = ContinuousClock.now
    await blocked.finish(grace: .milliseconds(200))
    #expect(ContinuousClock.now - start < .seconds(3))
    #expect(gate.inFlight.frames == 1)
    // Once the pipe moves again the abandoned thread notices and lets go.
    let rest = try await blockingIO { drain(stalled.read, idle: 500) }
    #expect(!rest.isEmpty && rest.count < 4 * 1024 * 1024 && !rest.contains(0x0A))
    try await waitUntil("the abandoned message is released") { gate.inFlight.frames == 0 }
    #expect(failures.value.isEmpty)

    // A closed client is reported, once, and ends the writer.
    let broken = makePipe()
    close(broken.read)
    let failing = ACPClientWriter(
      descriptor: broken.write, chunkBytes: 4096,
      failed: { reason in failures.with { $0.append(reason) } })
    failing.push(ACPOutbound(body: .inline(Data("x".utf8))))
    try await waitUntil("the failure is reported") { failures.value.count == 1 }
    failing.push(ACPOutbound(body: .inline(Data("y".utf8))))
    await failing.finish(grace: .seconds(1))
    #expect(failures.value.count == 1)
    for descriptor in [first.read, first.write, stalled.read, stalled.write, broken.write] {
      close(descriptor)
    }
  }

  @Test func clientReaderFramesOffTheEventLoopAndReportsEOF() async throws {
    var descriptors: [Int32] = [0, 0]
    #expect(pipe(&descriptors) == 0)
    let (input, output) = (descriptors[0], descriptors[1])
    let limits = ACPLimits()
    let spool = try ACPSpool(limits: limits)
    defer { spool.remove() }
    let events = Locked<[String]>([])
    let observed = Locked(Data())
    let reader = ACPClientReader(
      descriptor: input,
      ingress: ACPIngress(limits: limits, spool: spool, gate: ACPGate(limits: limits)),
      chunkBytes: 4096, observe: { data in observed.with { $0.append(Data(data)) } }
    ) { inbound, problem in
      let event: String
      switch inbound {
      case .message(let frame, _): event = "message \(frame.body.count)"
      case .rejected: event = "rejected"
      case .malformed: event = "malformed"
      case nil: event = "eof: \(problem ?? "clean")"
      }
      events.with { $0.append(event) }
    }
    let big = String(decoding: syntheticPayload(600 * 1024), as: UTF8.self)
    let text = #"{"jsonrpc":"2.0","id":1,"x":"\#(big)"}"# + "\nbad\n" + #"{"jsonrpc":"2.0","id""#
    let bytes = Data(text.utf8)
    try await blockingIO {
      bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let count = write(output, buffer.baseAddress! + offset, buffer.count - offset)
          precondition(count > 0)
          offset += count
        }
      }
    }
    try await waitUntil("both lines arrive") { events.value.count == 2 }
    close(output)
    try await waitUntil("EOF is reported") { events.value.count == 3 }
    #expect(
      events.value == ["message \(big.utf8.count + 31)", "malformed", "eof: Truncated ACP message at EOF"])
    // The transcript sees the raw bytes, including the rejected ones.
    #expect(observed.value == bytes)
    reader.stop()
    close(input)
    #expect(spool.openFiles == 0)
  }

  @Test func stdioLogSplitsLongLinesWithoutChangingBytes() throws {
    let directory = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("stdio.log")
    let log = try StdioLog(path: path.path)
    let limit = StdioLog.maximumRecordBytes
    var input = syntheticPayload(limit * 2 + 1000)
    input.append(Data("\nshort\n\n".utf8))
    input.append(syntheticPayload(limit))
    input.append(Data("tail".utf8))
    // Irregular fragments, crossing record boundaries at arbitrary points.
    var start = 0
    var size = 1
    while start < input.count {
      let end = min(start + size, input.count)
      log.record(input.subdata(in: start..<end), stream: .stdin)
      start = end
      size = size * 3 % 50_021 + 1
    }
    log.finish()
    var expected = Data()
    var recorded = Data()
    for record in [
      input[..<limit], input[limit..<limit * 2], input[(limit * 2)..<(limit * 2 + 1001)],
      Data("short\n".utf8), Data("\n".utf8), input[(limit * 2 + 1008)..<(limit * 3 + 1008)],
      Data("tail".utf8),
    ] {
      expected.append(Data("stdin: ".utf8))
      expected.append(record)
      if record.last != 0x0A { expected.append(0x0A) }
      recorded.append(record)
    }
    #expect(recorded == input)
    #expect(try Data(contentsOf: path) == expected)
  }

  /// Reproducible measurement of the reported failure's shape: one ~321 MiB
  /// `session/prompt` line holding three opaque image blocks, with its routing
  /// fields last, sent through the real framing thread, window, spool, proxy,
  /// and pull-based backend stream. The payload is generated; no user data.
  /// Run with scripts/benchmark-acp-large.sh.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTC_ACP_BENCHMARK"] != nil))
  func largePromptBenchmark() async throws {
    let environment = ProcessInfo.processInfo.environment
    let megabytes = Int(environment["AGENTC_ACP_BENCHMARK_MIB"] ?? "") ?? 321
    let root = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try await blockingIO { try ACPBenchmark.run(megabytes: megabytes, root: root) }
    print(report.text)
    #expect(report.forwardedBytes == report.expectedBytes)
    // Memory must not scale with the message: allow a generous fixed margin.
    #expect(report.peakResidentGrowth < 96 * 1024 * 1024, "\(report.text)")
    #expect(report.spoolFilesAfter == 0)
  }
}

private enum ACPBenchmark {
  struct Report: Sendable {
    var text = ""
    var forwardedBytes = 0
    var expectedBytes = 0
    var peakResidentGrowth = 0
    var spoolFilesAfter = 0
  }

  /// Current resident memory. Sampled rather than read from ru_maxrss, which
  /// on Linux survives exec and so reports the test launcher's peak.
  static func residentBytes() throws -> Int {
    let bytes = readResidentBytes()
    // An unreadable value must fail the run, not pass the memory assertion.
    guard bytes > 0 else { throw ACPError("Cannot read resident memory size") }
    return bytes
  }

  private static func readResidentBytes() -> Int {
    #if canImport(Darwin)
      var info = mach_task_basic_info()
      var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
      let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
      }
      return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    #else
      guard let text = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else {
        return 0
      }
      let fields = text.split(separator: " ")
      return fields.count > 1 ? (Int(fields[1]) ?? 0) * Int(sysconf(Int32(_SC_PAGESIZE))) : 0
    #endif
  }

  static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }

  /// Runs on a dedicated thread: the proxy is single-owner and this waits on semaphores.
  static func run(megabytes: Int, root: URL) throws -> Report {
    let limits = ACPLimits.standard
    let spool = try ACPSpool(limits: limits)
    defer { spool.remove() }
    let lines = Locked<[Int]>([0])  // Byte length of each line a backend received.
    let promptDone = DispatchSemaphore(value: 0)
    let total = megabytes * 1024 * 1024
    let proxy = try ACPProxy(
      options: SharedOptions.parse([]), limits: limits, spool: spool,
      launch: { id, _ in
        let queue = ACPOutboundQueue()
        let stream = queue.stream(chunkBytes: limits.chunkBytes) { _ in }
        if id != "discovery" {
          // Stands in for the runtime's stdin relay: pulls chunk by chunk.
          Task.detached {
            for await chunk in stream {
              let finished = lines.with { lines -> Bool in
                lines[lines.count - 1] += chunk.count
                guard chunk.last == 0x0A else { return false }
                let large = lines[lines.count - 1] > total / 2
                lines.append(0)
                return large
              }
              if finished { promptDone.signal() }
            }
          }
        }
        return .init(send: { queue.push($0) }, close: { queue.finish() })
      }, output: { _ in }, diagnostic: { print("diagnostic: \($0)") })
    func line(_ text: String) -> Data { Data((text + "\n").utf8) }
    let capabilities = #"{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}"#
    try proxy.receiveClient(line(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#))
    try proxy.receiveBackend("discovery", data: line(#"{"jsonrpc":"2.0","id":"agentc-1","result":\#(capabilities)}"#))
    try proxy.receiveClient(line(#"{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"\#(root.path)"}}"#))
    try proxy.receiveBackend(root.path, data: line(#"{"jsonrpc":"2.0","id":"agentc-2","result":\#(capabilities)}"#))
    try proxy.receiveBackend(root.path, data: line(#"{"jsonrpc":"2.0","id":"agentc-3","result":{"sessionId":"native"}}"#))
    let external = ACPProxy.sessionID(workspace: root.path, native: "native")

    // Three image blocks, then the routing fields.
    let block = syntheticPayload(64 * 1024)
    let open = Data(#"{"type":"image","mimeType":"image/vnd.adobe.photoshop","data":""#.utf8)
    let head = Data(#"{"params":{"prompt":["#.utf8)
    let tail = Data((#"],"sessionId":"\#(external)"},"method":"session/prompt","jsonrpc":"2.0","id":7}"# + "\n").utf8)
    let blocksPerImage = total / 3 / block.count
    var report = Report()
    let sent = head.count + 3 * (open.count + blocksPerImage * block.count + 2) + 2 + tail.count
    // id 7 -> "agentc-4"; the external session id -> "native".
    report.expectedBytes = sent - 1 + 10 - external.utf8.count + 6

    let gate = ACPGate(limits: limits)
    let inbound = Locked<[ACPInbound]>([])
    let framed = DispatchSemaphore(value: 0)
    let baseline = try residentBytes()
    let peak = Locked(baseline)
    let sampling = Locked(true)
    let sampled = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      while sampling.value {
        // A failed sample poisons the result instead of being skipped.
        let now = (try? residentBytes()) ?? Int.max / 2
        peak.with { $0 = max($0, now) }
        usleep(2000)
      }
      sampled.signal()
    }
    let clock = ContinuousClock()
    let start = clock.now
    Thread.detachNewThread {
      // Stands in for the client reader thread.
      let ingress = ACPIngress(limits: limits, spool: spool, gate: gate)
      let emit: (ACPInbound) -> Void = { item in
        inbound.with { $0.append(item) }
        framed.signal()
      }
      ingress.receive(head, emit: emit)
      for image in 0..<3 {
        ingress.receive(open, emit: emit)
        for _ in 0..<blocksPerImage { ingress.receive(block, emit: emit) }
        ingress.receive(Data((image == 2 ? "\"}" : "\"},").utf8), emit: emit)
      }
      ingress.receive(tail, emit: emit)
    }
    guard framed.wait(timeout: .now() + 900) == .success else {
      throw ACPError("The message was never framed")
    }
    let framedAt = clock.now
    let spooledBytes = spool.usedBytes
    try proxy.receiveClient(inbound.with { $0.removeFirst() })
    guard promptDone.wait(timeout: .now() + 900) == .success else {
      throw ACPError("The message never reached the backend stream")
    }
    let done = clock.now
    sampling.with { $0 = false }
    sampled.wait()
    report.peakResidentGrowth = max(peak.value, try residentBytes()) - baseline
    report.forwardedBytes = lines.value.max() ?? 0
    try proxy.finish()
    // The consumer lets go of the last message on its next pull.
    for _ in 0..<400 where spool.openFiles != 0 { usleep(5000) }
    report.spoolFilesAfter = spool.openFiles

    // Scanner alone, for comparison with the end-to-end rate.
    var scanner = ACPScanner()
    let scanStart = clock.now
    Data(#"{"jsonrpc":"2.0","x":""#.utf8).withUnsafeBytes { _ = scanner.scan($0) }
    block.withUnsafeBytes { bytes in
      for _ in 0..<(total / block.count) { _ = scanner.scan(bytes) }
    }
    let scanTime = seconds(clock.now - scanStart)

    let size = Double(sent) / 1048576
    let frameTime = seconds(framedAt - start)
    let totalTime = seconds(done - start)
    report.text = String(
      format: """
        ACP large-message benchmark (synthetic payload)
          message:            %.1f MiB, 3 image blocks, routing fields last
          validate + spool:   %.2f s (%.0f MiB/s), %.0f MiB on disk
          end to end:         %.2f s (%.0f MiB/s) through proxy and pull stream
          scanner only:       %.2f s (%.0f MiB/s)
          peak RSS growth:    %.1f MiB over a %.1f MiB baseline (sampled every 2 ms)
        """,
      size, frameTime, size / frameTime, Double(spooledBytes) / 1048576, totalTime,
      size / totalTime, scanTime, Double(megabytes) / scanTime,
      Double(report.peakResidentGrowth) / 1048576, Double(baseline) / 1048576)
    return report
  }
}
