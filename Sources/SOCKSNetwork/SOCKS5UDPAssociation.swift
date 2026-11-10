#if os(macOS)
  import AgentIsolation
  import Foundation
  import Network

  /// A single fixed-destination UDP flow, with its own authenticated TCP control
  /// connection and connected UDP socket. Never shares a relay socket between guest
  /// tuples: SOCKS reply envelopes do not identify the original guest source port.
  ///
  /// At most one send and one receive may be outstanding. Cancellation, control
  /// shutdown or a write timeout closes the whole association. There is no idle
  /// receive timeout or application-side datagram queue.
  public actor SOCKS5UDPAssociation {
    public static let maximumPayloadSize = 1472
    public typealias TransportError = SOCKS5Connection.TransportError

    private let control: SOCKS5Connection
    private let connection: NWConnection
    private let header: Data
    private let timeout: Duration
    private var isClosed = false
    private var ready: (UUID, CheckedContinuation<Void, any Error>)?
    private var writer: (UUID, CheckedContinuation<Void, any Error>)?
    private var reader: (UUID, CheckedContinuation<Data?, any Error>)?
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var monitor: Task<Void, Never>?

    private init(
      control: SOCKS5Connection, relay: NWEndpoint.Host, relayPort: UInt16,
      address: [UInt8], port: UInt16, timeout: Duration
    ) {
      self.control = control
      self.timeout = timeout
      header = Data([0, 0, 0, 1] + address + [UInt8(port >> 8), UInt8(port & 255)])
      // Connecting to the negotiated numeric endpoint filters packets from other
      // sources. The encapsulated source is checked separately against `header`.
      connection = NWConnection(
        host: relay, port: NWEndpoint.Port(rawValue: relayPort)!, using: .udp)
    }

    deinit {
      connection.cancel()
      monitor?.cancel()
      for timer in timers.values { timer.cancel() }
      let control = control
      Task { await control.close() }
    }

    public static func associate(
      proxy: SOCKS5Proxy, destination: String, port: UInt16
    ) async throws -> SOCKS5UDPAssociation {
      try await associate(proxy: proxy, destination: destination, port: port, timeout: .seconds(30))
    }

    // Internal injection for deadline tests; not a user-configurable transport policy.
    static func associate(
      proxy: SOCKS5Proxy, destination: String, port: UInt16, timeout: Duration
    ) async throws -> SOCKS5UDPAssociation {
      let address = try SOCKS5Connection.ipv4Bytes(destination)
      guard port != 0 else { throw TransportError.invalidDestination }
      let (control, relay, relayPort) = try await SOCKS5Connection.associateUDP(
        proxy: proxy, timeout: timeout)
      let association = SOCKS5UDPAssociation(
        control: control, relay: relay, relayPort: relayPort, address: address, port: port,
        timeout: timeout)
      do {
        try await association.start()
        try Task.checkCancellation()
        return association
      } catch {
        await association.close()
        throw error
      }
    }

    public func send(_ payload: Data) async throws {
      guard payload.count <= Self.maximumPayloadSize else {
        throw TransportError.invalidBufferSize
      }
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        guard !isClosed else { throw TransportError.closed }
        guard writer == nil else { throw TransportError.concurrentSend }
        try await withCheckedThrowingContinuation { continuation in
          let id = UUID()
          writer = (id, continuation)
          armTimeout(id)
          connection.send(
            content: header + payload, contentContext: .defaultMessage, isComplete: true,
            completion: .contentProcessed { [weak self] error in
              Task { await self?.writeCompleted(id: id, failed: error != nil) }
            })
        }
      } onCancel: {
        Task { await self.terminate(with: CancellationError()) }
      }
    }

    /// Empty Data is a valid UDP payload; nil means this association has closed.
    /// Invalid, fragmented, oversized and wrong-destination envelopes are dropped.
    public func receive() async throws -> Data? {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        guard !isClosed else { return nil }
        guard reader == nil else { throw TransportError.concurrentReceive }
        return try await withCheckedThrowingContinuation { continuation in
          let id = UUID()
          reader = (id, continuation)
          receiveDatagram(id: id)
        }
      } onCancel: {
        Task { await self.terminate(with: CancellationError()) }
      }
    }

    public func close() {
      terminate(with: TransportError.closed)
    }

    private func start() async throws {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        guard !isClosed else { throw TransportError.closed }
        try await withCheckedThrowingContinuation { continuation in
          let id = UUID()
          ready = (id, continuation)
          armTimeout(id)
          monitor = Task { [weak self, control] in
            do {
              let unexpected = try await control.receive(maximum: 1)
              await self?.terminate(
                with: unexpected == nil ? TransportError.closed : TransportError.malformedReply)
            } catch {
              await self?.terminate(with: error)
            }
          }
          connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.stateChanged(state) }
          }
          connection.start(queue: DispatchQueue(label: "agentc.socks5.udp"))
        }
      } onCancel: {
        Task { await self.terminate(with: CancellationError()) }
      }
    }

    private func stateChanged(_ state: NWConnection.State) {
      guard !isClosed else { return }
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

    private func receiveDatagram(id: UUID) {
      // receiveMessage preserves datagram boundaries, including empty payloads.
      // UDP itself bounds this allocation to one wire datagram (<= 65,535 bytes).
      // Only one callback is outstanding; no Task/actor backlog or retained queue
      // is created by a flood of invalid datagrams. Accepted payloads are <= 1472.
      connection.receiveMessage { [weak self] data, _, complete, error in
        Task {
          await self?.readCompleted(id: id, data: data, complete: complete, failed: error != nil)
        }
      }
    }

    private func readCompleted(id: UUID, data: Data?, complete: Bool, failed: Bool) {
      guard let (pendingID, continuation) = reader, pendingID == id else { return }
      if failed {
        // Some Network.framework versions report ENODATA after an empty *wire*
        // datagram. That is not a valid SOCKS envelope; fail closed on the transport
        // error rather than turn it into guest EOF or a valid empty guest payload.
        terminate(with: TransportError.networkFailure)
        return
      }
      guard complete, let data,
        (header.count...(header.count + Self.maximumPayloadSize)).contains(data.count),
        data.starts(with: header)
      else {
        // Matching the entire fixed header validates RSV, FRAG, ATYP, IPv4 and port.
        // Each invalid packet costs one bounded callback, then gives up the executor.
        receiveDatagram(id: id)
        return
      }
      reader = nil
      continuation.resume(returning: Data(data.dropFirst(header.count)))
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
      monitor?.cancel()
      monitor = nil
      Task { await control.close() }
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
  }
#endif
