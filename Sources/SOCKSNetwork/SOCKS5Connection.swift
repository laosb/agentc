#if os(macOS)
  import AgentIsolation
  import Foundation
  import Network

  /// Host-side TCP transport. Normal connections only dial the configured proxy.
  ///
  /// Cancellation or a timed-out operation closes the entire transport: a partially
  /// written SOCKS message or stream write cannot safely be retried. Reads have no
  /// idle timeout after negotiation, so idle tunnels remain usable.
  public actor SOCKS5Connection {
    public enum TransportError: Error, Sendable, Equatable {
      case invalidConfiguration
      case invalidDestination
      case invalidBufferSize
      case concurrentReceive
      case concurrentSend
      case closed
      case sendingFinished
      case timedOut
      case networkFailure
      case unexpectedEOF
      case malformedReply
      case authenticationRejected
      case connectRejected(UInt8)
      case associateRejected(UInt8)
      case unsupportedRelay
    }

    /// Each call to send/receive is bounded to this many bytes.
    public static let maximumBufferSize = 64 * 1024
    private static let operationTimeout: Duration = .seconds(30)

    private let connection: NWConnection
    private let timeout: Duration
    private var isClosed = false
    private var receivedEOF = false
    private var sentEOF = false
    private var ready: (UUID, CheckedContinuation<Void, any Error>)?
    private var writer: (UUID, CheckedContinuation<Void, any Error>)?
    private var reader: (UUID, CheckedContinuation<Data?, any Error>)?
    private var timers: [UUID: Task<Void, Never>] = [:]

    private init(host: String, port: UInt16, timeout: Duration) {
      connection = NWConnection(
        host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
      self.timeout = timeout
    }

    deinit {
      connection.cancel()
      for timer in timers.values { timer.cancel() }
    }

    public static func connect(
      proxy: SOCKS5Proxy, destination: String, port: UInt16
    ) async throws -> SOCKS5Connection {
      try await connect(
        proxy: proxy, destination: destination, port: port, timeout: operationTimeout)
    }

    // Internal timeout injection keeps timeout tests fast without adding public policy knobs.
    static func connect(
      proxy: SOCKS5Proxy, destination: String, port: UInt16, timeout: Duration
    ) async throws -> SOCKS5Connection {
      let address = try ipv4Bytes(destination)
      guard port != 0 else { throw TransportError.invalidDestination }
      let (transport, _) = try await establish(
        proxy: proxy, command: .connect, address: address, port: port, timeout: timeout)
      return transport
    }

    private enum Command: UInt8 {
      case connect = 1
      case associate = 3
    }

    private struct BoundAddress: Sendable {
      let type: UInt8
      let bytes: [UInt8]
      let port: UInt16
    }

    /// Both commands share credential validation, authentication, deadlines and reply parsing.
    private static func establish(
      proxy: SOCKS5Proxy, command: Command, address: [UInt8], port: UInt16, timeout: Duration
    ) async throws -> (SOCKS5Connection, BoundAddress) {
      guard !proxy.host.isEmpty, !proxy.host.contains("\0"), proxy.port != 0,
        (proxy.username == nil) == (proxy.password == nil)
      else { throw TransportError.invalidConfiguration }
      for credential in [proxy.username, proxy.password].compactMap({ $0 }) {
        guard (1...255).contains(credential.utf8.count) else {
          throw TransportError.invalidConfiguration
        }
      }
      let transport = SOCKS5Connection(host: proxy.host, port: proxy.port, timeout: timeout)
      do {
        try await transport.start()
        let bound = try await transport.negotiate(
          proxy: proxy, command: command, address: address, port: port)
        try Task.checkCancellation()
        return (transport, bound)
      } catch {
        await transport.close()
        throw error
      }
    }

    static func associateUDP(
      proxy: SOCKS5Proxy, timeout: Duration
    ) async throws -> (SOCKS5Connection, NWEndpoint.Host, UInt16) {
      // The UDP socket's local address is not known yet. RFC 1928 permits all zeros.
      let (transport, bound) = try await establish(
        proxy: proxy, command: .associate, address: [0, 0, 0, 0], port: 0, timeout: timeout)
      do {
        guard bound.port != 0 else { throw TransportError.unsupportedRelay }
        let host = try await transport.relayHost(bound)
        try Task.checkCancellation()
        return (transport, host, bound.port)
      } catch {
        await transport.close()
        throw error
      }
    }

    private func relayHost(_ bound: BoundAddress) throws -> NWEndpoint.Host {
      if bound.type == 1, bound.bytes.allSatisfy({ $0 == 0 }) {
        // Never resolve the guest address or re-resolve the proxy's configured name.
        // Use the numeric endpoint of the TCP connection that authenticated us.
        guard case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint else {
          throw TransportError.unsupportedRelay
        }
        switch host {
        case .ipv4, .ipv6: return host
        default: throw TransportError.unsupportedRelay
        }
      }
      switch bound.type {
      case 1:
        guard let address = IPv4Address(Data(bound.bytes)) else {
          throw TransportError.unsupportedRelay
        }
        return .ipv4(address)
      case 4:
        guard !bound.bytes.allSatisfy({ $0 == 0 }),
          let address = IPv6Address(Data(bound.bytes))
        else { throw TransportError.unsupportedRelay }
        return .ipv6(address)
      default:
        // Domain relay metadata is deliberately unsupported; guest input is never DNS input.
        throw TransportError.unsupportedRelay
      }
    }

    /// The only direct-connect exception: the explicitly authorized host MCP bridge.
    public static func connectHostMCP(port: UInt16) async throws -> SOCKS5Connection {
      guard port != 0 else { throw TransportError.invalidDestination }
      let transport = SOCKS5Connection(
        host: "127.0.0.1", port: port, timeout: operationTimeout)
      do {
        try await transport.start()
        try Task.checkCancellation()
        return transport
      } catch {
        await transport.close()
        throw error
      }
    }

    /// Exactly one send (including finishSending) may be outstanding.
    public func send(_ data: Data) async throws {
      guard data.count <= Self.maximumBufferSize else {
        throw TransportError.invalidBufferSize
      }
      try await write(data, final: false)
    }

    /// Returns at most `maximum` bytes, or nil once the peer has closed its write side.
    /// A second concurrent receive fails rather than sharing or stealing stream bytes.
    public func receive(maximum: Int) async throws -> Data? {
      try await read(maximum: maximum, timed: false)
    }

    public func finishSending() async throws {
      try await write(nil, final: true)
    }

    public func close() {
      terminate(with: TransportError.closed)
    }

    private func start() async throws {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
          let id = UUID()
          ready = (id, continuation)
          armTimeout(id)
          connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.stateChanged(state) }
          }
          connection.start(queue: DispatchQueue(label: "agentc.socks5"))
        }
      } onCancel: {
        Task { await self.terminate(with: CancellationError()) }
      }
    }

    private func stateChanged(_ state: NWConnection.State) {
      // State updates only complete establishment. Once ready, each I/O callback
      // owns its result. In particular, Network.framework can report a failed
      // state after both FINs while a successful final receive/EOF is still queued.
      // Failing that receive from a state update would discard valid stream data.
      guard ready != nil else { return }
      switch state {
      case .ready:
        if let (id, continuation) = ready {
          ready = nil
          disarmTimeout(id)
          continuation.resume()
        }
      case .failed, .waiting:
        terminate(with: TransportError.networkFailure)
      case .cancelled:
        terminate(with: TransportError.closed)
      default:
        break
      }
    }

    private func write(_ data: Data?, final: Bool) async throws {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        guard !isClosed else { throw TransportError.closed }
        guard writer == nil else { throw TransportError.concurrentSend }
        guard !sentEOF else { throw TransportError.sendingFinished }
        if final { sentEOF = true }
        try await withCheckedThrowingContinuation { continuation in
          let id = UUID()
          writer = (id, continuation)
          armTimeout(id)
          // contentProcessed completes only after the entire content was processed;
          // NWConnection handles partial kernel writes and TCP backpressure.
          connection.send(
            content: data, contentContext: final ? .finalMessage : .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
              Task { await self?.writeCompleted(id: id, failed: error != nil) }
            })
        }
      } onCancel: {
        Task { await self.terminate(with: CancellationError()) }
      }
    }

    private func writeCompleted(id: UUID, failed: Bool) {
      guard let (pendingID, continuation) = writer, pendingID == id else { return }
      if failed {
        terminate(with: TransportError.networkFailure)
      } else {
        writer = nil
        disarmTimeout(id)
        continuation.resume()
      }
    }

    private func read(maximum: Int, timed: Bool) async throws -> Data? {
      guard (1...Self.maximumBufferSize).contains(maximum) else {
        throw TransportError.invalidBufferSize
      }
      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        guard !isClosed else { throw TransportError.closed }
        guard reader == nil else { throw TransportError.concurrentReceive }
        if receivedEOF { return nil }
        return try await withCheckedThrowingContinuation { continuation in
          let id = UUID()
          reader = (id, continuation)
          if timed { armTimeout(id) }
          connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) {
            [weak self] data, _, complete, error in
            Task {
              await self?.readCompleted(
                id: id, data: data, complete: complete, failed: error != nil)
            }
          }
        }
      } onCancel: {
        Task { await self.terminate(with: CancellationError()) }
      }
    }

    private func readCompleted(id: UUID, data: Data?, complete: Bool, failed: Bool) {
      guard let (pendingID, continuation) = reader, pendingID == id else { return }
      if failed {
        terminate(with: TransportError.networkFailure)
        return
      }
      // With minimumIncompleteLength=1, empty data is only valid at EOF.
      guard complete || !(data?.isEmpty ?? true) else {
        terminate(with: TransportError.networkFailure)
        return
      }
      reader = nil
      disarmTimeout(id)
      receivedEOF = complete
      continuation.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 })
    }

    private func armTimeout(_ id: UUID) {
      timers[id] = Task { [weak self, timeout] in
        do { try await Task.sleep(for: timeout) } catch { return }
        await self?.expire(id)
      }
    }

    private func disarmTimeout(_ id: UUID) {
      timers.removeValue(forKey: id)?.cancel()
    }

    private func expire(_ id: UUID) {
      guard timers[id] != nil else { return }
      terminate(with: TransportError.timedOut)
    }

    private func terminate(with error: any Error) {
      guard !isClosed else { return }
      isClosed = true
      connection.stateUpdateHandler = nil
      connection.cancel()
      for timer in timers.values { timer.cancel() }
      timers.removeAll()
      let pendingReady = ready
      let pendingWriter = writer
      let pendingReader = reader
      ready = nil
      writer = nil
      reader = nil
      pendingReady?.1.resume(throwing: error)
      pendingWriter?.1.resume(throwing: error)
      pendingReader?.1.resume(throwing: error)
    }

    private func readExactly(_ count: Int) async throws -> [UInt8] {
      var bytes: [UInt8] = []
      while bytes.count < count {
        guard let data = try await read(maximum: count - bytes.count, timed: true) else {
          throw TransportError.unexpectedEOF
        }
        bytes.append(contentsOf: data)
      }
      return bytes
    }

    private func negotiate(
      proxy: SOCKS5Proxy, command: Command, address: [UInt8], port: UInt16
    ) async throws -> BoundAddress {
      // A single overall negotiation deadline also bounds a slow trickle of bytes.
      let negotiationID = UUID()
      armTimeout(negotiationID)
      defer { disarmTimeout(negotiationID) }
      let method: UInt8 = proxy.username == nil ? 0 : 2
      // Offer exactly one method, never downgrade supplied credentials to no-auth.
      try await send(Data([5, 1, method]))
      let selection = try await readExactly(2)
      guard selection[0] == 5 else { throw TransportError.malformedReply }
      guard selection[1] == method else { throw TransportError.authenticationRejected }
      if let username = proxy.username, let password = proxy.password {
        let user = Array(username.utf8)
        let pass = Array(password.utf8)
        try await send(Data([1, UInt8(user.count)] + user + [UInt8(pass.count)] + pass))
        let reply = try await readExactly(2)
        guard reply[0] == 1 else { throw TransportError.malformedReply }
        guard reply[1] == 0 else { throw TransportError.authenticationRejected }
      }
      try await send(
        Data([5, command.rawValue, 0, 1] + address + [UInt8(port >> 8), UInt8(port & 255)]))
      let reply = try await readExactly(4)
      guard reply[0] == 5, reply[2] == 0 else { throw TransportError.malformedReply }
      let bytes: [UInt8]
      switch reply[3] {
      case 1:
        bytes = try await readExactly(4)
      case 4:
        bytes = try await readExactly(16)
      case 3:
        let length = Int(try await readExactly(1)[0])
        guard length > 0 else { throw TransportError.malformedReply }
        bytes = try await readExactly(length)
      default:
        throw TransportError.malformedReply
      }
      let boundPort = try await readExactly(2)
      guard reply[1] == 0 else {
        throw command == .connect
          ? TransportError.connectRejected(reply[1]) : TransportError.associateRejected(reply[1])
      }
      return BoundAddress(
        type: reply[3], bytes: bytes, port: UInt16(boundPort[0]) << 8 | UInt16(boundPort[1]))
    }

    static func ipv4Bytes(_ destination: String) throws -> [UInt8] {
      // Reject names, IPv6, shorthand and non-ASCII input before opening a socket.
      guard destination.utf8.count <= 15 else { throw TransportError.invalidDestination }
      let parts = destination.split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count == 4 else { throw TransportError.invalidDestination }
      return try parts.map { part in
        guard (1...3).contains(part.utf8.count),
          part.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt8(part)
        else { throw TransportError.invalidDestination }
        return value
      }
    }
  }
#endif
