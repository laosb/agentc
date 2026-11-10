#if os(macOS)
  import AgentIsolation
  import CSOCKSNetwork
  import Darwin
  import Foundation

  public enum SOCKSNetworkEngine {
    /// Runs exactly once in a private child process. Descriptors are borrowed,
    /// never closed. Any control byte or control EOF terminates the engine.
    public static func run(
      proxy: SOCKS5Proxy, packetFD: Int32, controlFD: Int32, hostMCPPort: UInt16?
    ) async throws {
      let engine = PacketEngine(
        proxy: proxy, packetFD: packetFD,
        controlFD: controlFD, hostMCPPort: hostMCPPort)
      try await engine.run()
    }
  }

  private enum PacketEngineError: Error {
    case system(Int32)
    case alreadyInitialized
    case invalidHostMCPPort
    case stopped
    case invalidDNS
  }

  /// Every lwIP entry point (including timers and callbacks) executes on this
  /// actor. Network awaits are reentrant; no raw pointer crosses an await.
  private actor PacketEngine {
    private struct Flow {
      let tuple: Packet.Tuple
      let generation: UInt64
      let created: ContinuousClock.Instant
      var activity: ContinuousClock.Instant
      var retired: ContinuousClock.Instant?
      var started = false
      var connected = false
      var upstreamFinished = false
      var downstreamFinished = false
      var connection: SOCKS5Connection?
      var tasks: [Task<Void, Never>] = []
    }

    private struct DNSJob {
      let created: ContinuousClock.Instant
      let task: Task<Void, Never>
      var connection: SOCKS5Connection?
    }

    private let proxy: SOCKS5Proxy
    private let packetFD: Int32
    private let controlFD: Int32
    private let hostMCPPort: UInt16?
    private let output = LWIPOutput()
    private let clock = ContinuousClock()
    private var flows: [UInt32: Flow] = [:]
    private var tuples: [Packet.Tuple: UInt32] = [:]
    private var dns: [UInt64: DNSJob] = [:]
    private var serial: UInt64 = 0
    private var stopped = false

    init(proxy: SOCKS5Proxy, packetFD: Int32, controlFD: Int32, hostMCPPort: UInt16?) {
      self.proxy = proxy
      self.packetFD = packetFD
      self.controlFD = controlFD
      self.hostMCPPort = hostMCPPort
    }

    func run() async throws {
      guard hostMCPPort != 0 && hostMCPPort != 53 else {
        throw PacketEngineError.invalidHostMCPPort
      }
      let packetFlags = fcntl(packetFD, F_GETFL)
      let controlFlags = fcntl(controlFD, F_GETFL)
      guard packetFlags >= 0, controlFlags >= 0 else { throw PacketEngineError.system(errno) }
      guard fcntl(packetFD, F_SETFL, packetFlags | O_NONBLOCK) == 0 else {
        throw PacketEngineError.system(errno)
      }
      defer { _ = fcntl(packetFD, F_SETFL, packetFlags) }
      guard fcntl(controlFD, F_SETFL, controlFlags | O_NONBLOCK) == 0 else {
        throw PacketEngineError.system(errno)
      }
      defer { _ = fcntl(controlFD, F_SETFL, controlFlags) }
      var one: Int32 = 1
      guard
        setsockopt(
          packetFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
          == 0,
        setsockopt(
          controlFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
          == 0
      else { throw PacketEngineError.system(errno) }
      guard output.initialize() else { throw PacketEngineError.alreadyInitialized }
      defer { shutdown() }
      // One byte only, after the stack and both nonblocking channels are ready.
      var ready: UInt8 = 1
      guard Darwin.send(controlFD, &ready, 1, 0) == 1 else {
        throw PacketEngineError.system(errno)
      }
      var buffer = [UInt8](repeating: 0, count: 1515)
      while !Task.isCancelled {
        var control: UInt8 = 0
        let count = Darwin.recv(controlFD, &control, 1, 0)
        if count >= 0 { return }
        if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
          throw PacketEngineError.system(errno)
        }
        // Work per turn is bounded so a saturated guest cannot starve control
        // EOF, cancellation, timers, or the proxy socket completion tasks.
        for _ in 0..<64 {
          let count = buffer.withUnsafeMutableBytes {
            Darwin.recv(packetFD, $0.baseAddress, $0.count, 0)
          }
          if count < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { break }
            throw PacketEngineError.system(errno)
          }
          if count <= 1514 { process(Array(buffer.prefix(count))) }
        }
        agentc_lwip_tick()
        maintain()
        try flush()
        try await Task.sleep(for: .milliseconds(5))
      }
    }

    private func process(_ bytes: [UInt8]) {
      guard let packet = Packet.inbound(bytes) else { return }
      switch packet {
      case .arp(let frame):
        LWIPOutput.input(frame)
      case .tcp(let frame, let tuple, let syn):
        var slot = tuples[tuple]
        if slot == nil && syn {
          guard let available = (UInt32(0)..<128).first(where: { flows[$0] == nil }),
            agentc_lwip_listen(available, localPort(available)) != 0
          else { return }
          serial &+= 1
          let now = clock.now
          flows[available] = Flow(tuple: tuple, generation: serial, created: now, activity: now)
          tuples[tuple] = available
          slot = available
        }
        guard let slot, flows[slot]?.retired == nil else { return }
        // Keep mappings through TIME_WAIT; never reopen the same translated
        // port while lwIP or the bounded output queue can still reference it.
        flows[slot]?.activity = clock.now
        LWIPOutput.input(Packet.translatedInbound(frame, localPort: localPort(slot)))
      case .dns(let query):
        guard dns.count < 32 else { return }
        serial &+= 1
        let id = serial
        let task = Task { await self.resolve(query, id: id) }
        dns[id] = DNSJob(created: clock.now, task: task)
      }
    }

    private func localPort(_ slot: UInt32) -> UInt16 { UInt16(20000 + slot) }

    private func flush() throws {
      for _ in 0..<256 {
        guard let frame = output.next else { return }
        var translated = frame
        if frame.count >= 54 && Packet.u16(frame, 12) == 0x0800 && frame[23] == 6 {
          let port = Packet.u16(frame, 34)
          guard port >= 20000, port < 20128,
            let flow = flows[UInt32(port - 20000)],
            let packet = Packet.translatedOutbound(frame, tuple: flow.tuple)
          else {
            output.removeFirst()
            continue
          }
          translated = packet
        }
        let sent = translated.withUnsafeBytes {
          Darwin.send(packetFD, $0.baseAddress, $0.count, 0)
        }
        if sent < 0 {
          // Darwin's connected AF_UNIX datagram socket can report ENOBUFS
          // rather than EAGAIN when the peer's receive queue is full.
          if errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS || errno == EINTR {
            return
          }
          throw PacketEngineError.system(errno)
        }
        guard sent == translated.count else { throw PacketEngineError.system(EIO) }
        output.removeFirst()
      }
    }

    private func maintain() {
      let now = clock.now
      for slot in Array(flows.keys) {
        guard let flow = flows[slot] else { continue }
        let state = agentc_lwip_state(slot)
        if flow.retired != nil {
          // The PCB destructor already includes lwIP's TIME_WAIT lifetime.
          // Waiting a second 2MSL here would needlessly exhaust the slot pool.
          // Drain old queued packets before reusing a translated source port.
          if state == 0 && !output.containsTCP(sourcePort: localPort(slot)) {
            tuples.removeValue(forKey: flow.tuple)
            flows.removeValue(forKey: slot)
          }
          continue
        }
        if state == 0
          || (!flow.connected && flow.created.duration(to: now) > .seconds(20))
          || flow.activity.duration(to: now) > .seconds(3600)
        {
          retire(slot)
        } else if state == 2 && !flow.started {
          flows[slot]?.started = true
          let task = Task { await self.connect(slot: slot, generation: flow.generation) }
          flows[slot]?.tasks.append(task)
        }
      }
      for (id, job) in dns where job.created.duration(to: now) > .seconds(15) {
        job.task.cancel()
        if let connection = job.connection { Task { await connection.close() } }
        dns.removeValue(forKey: id)
      }
    }

    private func active(_ slot: UInt32, _ generation: UInt64) -> Bool {
      let state = agentc_lwip_state(slot)
      return !stopped && flows[slot]?.generation == generation
        && flows[slot]?.retired == nil && (state == 2 || state == 4)
    }

    private func connect(slot: UInt32, generation: UInt64) async {
      guard let flow = flows[slot], active(slot, generation) else { return }
      do {
        let connection: SOCKS5Connection
        if flow.tuple.destination == Packet.gateway,
          let hostMCPPort, flow.tuple.destinationPort == hostMCPPort
        {
          connection = try await SOCKS5Connection.connectHostMCP(port: hostMCPPort)
        } else {
          // The gateway is a DNS service, not a literal upstream host. TCP
          // fallback after a truncated UDP answer uses the same fixed resolver.
          let destination =
            flow.tuple.destination == Packet.gateway
              && flow.tuple.destinationPort == 53 ? "1.1.1.1" : flow.tuple.address
          connection = try await SOCKS5Connection.connect(
            proxy: proxy, destination: destination, port: flow.tuple.destinationPort)
        }
        guard active(slot, generation), !Task.isCancelled else {
          await connection.close()
          return
        }
        flows[slot]?.connected = true
        flows[slot]?.connection = connection
        let up = Task { await self.upload(slot, generation, connection) }
        let down = Task { await self.download(slot, generation, connection) }
        flows[slot]?.tasks.append(contentsOf: [up, down])
      } catch {
        if active(slot, generation) { retire(slot) }
      }
    }

    private func upload(_ slot: UInt32, _ generation: UInt64, _ connection: SOCKS5Connection) async
    {
      do {
        while active(slot, generation) && !Task.isCancelled {
          let data = LWIPOutput.read(slot: slot)
          if !data.isEmpty {
            try await connection.send(data)
            guard active(slot, generation) else { return }
            agentc_lwip_consume(slot, data.count)
            flows[slot]?.activity = clock.now
          } else if agentc_lwip_eof(slot) != 0 {
            try await connection.finishSending()
            guard active(slot, generation) else { return }
            flows[slot]?.upstreamFinished = true
            finishIfComplete(slot)
            return
          } else {
            try await Task.sleep(for: .milliseconds(5))
          }
        }
      } catch {
        if active(slot, generation) { retire(slot) }
      }
    }

    private func download(_ slot: UInt32, _ generation: UInt64, _ connection: SOCKS5Connection)
      async
    {
      do {
        while active(slot, generation) && !Task.isCancelled {
          // Never pull another proxy chunk until lwIP has acknowledged-window
          // space. At most one 16 KiB chunk is held outside its bounded sndbuf.
          guard agentc_lwip_send_capacity(slot) >= 16384 else {
            try await Task.sleep(for: .milliseconds(5))
            continue
          }
          guard let data = try await connection.receive(maximum: 16384) else {
            while active(slot, generation) && agentc_lwip_finish(slot) == 0 {
              try await Task.sleep(for: .milliseconds(5))
            }
            guard active(slot, generation) else { return }
            flows[slot]?.downstreamFinished = true
            finishIfComplete(slot)
            return
          }
          guard !data.isEmpty, data.count <= 16384 else { throw PacketEngineError.stopped }
          while active(slot, generation) && !LWIPOutput.write(slot: slot, data: data) {
            try await Task.sleep(for: .milliseconds(5))
          }
          guard active(slot, generation) else { return }
          flows[slot]?.activity = clock.now
        }
      } catch {
        if active(slot, generation) { retire(slot) }
      }
    }

    private func finishIfComplete(_ slot: UInt32) {
      guard let flow = flows[slot], flow.upstreamFinished, flow.downstreamFinished else { return }
      agentc_lwip_release(slot)
      if let connection = flow.connection { Task { await connection.close() } }
      flows[slot]?.connection = nil
      // The ext-arg destruction callback, not close(), decides when lwIP no
      // longer owns this PCB. maintain() observes that callback through state().
    }

    private func retire(_ slot: UInt32) {
      guard let flow = flows[slot], flow.retired == nil else { return }
      for task in flow.tasks { task.cancel() }
      if let connection = flow.connection { Task { await connection.close() } }
      agentc_lwip_abort(slot)
      flows[slot]?.connection = nil
      flows[slot]?.tasks = []
      flows[slot]?.retired = clock.now
    }

    private func resolve(_ query: Packet.DNSQuery, id: UInt64) async {
      var connection: SOCKS5Connection?
      do {
        let socket = try await SOCKS5Connection.connect(
          proxy: proxy, destination: "1.1.1.1", port: 53)
        connection = socket
        guard !stopped, dns[id] != nil, !Task.isCancelled else {
          await socket.close()
          return
        }
        dns[id]?.connection = socket
        var framed = [UInt8](repeating: 0, count: 2)
        Packet.put16(UInt16(query.message.count), &framed, 0)
        framed += query.message
        try await socket.send(Data(framed))
        let prefix = try await Self.readExactly(2, from: socket)
        let count = Int(Packet.u16(prefix, 0))
        guard count >= 12 else { throw PacketEngineError.invalidDNS }
        let answer = try await Self.readExactly(count, from: socket)
        if !stopped, dns[id] != nil, !Task.isCancelled, let frame = query.response(answer) {
          output.append(frame)
        }
      } catch {
        // Fail closed. The guest retries/times out; never consult a host resolver.
      }
      if let connection { await connection.close() }
      dns.removeValue(forKey: id)
    }

    private nonisolated static func readExactly(_ count: Int, from socket: SOCKS5Connection)
      async throws -> [UInt8]
    {
      var bytes: [UInt8] = []
      bytes.reserveCapacity(count)
      while bytes.count < count {
        try Task.checkCancellation()
        guard let chunk = try await socket.receive(maximum: count - bytes.count),
          !chunk.isEmpty, chunk.count <= count - bytes.count
        else { throw PacketEngineError.invalidDNS }
        bytes.append(contentsOf: chunk)
      }
      return bytes
    }

    private func shutdown() {
      stopped = true
      for slot in Array(flows.keys) { retire(slot) }
      for job in dns.values {
        job.task.cancel()
        if let connection = job.connection { Task { await connection.close() } }
      }
      dns.removeAll()
    }
  }
#endif
