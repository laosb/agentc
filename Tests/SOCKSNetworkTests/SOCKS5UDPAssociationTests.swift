#if os(macOS)
  import AgentIsolation
  import Foundation
  import Network
  @testable import SOCKSNetwork
  import XCTest

  @MainActor
  final class SOCKS5UDPAssociationTests: XCTestCase {
    private let envelope: [UInt8] = [0, 0, 0, 1, 192, 0, 2, 1, 0, 80]

    func testAuthenticatedAndUnauthenticatedFragmentedRepliesAndPayloadBoundaries() async throws {
      for authenticated in [false, true] {
        let relay = try await MockUDPRelay.start()
        let server = try await MockSOCKSServer.start { peer in
          try await negotiateUDP(peer, relayPort: relay.port, authenticated: authenticated)
          _ = try await peer.read()
        }
        let association = try await SOCKS5UDPAssociation.associate(
          proxy: server.proxy(authenticated: authenticated), destination: "192.0.2.1", port: 80)
        // Back-to-back sends preserve message boundaries, including a zero-byte payload.
        let payloads = [Data(), Data([1]), Data([2, 3, 4]), Data(repeating: 99, count: 1472)]
        for payload in payloads { try await association.send(payload) }
        for payload in payloads {
          let reply = try await receiveBeforeDeadline(association)
          XCTAssertEqual(reply, payload)
        }
        do {
          try await association.send(Data(repeating: 0, count: 1473))
          XCTFail("Accepted oversized UDP payload")
        } catch {
          XCTAssertEqual(error as? SOCKS5Connection.TransportError, .invalidBufferSize)
        }
        // A rejected oversized send does not damage the association.
        try await association.send(Data([7]))
        let reply = try await receiveBeforeDeadline(association)
        XCTAssertEqual(reply, Data([7]))
        await association.close()
        try await server.completed()
        await server.stop()
        await relay.stop()
      }
    }

    func testNumericIPv4IPv6AndWildcardRelayAddresses() async throws {
      for address: [UInt8] in [
        [1, 127, 0, 0, 1], [1, 0, 0, 0, 0],
        [4] + Array(repeating: 0, count: 15) + [1],
      ] {
        let relay = try await MockUDPRelay.start(ipv6: address[0] == 4)
        let server = try await MockSOCKSServer.start { peer in
          try await negotiateUDP(peer, relayPort: relay.port, address: address)
          _ = try await peer.read()
        }
        // Resolve only proxy metadata, never the guest destination. The wildcard
        // case must use the actual TCP peer rather than this configured hostname.
        let proxy = try SOCKS5Proxy(url: "socks5://localhost:\(server.port)")
        let association = try await SOCKS5UDPAssociation.associate(
          proxy: proxy, destination: "192.0.2.1", port: 80)
        try await association.send(Data([8]))
        let reply = try await receiveBeforeDeadline(association)
        XCTAssertEqual(reply, Data([8]))
        await association.close()
        await server.stop()
        await relay.stop()
      }
    }

    func testRejectedCommandAndUnsupportedRelayMetadataFailClosed() async throws {
      let cases: [([UInt8], UInt16, UInt8, SOCKS5Connection.TransportError)] = [
        ([1, 127, 0, 0, 1], 9999, 7, .associateRejected(7)),
        ([1, 127, 0, 0, 1], 0, 0, .unsupportedRelay),
        ([3, 9] + Array("localhost".utf8), 9999, 0, .unsupportedRelay),
        ([4] + Array(repeating: 0, count: 16), 9999, 0, .unsupportedRelay),
      ]
      for (address, port, status, expected) in cases {
        let server = try await MockSOCKSServer.start { peer in
          try await negotiateUDP(peer, relayPort: port, address: address, status: status)
          _ = try await peer.read()
        }
        do {
          _ = try await SOCKS5UDPAssociation.associate(
            proxy: server.proxy(), destination: "192.0.2.1", port: 80)
          XCTFail("Accepted unsupported UDP relay")
        } catch {
          XCTAssertEqual(error as? SOCKS5Connection.TransportError, expected)
        }
        try await server.completed()
        await server.stop()
      }
    }

    func testMultipleAssociationsToSameDestinationUseDifferentRelaySockets() async throws {
      let relay = try await MockUDPRelay.start()
      let server = try await MockSOCKSServer.start { peer in
        try await negotiateUDP(peer, relayPort: relay.port)
        _ = try await peer.read()
      }
      let first = try await SOCKS5UDPAssociation.associate(
        proxy: server.proxy(), destination: "192.0.2.1", port: 80)
      let second = try await SOCKS5UDPAssociation.associate(
        proxy: server.proxy(), destination: "192.0.2.1", port: 80)
      try await first.send(Data([1]))
      try await second.send(Data([2]))
      // Read in reverse order: one shared UDP socket would steal a response.
      let secondReply = try await receiveBeforeDeadline(second)
      let firstReply = try await receiveBeforeDeadline(first)
      XCTAssertEqual(secondReply, Data([2]))
      XCTAssertEqual(firstReply, Data([1]))
      let count = await relay.peerCount
      XCTAssertEqual(count, 2)
      await first.close()
      try await second.send(Data([3]))
      let survivingReply = try await receiveBeforeDeadline(second)
      XCTAssertEqual(survivingReply, Data([3]))
      await second.close()
      await server.stop()
      await relay.stop()
    }

    func testMalformedAndWrongDestinationEnvelopesAreDropped() async throws {
      let header = envelope
      let relay = try await MockUDPRelay.start { data in
        var badAddress = header
        badAddress[7] = 2
        var badPort = header
        badPort[9] = 81
        var fragmented = header
        fragmented[2] = 1
        var reserved = header
        reserved[0] = 1
        return [
          Data([0]), Data(header.dropLast()), Data(badAddress), Data(badPort),
          Data(fragmented), Data(reserved),
          Data([0, 0, 0, 3, 1, 97, 0, 80, 9]),
          Data([0, 0, 0, 4] + Array(repeating: 0, count: 16) + [0, 80, 9]),
          Data(header) + Data(repeating: 1, count: 1473),
          Data(header) + Data(repeating: 1, count: 8_000),
          data,
        ]
      }
      let server = try await MockSOCKSServer.start { peer in
        try await negotiateUDP(peer, relayPort: relay.port)
        _ = try await peer.read()
      }
      let association = try await SOCKS5UDPAssociation.associate(
        proxy: server.proxy(), destination: "192.0.2.1", port: 80)
      try await association.send(Data([42]))
      let reply = try await receiveBeforeDeadline(association)
      XCTAssertEqual(reply, Data([42]))
      // The following valid empty payload must not be interpreted as EOF.
      try await association.send(Data())
      let empty = try await receiveBeforeDeadline(association)
      XCTAssertEqual(empty, Data())
      await association.close()
      await server.stop()
      await relay.stop()
    }

    func testRawEmptyRelayDatagramIsNotAnEmptyGuestPayload() async throws {
      let relay = try await MockUDPRelay.start { [Data(), $0] }
      let server = try await MockSOCKSServer.start { peer in
        try await negotiateUDP(peer, relayPort: relay.port)
        _ = try await peer.read()
      }
      let association = try await SOCKS5UDPAssociation.associate(
        proxy: server.proxy(), destination: "192.0.2.1", port: 80)
      try await association.send(Data([42]))
      do {
        let reply = try await receiveBeforeDeadline(association)
        XCTAssertEqual(reply, Data([42]))
      } catch {
        // macOS Network.framework may report ENODATA after receiving a raw empty
        // UDP datagram. Closing on that transport error is safe; fabricating an
        // empty guest payload from a missing SOCKS header is not.
        XCTAssertEqual(error as? SOCKS5Connection.TransportError, .networkFailure)
      }
      await association.close()
      await server.stop()
      await relay.stop()
    }

    func testControlEOFAndUnexpectedControlBytesStopForwarding() async throws {
      for unexpectedBytes in [false, true] {
        let relay = try await MockUDPRelay.start()
        let trigger = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let server = try await MockSOCKSServer.start { peer in
          try await negotiateUDP(peer, relayPort: relay.port)
          for await _ in trigger.stream { break }
          if unexpectedBytes {
            try await peer.send([42])
          } else {
            try await peer.finish()
          }
        }
        let association = try await SOCKS5UDPAssociation.associate(
          proxy: server.proxy(), destination: "192.0.2.1", port: 80)
        try await association.send(Data([1]))
        let reply = try await receiveBeforeDeadline(association)
        XCTAssertEqual(reply, Data([1]))
        let read = Task { try await receiveBeforeDeadline(association) }
        trigger.continuation.yield(())
        trigger.continuation.finish()
        do {
          let eof = try await read.value
          XCTAssertNil(eof)
        } catch {
          XCTAssertEqual(
            error as? SOCKS5Connection.TransportError,
            unexpectedBytes ? .malformedReply : .closed)
        }
        do {
          try await association.send(Data([2]))
          XCTFail("Forwarded after control shutdown")
        } catch {
          XCTAssertEqual(error as? SOCKS5Connection.TransportError, .closed)
        }
        try await server.completed()
        await association.close()
        await server.stop()
        await relay.stop()
      }
    }

    func testCancellationAndCloseUnblockReceive() async throws {
      for cancel in [false, true] {
        let relay = try await MockUDPRelay.start()
        let server = try await MockSOCKSServer.start { peer in
          try await negotiateUDP(peer, relayPort: relay.port)
          _ = try await peer.read()
        }
        let association = try await SOCKS5UDPAssociation.associate(
          proxy: server.proxy(), destination: "192.0.2.1", port: 80)
        let read = Task { try await receiveBeforeDeadline(association) }
        try await Task.sleep(for: .milliseconds(20))
        if cancel { read.cancel() } else { await association.close() }
        do {
          let eof = try await read.value
          XCTAssertNil(eof)
        } catch {
          XCTAssertTrue(
            error is CancellationError || error as? SOCKS5Connection.TransportError == .closed)
        }
        await association.close()
        try await server.completed()
        await server.stop()
        await relay.stop()
      }
    }

    func testConcurrentReceiveIsRejectedWithoutQueuing() async throws {
      let relay = try await MockUDPRelay.start()
      let server = try await MockSOCKSServer.start { peer in
        try await negotiateUDP(peer, relayPort: relay.port)
        _ = try await peer.read()
      }
      let association = try await SOCKS5UDPAssociation.associate(
        proxy: server.proxy(), destination: "192.0.2.1", port: 80)
      await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<2 {
          group.addTask {
            do {
              _ = try await receiveBeforeDeadline(association)
              return false
            } catch {
              return error as? SOCKS5Connection.TransportError == .concurrentReceive
            }
          }
        }
        let rejected = await group.next()
        XCTAssertEqual(rejected, true)
        await association.close()
      }
      await server.stop()
      await relay.stop()
    }

    func testInvalidDestinationAndZeroPortAreRejectedBeforeDialing() async throws {
      let proxy = try SOCKS5Proxy(url: "socks5://127.0.0.1:1")
      for (host, port): (String, UInt16) in [
        ("example.com", 80), ("::1", 80), ("127.1", 80), ("256.0.0.1", 80),
        ("1.2.3.", 80), (" 1.2.3.4", 80), ("192.0.2.1", 0),
      ] {
        do {
          _ = try await SOCKS5UDPAssociation.associate(proxy: proxy, destination: host, port: port)
          XCTFail("Accepted invalid guest destination")
        } catch {
          XCTAssertEqual(error as? SOCKS5Connection.TransportError, .invalidDestination)
        }
      }
    }

    func testNegotiationTimeoutAndCancellation() async throws {
      for cancel in [false, true] {
        let server = try await MockSOCKSServer.start { peer in
          try await peer.expect([5, 1, 0])
          _ = try await peer.read()
        }
        let proxy = try server.proxy()
        let task = Task {
          try await SOCKS5UDPAssociation.associate(
            proxy: proxy, destination: "192.0.2.1", port: 80,
            timeout: cancel ? .seconds(30) : .milliseconds(100))
        }
        if cancel {
          try await Task.sleep(for: .milliseconds(30))
          task.cancel()
        }
        do {
          _ = try await task.value
          XCTFail("Stalled handshake succeeded")
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
  }

  private func negotiateUDP(
    _ peer: MockPeer, relayPort: UInt16, authenticated: Bool = false,
    address: [UInt8] = [1, 127, 0, 0, 1], status: UInt8 = 0
  ) async throws {
    let method: UInt8 = authenticated ? 2 : 0
    try await peer.expect([5, 1, method])
    try await peer.fragment([5, method])
    if authenticated {
      try await peer.expect([1, 4, 117, 115, 101, 114, 4, 112, 97, 115, 115])
      try await peer.fragment([1, 0])
    }
    try await peer.expect([5, 3, 0, 1, 0, 0, 0, 0, 0, 0])
    try await peer.fragment(
      [5, status, 0] + address + [UInt8(relayPort >> 8), UInt8(relayPort & 255)])
  }

  private func receiveBeforeDeadline(_ association: SOCKS5UDPAssociation) async throws -> Data? {
    try await withThrowingTaskGroup(of: Data?.self) { group in
      group.addTask { try await association.receive() }
      group.addTask {
        try await Task.sleep(for: .seconds(3))
        throw SOCKS5Connection.TransportError.timedOut
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }

  private actor MockUDPRelay {
    nonisolated let port: UInt16
    private let listener: NWListener
    private var peers: [NWConnection] = []
    private var isStopped = false
    var peerCount: Int { peers.count }

    private init(listener: NWListener, port: UInt16) {
      self.listener = listener
      self.port = port
    }

    static func start(
      ipv6: Bool = false,
      replies: @escaping @Sendable (Data) -> [Data] = { [$0] }
    ) async throws -> MockUDPRelay {
      let parameters = NWParameters.udp
      parameters.requiredLocalEndpoint = .hostPort(
        host: ipv6 ? "::1" : "127.0.0.1", port: .any)
      let listener = try NWListener(using: parameters)
      let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
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
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: DispatchQueue(label: "agentc.test.socks.udp.listener"))
      }
      let relay = MockUDPRelay(listener: listener, port: port)
      listener.newConnectionHandler = { connection in
        Task { await relay.accept(connection, replies: replies) }
      }
      return relay
    }

    private func accept(
      _ connection: NWConnection, replies: @escaping @Sendable (Data) -> [Data]
    ) {
      peers.append(connection)
      connection.start(queue: DispatchQueue(label: "agentc.test.socks.udp.peer"))
      Task {
        do {
          while true {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
              connection.receiveMessage { data, _, complete, error in
                if let error {
                  continuation.resume(throwing: error)
                } else if complete {
                  continuation.resume(returning: data ?? Data())
                } else {
                  continuation.resume(throwing: MockError.unexpectedBytes)
                }
              }
            }
            for reply in replies(data) {
              try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(
                  content: reply,
                  completion: .contentProcessed { error in
                    if let error {
                      continuation.resume(throwing: error)
                    } else {
                      continuation.resume()
                    }
                  })
              }
            }
          }
        } catch {
          if !isStopped { XCTFail("Mock UDP relay failed: \(error)") }
          connection.cancel()
        }
      }
    }

    func stop() {
      isStopped = true
      listener.newConnectionHandler = nil
      listener.cancel()
      for peer in peers { peer.cancel() }
      peers.removeAll()
    }
  }
#endif
