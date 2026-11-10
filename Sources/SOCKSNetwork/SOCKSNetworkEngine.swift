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
    private enum WaitReason {
      case upload, capacity, retry
    }

    private struct Waiter {
      let reason: WaitReason
      let continuation: CheckedContinuation<Void, Never>
    }

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
      var uploadWaiter: Waiter?
      var downloadWaiter: Waiter?
    }

    private struct DNSJob {
      let created: ContinuousClock.Instant
      let task: Task<Void, Never>
      var connection: SOCKS5Connection?
    }

    private struct UDPFlow {
      let generation: UInt64
      let created: ContinuousClock.Instant
      var activity: ContinuousClock.Instant
      var association: SOCKS5UDPAssociation?
      // At most eight waiting datagrams plus one in-flight send per flow.
      var pending: [Data]
      var connecting: Task<Void, Never>?
      var sending: Task<Void, Never>?
      var receiving: Task<Void, Never>?
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
    private var udpFlows: [Packet.Tuple: UDPFlow] = [:]
    private var udpUnavailableUntil: ContinuousClock.Instant?
    private var serial: UInt64 = 0
    private var stopped = false
    private var wakeups: PacketEngineWakeups?
    private var progress: UInt64 = 0

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
      let wakeups = PacketEngineWakeups(packetFD: packetFD, controlFD: controlFD)
      self.wakeups = wakeups
      defer { self.wakeups = nil }
      do {
        wakeups.armReads()
        // One byte only, after the stack and both nonblocking channels are ready.
        var ready: UInt8 = 1
        guard Darwin.send(controlFD, &ready, 1, 0) == 1 else {
          throw PacketEngineError.system(errno)
        }
        try await withTaskCancellationHandler {
          try await eventLoop(wakeups)
        } onCancel: {
          // Finishing the mailbox wakes a quiet engine, even without any FD input.
          wakeups.stop()
        }
      } catch {
        await shutdown()
        throw error
      }
      await shutdown()
    }

    private func eventLoop(_ wakeups: PacketEngineWakeups) async throws {
      var buffer = [UInt8](repeating: 0, count: 1515)
      for await _ in wakeups.stream {
        guard !Task.isCancelled else { return }
        let events = wakeups.takeEvents()
        var control: UInt8 = 0
        let count = Darwin.recv(controlFD, &control, 1, 0)
        if count >= 0 { return }
        if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
          throw PacketEngineError.system(errno)
        }
        // Work per turn is bounded so a saturated guest cannot starve control
        // EOF, cancellation, timers, or the proxy socket completion tasks.
        var inputProgress = false
        for _ in 0..<64 {
          let count = buffer.withUnsafeMutableBytes {
            Darwin.recv(packetFD, $0.baseAddress, $0.count, 0)
          }
          if count < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            throw PacketEngineError.system(errno)
          }
          inputProgress = true
          if count <= 1514 { process(Array(buffer.prefix(count))) }
        }
        // Rearming level readiness reschedules a bounded turn if the input
        // budget was exhausted; neither descriptor is polled while idle.
        wakeups.armReads()
        if events.contains(.timer) { agentc_lwip_tick() }
        maintain()
        resumeWaiters(retry: inputProgress || events.contains(.timer))
        try flush()
        // next() can complete synchronously when the mailbox is already full.
        // Explicitly yield so sustained packet input cannot monopolize the actor.
        await Task.yield()
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
      case .udp(let datagram):
        enqueue(datagram)
      }
    }

    private func localPort(_ slot: UInt32) -> UInt16 { UInt16(20000 + slot) }

    private func flush() throws {
      for _ in 0..<256 {
        guard let frame = output.next else {
          wakeups?.outputDrained()
          return
        }
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
            wakeups?.outputBlocked()
            return
          }
          throw PacketEngineError.system(errno)
        }
        guard sent == translated.count else { throw PacketEngineError.system(EIO) }
        output.removeFirst()
      }
      if output.next != nil {
        wakeups?.signal()
      } else {
        wakeups?.outputDrained()
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
      for (tuple, flow) in udpFlows {
        if (flow.association == nil && flow.created.duration(to: now) > .seconds(20))
          || flow.activity.duration(to: now) > .seconds(60)
        {
          retireUDP(tuple)
        }
      }
    }

    private func active(_ slot: UInt32, _ generation: UInt64) -> Bool {
      let state = agentc_lwip_state(slot)
      return !stopped && flows[slot]?.generation == generation
        && flows[slot]?.retired == nil && (state == 2 || state == 4)
    }

    private func wait(
      _ slot: UInt32, _ generation: UInt64, for reason: WaitReason, since observed: UInt64
    ) async {
      guard active(slot, generation), !Task.isCancelled else { return }
      switch reason {
      case .upload:
        if agentc_lwip_readable(slot) > 0 || agentc_lwip_eof(slot) != 0 { return }
      case .capacity:
        if agentc_lwip_send_capacity(slot) >= 16384 { return }
      case .retry:
        if progress != observed { return }
      }
      // Condition check and registration both execute on this actor without an
      // intervening suspension. Retirement resumes both waiters before reuse.
      await withCheckedContinuation { continuation in
        let waiter = Waiter(reason: reason, continuation: continuation)
        if reason == .upload {
          precondition(flows[slot]?.uploadWaiter == nil)
          flows[slot]?.uploadWaiter = waiter
        } else {
          precondition(flows[slot]?.downloadWaiter == nil)
          flows[slot]?.downloadWaiter = waiter
        }
      }
    }

    private func resumeWaiters(retry: Bool) {
      if retry { progress &+= 1 }
      for slot in flows.keys {
        if let waiter = flows[slot]?.uploadWaiter,
          agentc_lwip_readable(slot) > 0 || agentc_lwip_eof(slot) != 0
        {
          flows[slot]?.uploadWaiter = nil
          waiter.continuation.resume()
        }
        if let waiter = flows[slot]?.downloadWaiter,
          (waiter.reason == .capacity && agentc_lwip_send_capacity(slot) >= 16384)
            || (waiter.reason == .retry && retry)
        {
          flows[slot]?.downloadWaiter = nil
          waiter.continuation.resume()
        }
      }
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
          let gatewayDNS =
            flow.tuple.destination == Packet.gateway && flow.tuple.destinationPort == 53
          connection = try await SOCKS5Connection.connect(
            proxy: proxy, destination: gatewayDNS ? proxy.dns.host : flow.tuple.address,
            port: gatewayDNS ? proxy.dns.port : flow.tuple.destinationPort)
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
            // tcp_recved may generate a window update; freeing receive pbufs
            // also permits a previously ERR_MEM-blocked writer to retry.
            resumeWaiters(retry: true)
            wakeups?.signal()
          } else if agentc_lwip_eof(slot) != 0 {
            try await connection.finishSending()
            guard active(slot, generation) else { return }
            flows[slot]?.upstreamFinished = true
            finishIfComplete(slot)
            return
          } else {
            await wait(slot, generation, for: .upload, since: progress)
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
            await wait(slot, generation, for: .capacity, since: progress)
            continue
          }
          guard let data = try await connection.receive(maximum: 16384) else {
            while active(slot, generation) && agentc_lwip_finish(slot) == 0 {
              await wait(slot, generation, for: .retry, since: progress)
            }
            guard active(slot, generation) else { return }
            wakeups?.signal()
            flows[slot]?.downstreamFinished = true
            finishIfComplete(slot)
            return
          }
          guard !data.isEmpty, data.count <= 16384 else { throw PacketEngineError.stopped }
          while active(slot, generation) && !LWIPOutput.write(slot: slot, data: data) {
            await wait(slot, generation, for: .retry, since: progress)
          }
          guard active(slot, generation) else { return }
          flows[slot]?.activity = clock.now
          wakeups?.signal()
        }
      } catch {
        if active(slot, generation) { retire(slot) }
      }
    }

    private func finishIfComplete(_ slot: UInt32) {
      guard let flow = flows[slot], flow.upstreamFinished, flow.downstreamFinished else { return }
      agentc_lwip_release(slot)
      wakeups?.signal()
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
      flow.uploadWaiter?.continuation.resume()
      flow.downloadWaiter?.continuation.resume()
      flows[slot]?.connection = nil
      flows[slot]?.tasks = []
      flows[slot]?.uploadWaiter = nil
      flows[slot]?.downloadWaiter = nil
      flows[slot]?.retired = clock.now
      wakeups?.signal()
    }

    private func enqueue(_ datagram: Packet.Datagram) {
      let tuple = datagram.tuple
      if udpFlows[tuple] == nil {
        guard udpUnavailableUntil.map({ clock.now >= $0 }) ?? true else { return }
        guard udpFlows.count < 64 else { return }
        serial &+= 1
        let generation = serial
        let now = clock.now
        udpFlows[tuple] = UDPFlow(
          generation: generation, created: now, activity: now,
          pending: [Data(datagram.payload)])
        udpFlows[tuple]?.connecting = Task { await self.connectUDP(tuple, generation) }
      } else if udpFlows[tuple]!.pending.count < 8 {
        udpFlows[tuple]?.pending.append(Data(datagram.payload))
        udpFlows[tuple]?.activity = clock.now
        startUDPSender(tuple)
      }
    }

    private func activeUDP(_ tuple: Packet.Tuple, _ generation: UInt64) -> Bool {
      !stopped && udpFlows[tuple]?.generation == generation
    }

    private func connectUDP(_ tuple: Packet.Tuple, _ generation: UInt64) async {
      do {
        let association = try await SOCKS5UDPAssociation.associate(
          proxy: proxy, destination: tuple.address, port: tuple.destinationPort)
        guard activeUDP(tuple, generation), !Task.isCancelled else {
          await association.close()
          return
        }
        udpFlows[tuple]?.association = association
        udpFlows[tuple]?.connecting = nil
        udpFlows[tuple]?.receiving = Task {
          await self.receiveUDP(tuple, generation, association)
        }
        startUDPSender(tuple)
      } catch {
        guard activeUDP(tuple, generation) else { return }
        // TCP-only proxies commonly reject command3 with REP7. Avoid a new
        // authenticated TCP handshake for every guest datagram in that case.
        if let error = error as? SOCKS5Connection.TransportError,
          case .associateRejected(7) = error
        {
          udpUnavailableUntil = clock.now.advanced(by: .seconds(30))
        }
        retireUDP(tuple)
      }
    }

    private func startUDPSender(_ tuple: Packet.Tuple) {
      guard let flow = udpFlows[tuple], flow.sending == nil,
        !flow.pending.isEmpty, let association = flow.association
      else { return }
      udpFlows[tuple]?.sending = Task {
        await self.sendUDP(tuple, flow.generation, association)
      }
    }

    private func sendUDP(
      _ tuple: Packet.Tuple, _ generation: UInt64, _ association: SOCKS5UDPAssociation
    ) async {
      do {
        while activeUDP(tuple, generation) && !Task.isCancelled {
          guard !udpFlows[tuple]!.pending.isEmpty else {
            udpFlows[tuple]?.sending = nil
            return
          }
          let data = udpFlows[tuple]!.pending.removeFirst()
          try await association.send(data)
          guard activeUDP(tuple, generation) else { return }
          udpFlows[tuple]?.activity = clock.now
        }
      } catch {
        if activeUDP(tuple, generation) { retireUDP(tuple) }
      }
    }

    private func receiveUDP(
      _ tuple: Packet.Tuple, _ generation: UInt64, _ association: SOCKS5UDPAssociation
    ) async {
      do {
        while activeUDP(tuple, generation) && !Task.isCancelled {
          guard let data = try await association.receive() else {
            if activeUDP(tuple, generation) { retireUDP(tuple) }
            return
          }
          guard activeUDP(tuple, generation) else { return }
          let datagram = Packet.Datagram(tuple: tuple, payload: [])
          if let frame = datagram.response(Array(data)) {
            output.append(frame)
            wakeups?.signal()
            udpFlows[tuple]?.activity = clock.now
          }
        }
      } catch {
        if activeUDP(tuple, generation) { retireUDP(tuple) }
      }
    }

    private func retireUDP(_ tuple: Packet.Tuple) {
      guard let flow = udpFlows.removeValue(forKey: tuple) else { return }
      flow.connecting?.cancel()
      flow.sending?.cancel()
      flow.receiving?.cancel()
      if let association = flow.association { Task { await association.close() } }
    }

    private func resolve(_ query: Packet.DNSQuery, id: UInt64) async {
      var connection: SOCKS5Connection?
      do {
        let socket = try await SOCKS5Connection.connect(
          proxy: proxy, destination: proxy.dns.host, port: proxy.dns.port)
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
          wakeups?.signal()
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

    private func shutdown() async {
      stopped = true
      for slot in Array(flows.keys) { retire(slot) }
      for tuple in Array(udpFlows.keys) { retireUDP(tuple) }
      for job in dns.values {
        job.task.cancel()
        if let connection = job.connection { Task { await connection.close() } }
      }
      dns.removeAll()
      // In particular, do not return to run's flag-restoring defers (or to the
      // descriptor owner) until Dispatch's cancellation handlers have completed.
      await wakeups?.stopAndWait()
    }
  }
#endif
