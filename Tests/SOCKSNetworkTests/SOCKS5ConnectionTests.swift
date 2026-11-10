#if os(macOS)
  import AgentIsolation
  import Foundation
  import Network
  @testable import SOCKSNetwork
  import XCTest

  @MainActor
  final class SOCKS5ConnectionTests: XCTestCase {
    func testFragmentedRepliesConsumeEveryAddressTypeAndTunnel() async throws {
      for boundAddress: [UInt8] in [
        [1, 127, 0, 0, 1, 0, 80],
        [4] + Array(repeating: 0, count: 16) + [0, 80],
        [3, 3, 102, 111, 111, 0, 80],
      ] {
        let server = try await MockSOCKSServer.start { peer in
          try await peer.expect([5, 1, 0])
          try await peer.fragment([5, 0])
          try await peer.expect([5, 1, 0, 1, 192, 0, 2, 1, 1, 187])
          try await peer.fragment([5, 0, 0] + boundAddress)
          try await peer.expect([10, 20, 30])
          try await peer.send([40, 50, 60])
          try await peer.finish()
        }
        let transport = try await SOCKS5Connection.connect(
          proxy: server.proxy(), destination: "192.0.2.1", port: 443)
        try await transport.send(Data([10, 20, 30]))
        var output = Data()
        while let bytes = try await transport.receive(maximum: 2) {
          XCTAssertLessThanOrEqual(bytes.count, 2)
          output.append(bytes)
        }
        XCTAssertEqual(output, Data([40, 50, 60]))
        await transport.close()
        try await server.completed()
        await server.stop()
      }
    }

    func testRFC1929Authentication() async throws {
      let server = try await MockSOCKSServer.start { peer in
        try await peer.expect([5, 1, 2])
        try await peer.fragment([5, 2])
        try await peer.expect([1, 4, 117, 115, 101, 114, 4, 112, 97, 115, 115])
        try await peer.fragment([1, 0])
        try await peer.expect([5, 1, 0, 1, 192, 0, 2, 1, 0, 80])
        try await peer.fragment([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
      }
      let transport = try await SOCKS5Connection.connect(
        proxy: server.proxy(authenticated: true), destination: "192.0.2.1", port: 80)
      await transport.close()
      try await server.completed()
      await server.stop()
    }

    func testRejectsDowngradeAndBadAuthentication() async throws {
      for reply: [UInt8] in [[5, 0], [5, 255], [4, 2], [5, 2, 1, 1], [5, 2, 2, 0]] {
        let server = try await MockSOCKSServer.start { peer in
          try await peer.expect([5, 1, 2])
          try await peer.fragment(Array(reply.prefix(2)))
          if reply.count == 4 {
            try await peer.expect([1, 4, 117, 115, 101, 114, 4, 112, 97, 115, 115])
            try await peer.fragment(Array(reply.suffix(2)))
          }
        }
        do {
          _ = try await SOCKS5Connection.connect(
            proxy: server.proxy(authenticated: true), destination: "192.0.2.1", port: 80)
          XCTFail("Accepted invalid authentication")
        } catch {
          XCTAssertTrue(
            error as? SOCKS5Connection.TransportError == .authenticationRejected
              || error as? SOCKS5Connection.TransportError == .malformedReply)
          XCTAssertFalse(String(describing: error).contains("pass"))
        }
        try await server.completed()
        await server.stop()
      }
    }

    func testMalformedAndFailedConnectReplies() async throws {
      let cases: [([UInt8], SOCKS5Connection.TransportError)] = [
        ([4, 0, 0, 1], .malformedReply),
        ([5, 0, 1, 1], .malformedReply),
        ([5, 0, 0, 9], .malformedReply),
        ([5, 0, 0, 3, 0], .malformedReply),
        ([5, 5, 0, 1, 0, 0, 0, 0, 0, 0], .connectRejected(5)),
        ([5, 0, 0, 4, 0], .unexpectedEOF),
      ]
      for (reply, expected) in cases {
        let server = try await MockSOCKSServer.start { peer in
          try await peer.expect([5, 1, 0])
          try await peer.send([5, 0])
          try await peer.expect([5, 1, 0, 1, 192, 0, 2, 1, 0, 80])
          try await peer.send(reply)
          try await peer.finish()
        }
        do {
          _ = try await SOCKS5Connection.connect(
            proxy: server.proxy(), destination: "192.0.2.1", port: 80)
          XCTFail("Accepted invalid CONNECT")
        } catch {
          XCTAssertEqual(error as? SOCKS5Connection.TransportError, expected)
        }
        try await server.completed()
        await server.stop()
      }
    }

    func testHalfClosePreservesReads() async throws {
      let server = try await MockSOCKSServer.start { peer in
        try await peer.negotiate()
        try await peer.expect([1, 2, 3])
        let eof = try await peer.read()
        guard eof == nil else { throw MockError.unexpectedBytes }
        try await peer.send([7, 8, 9])
        try await peer.finish()
      }
      let transport = try await SOCKS5Connection.connect(
        proxy: server.proxy(), destination: "192.0.2.1", port: 80)
      try await transport.send(Data([1, 2, 3]))
      try await transport.finishSending()
      var received = Data()
      while let data = try await transport.receive(maximum: 64) { received.append(data) }
      XCTAssertEqual(received, Data([7, 8, 9]))
      do {
        try await transport.send(Data([4]))
        XCTFail("Sent after FIN")
      } catch {
        XCTAssertEqual(error as? SOCKS5Connection.TransportError, .sendingFinished)
      }
      await transport.close()
      try await server.completed()
      await server.stop()
    }

    func testMaximumSizeTransferWithBoundedReads() async throws {
      let payload = [UInt8](repeating: 123, count: SOCKS5Connection.maximumBufferSize)
      let server = try await MockSOCKSServer.start { peer in
        try await peer.negotiate()
        try await peer.expect(payload)
        try await peer.send(payload)
        try await peer.finish()
      }
      let transport = try await SOCKS5Connection.connect(
        proxy: server.proxy(), destination: "192.0.2.1", port: 80)
      try await transport.send(Data(payload))
      var received = Data()
      while let data = try await transport.receive(maximum: 511) {
        XCTAssertLessThanOrEqual(data.count, 511)
        received.append(data)
      }
      XCTAssertEqual(received, Data(payload))
      await transport.close()
      try await server.completed()
      await server.stop()
    }

    func testCancellationAndExplicitCloseUnblockReceive() async throws {
      for cancel in [true, false] {
        let server = try await MockSOCKSServer.start { peer in
          try await peer.negotiate()
          _ = try await peer.read()
        }
        let transport = try await SOCKS5Connection.connect(
          proxy: server.proxy(), destination: "192.0.2.1", port: 80)
        let read = Task { try await transport.receive(maximum: 32) }
        try await Task.sleep(for: .milliseconds(20))
        if cancel { read.cancel() } else { await transport.close() }
        do {
          _ = try await read.value
          XCTFail("Read did not fail")
        } catch {
          XCTAssertTrue(
            error is CancellationError || error as? SOCKS5Connection.TransportError == .closed)
        }
        await transport.close()
        await server.stop()
      }
    }

    func testOnlyOneConcurrentReceive() async throws {
      let server = try await MockSOCKSServer.start { peer in
        try await peer.negotiate()
        _ = try await peer.read()
      }
      let transport = try await SOCKS5Connection.connect(
        proxy: server.proxy(), destination: "192.0.2.1", port: 80)
      // The task group itself starts two receives; whichever arrives second must fail.
      await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<2 {
          group.addTask {
            do {
              _ = try await transport.receive(maximum: 1)
              return false
            } catch {
              return error as? SOCKS5Connection.TransportError == .concurrentReceive
            }
          }
        }
        let rejected = await group.next()
        XCTAssertEqual(rejected, true)
        await transport.close()
      }
      await server.stop()
    }

    func testHandshakeTimeoutAndCancellation() async throws {
      for cancel in [false, true] {
        let server = try await MockSOCKSServer.start { peer in
          try await peer.expect([5, 1, 0])
          // Never return a method selection.
          _ = try await peer.read()
        }
        let proxy = try server.proxy()
        let task = Task {
          try await SOCKS5Connection.connect(
            proxy: proxy, destination: "192.0.2.1", port: 80,
            timeout: cancel ? .seconds(30) : .milliseconds(100))
        }
        if cancel {
          try await Task.sleep(for: .milliseconds(30))
          task.cancel()
        }
        do {
          _ = try await task.value
          XCTFail("Handshake unexpectedly completed")
        } catch {
          if cancel {
            XCTAssertTrue(error is CancellationError)
          } else {
            XCTAssertEqual(error as? SOCKS5Connection.TransportError, .timedOut)
          }
        }
        await server.stop()
      }
    }

    func testSlowTrickleCannotExtendNegotiationDeadline() async throws {
      let server = try await MockSOCKSServer.start { peer in
        try await peer.expect([5, 1, 0])
        try await peer.send([5, 0])
        try await peer.expect([5, 1, 0, 1, 192, 0, 2, 1, 0, 80])
        // Every individual read can succeed, but the total reply takes > 500 ms.
        try await peer.fragment([5, 0, 0, 3, 255] + Array(repeating: 65, count: 255) + [0, 80])
      }
      do {
        _ = try await SOCKS5Connection.connect(
          proxy: server.proxy(), destination: "192.0.2.1", port: 80,
          timeout: .milliseconds(100))
        XCTFail("Slow trickle extended the handshake indefinitely")
      } catch {
        XCTAssertEqual(error as? SOCKS5Connection.TransportError, .timedOut)
      }
      await server.stop()
    }

    func testInvalidDestinationsAreRejectedWithoutDialing() async throws {
      let proxy = try SOCKS5Proxy(url: "socks5://127.0.0.1:1")
      for destination in ["example.com", "::1", "127.1", "256.0.0.1", "1.2.3.", " 1.2.3.4"] {
        do {
          _ = try await SOCKS5Connection.connect(proxy: proxy, destination: destination, port: 80)
          XCTFail("Accepted \(destination)")
        } catch {
          XCTAssertEqual(error as? SOCKS5Connection.TransportError, .invalidDestination)
        }
      }
    }

    func testHostMCPDirectConnectionAndBufferBounds() async throws {
      let server = try await MockSOCKSServer.start { peer in
        // No SOCKS negotiation is sent to the loopback-only exception.
        try await peer.expect([42])
        try await peer.send([43])
        try await peer.finish()
      }
      let transport = try await SOCKS5Connection.connectHostMCP(port: server.port)
      for size in [0, -1, SOCKS5Connection.maximumBufferSize + 1] {
        do {
          _ = try await transport.receive(maximum: size)
          XCTFail("Accepted invalid read bound")
        } catch {
          XCTAssertEqual(error as? SOCKS5Connection.TransportError, .invalidBufferSize)
        }
      }
      do {
        try await transport.send(Data(repeating: 0, count: SOCKS5Connection.maximumBufferSize + 1))
        XCTFail("Accepted oversized write")
      } catch {
        XCTAssertEqual(error as? SOCKS5Connection.TransportError, .invalidBufferSize)
      }
      try await transport.send(Data([42]))
      let reply = try await transport.receive(maximum: 1)
      XCTAssertEqual(reply, Data([43]))
      await transport.close()
      try await server.completed()
      await server.stop()
    }
  }

  private enum MockError: Error { case unexpectedBytes, stopped }

  private actor MockPeer {
    let connection: NWConnection

    init(_ connection: NWConnection) {
      self.connection = connection
      connection.start(queue: DispatchQueue(label: "agentc.test.socks.peer"))
    }

    func read(maximum: Int = 1024) async throws -> Data? {
      try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) {
          data, _, complete, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let data, !data.isEmpty {
            continuation.resume(returning: data)
          } else if complete {
            continuation.resume(returning: nil)
          } else {
            continuation.resume(throwing: MockError.unexpectedBytes)
          }
        }
      }
    }

    func expect(_ expected: [UInt8]) async throws {
      var bytes = Data()
      while bytes.count < expected.count {
        guard let next = try await read(maximum: expected.count - bytes.count) else {
          throw MockError.unexpectedBytes
        }
        bytes.append(next)
      }
      guard bytes == Data(expected) else { throw MockError.unexpectedBytes }
    }

    func send(_ bytes: [UInt8]) async throws {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        connection.send(
          content: Data(bytes),
          completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
          })
      }
    }

    func fragment(_ bytes: [UInt8]) async throws {
      for byte in bytes {
        try await send([byte])
        try await Task.sleep(for: .milliseconds(2))
      }
    }

    func finish() async throws {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        connection.send(
          content: nil, contentContext: .finalMessage, isComplete: true,
          completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
          })
      }
    }

    func negotiate() async throws {
      try await expect([5, 1, 0])
      try await send([5, 0])
      try await expect([5, 1, 0, 1, 192, 0, 2, 1, 0, 80])
      try await send([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
    }

    func stop() { connection.cancel() }
  }

  private actor MockSOCKSServer {
    nonisolated let port: UInt16
    private let listener: NWListener
    private var peers: [MockPeer] = []
    private let result: AsyncThrowingStream<Void, any Error>
    private let completion: AsyncThrowingStream<Void, any Error>.Continuation

    private init(listener: NWListener, port: UInt16) {
      self.listener = listener
      self.port = port
      (result, completion) = AsyncThrowingStream.makeStream()
    }

    static func start(
      script: @escaping @Sendable (MockPeer) async throws -> Void
    ) async throws -> MockSOCKSServer {
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
      let listener = try NWListener(using: parameters)
      let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
        // This callback is serialized by the listener's queue and removed at readiness.
        listener.stateUpdateHandler = { state in
          switch state {
          case .ready:
            listener.stateUpdateHandler = nil
            continuation.resume(returning: listener.port!.rawValue)
          case .failed(let error):
            listener.stateUpdateHandler = nil
            continuation.resume(throwing: error)
          default: break
          }
        }
        listener.newConnectionHandler = { connection in connection.cancel() }
        listener.start(queue: DispatchQueue(label: "agentc.test.socks.listener"))
      }
      let server = MockSOCKSServer(listener: listener, port: port)
      listener.newConnectionHandler = { connection in
        Task { await server.accept(connection, script: script) }
      }
      return server
    }

    nonisolated func proxy(authenticated: Bool = false) throws -> SOCKS5Proxy {
      try SOCKS5Proxy(
        url: "socks5://127.0.0.1:\(port)",
        environment: authenticated
          ? ["AGENTC_SOCKS5_USERNAME": "user", "AGENTC_SOCKS5_PASSWORD": "pass"] : [:])
    }

    private func accept(
      _ connection: NWConnection, script: @escaping @Sendable (MockPeer) async throws -> Void
    ) {
      let peer = MockPeer(connection)
      peers.append(peer)
      Task {
        do {
          try await script(peer)
          completion.finish()
        } catch {
          completion.finish(throwing: error)
        }
      }
    }

    func completed() async throws {
      for try await _ in result {}
    }

    func stop() async {
      listener.cancel()
      listener.newConnectionHandler = nil
      for peer in peers { await peer.stop() }
      completion.finish(throwing: MockError.stopped)
    }
  }
#endif
