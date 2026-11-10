#if os(macOS)
  import CSOCKSNetwork
  import Dispatch
  import Foundation

  /// A single bounded mailbox, not a task per descriptor event. The lock protects
  /// only Dispatch source lifetimes/suspension and mailbox bits; no lwIP or actor
  /// state is touched by these callbacks. Sources borrow, never close, their FDs.
  final class PacketEngineWakeups: @unchecked Sendable {
    struct Events: OptionSet, Sendable {
      let rawValue: UInt8
      static let packet = Self(rawValue: 1 << 0)
      static let control = Self(rawValue: 1 << 1)
      static let write = Self(rawValue: 1 << 2)
      static let timer = Self(rawValue: 1 << 3)
      static let work = Self(rawValue: 1 << 4)
    }

    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private let packet: any DispatchSourceRead
    private let control: any DispatchSourceRead
    private let write: any DispatchSourceWrite
    private let timer: any DispatchSourceTimer
    private let retry: any DispatchSourceTimer
    private let cancellations = DispatchGroup()
    private var armed: Events = []
    private var pending: Events = []
    private var stopped = false
    private var triedWriteReadiness = false
    private var retryScheduled = false
    private var retryMilliseconds = 1

    init(
      packetFD: Int32, controlFD: Int32,
      queue: DispatchQueue = DispatchQueue(label: "agentc.packet-readiness")
    ) {
      (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
      packet = DispatchSource.makeReadSource(fileDescriptor: packetFD, queue: queue)
      control = DispatchSource.makeReadSource(fileDescriptor: controlFD, queue: queue)
      write = DispatchSource.makeWriteSource(fileDescriptor: packetFD, queue: queue)
      timer = DispatchSource.makeTimerSource(queue: queue)
      retry = DispatchSource.makeTimerSource(queue: queue)
      packet.setEventHandler { [weak self] in self?.ready(.packet) }
      control.setEventHandler { [weak self] in self?.ready(.control) }
      write.setEventHandler { [weak self] in self?.ready(.write) }
      timer.setEventHandler { [weak self] in self?.signal(.timer) }
      retry.setEventHandler { [weak self] in self?.retryReady() }
      // Capture only the group: retaining self here would prevent deinit from
      // cancelling sources. A cancel handler runs after its source's final event
      // handler and after Dispatch has relinquished the borrowed descriptor.
      for source in [packet, control, write, timer, retry] as [any DispatchSourceProtocol] {
        cancellations.enter()
        source.setCancelHandler { [cancellations] in cancellations.leave() }
      }
      timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
      retry.schedule(deadline: .distantFuture)
      timer.resume()
      retry.resume()
    }

    deinit { stop() }

    func signal(_ event: Events = .work) {
      lock.lock()
      defer { lock.unlock() }
      signalLocked(event)
    }

    private func signalLocked(_ event: Events) {
      guard !stopped else { return }
      pending.formUnion(event)
      continuation.yield(())
    }

    func takeEvents() -> Events {
      lock.lock()
      defer { lock.unlock() }
      let events = pending
      pending = []
      return events
    }

    // A level-triggered source is suspended until the actor drains its FD.
    // Rearming after a bounded drain also schedules another turn if still ready.
    func armReads() {
      lock.lock()
      defer { lock.unlock() }
      guard !stopped else { return }
      if !armed.contains(.packet) {
        armed.insert(.packet)
        packet.resume()
      }
      if !armed.contains(.control) {
        armed.insert(.control)
        control.resume()
      }
    }

    private func ready(_ event: Events) {
      lock.lock()
      defer { lock.unlock() }
      guard !stopped, armed.contains(event) else { return }
      armed.remove(event)
      if event == .packet { packet.suspend() }
      if event == .control { control.suspend() }
      if event == .write { write.suspend() }
      signalLocked(event)
    }

    func outputBlocked() {
      lock.lock()
      defer { lock.unlock() }
      guard !stopped else { return }
      if !triedWriteReadiness {
        triedWriteReadiness = true
        armed.insert(.write)
        write.resume()
      } else if !armed.contains(.write) && !retryScheduled {
        // Some AF_UNIX datagram sockets report writable while send still
        // returns ENOBUFS. Do not continuously rearm that level-triggered source.
        retryScheduled = true
        retry.schedule(deadline: .now() + .milliseconds(retryMilliseconds))
        retryMilliseconds = min(64, retryMilliseconds * 2)
      }
    }

    private func retryReady() {
      lock.lock()
      defer { lock.unlock() }
      guard !stopped, retryScheduled else { return }
      retryScheduled = false
      signalLocked(.write)
    }

    func outputDrained() {
      lock.lock()
      defer { lock.unlock() }
      guard !stopped else { return }
      if armed.contains(.write) {
        armed.remove(.write)
        write.suspend()
      }
      triedWriteReadiness = false
      retryScheduled = false
      retryMilliseconds = 1
      retry.schedule(deadline: .distantFuture)
    }

    func stop() {
      lock.lock()
      defer { lock.unlock() }
      guard !stopped else { return }
      stopped = true
      packet.cancel()
      control.cancel()
      write.cancel()
      timer.cancel()
      retry.cancel()
      // A suspended Dispatch source must be balanced before releasing it.
      if !armed.contains(.packet) { packet.resume() }
      if !armed.contains(.control) { control.resume() }
      if !armed.contains(.write) { write.resume() }
      continuation.finish()
    }

    /// Cancellation is asynchronous. Callers must await this barrier before
    /// restoring FD flags or allowing the owner to close/reuse borrowed FDs.
    /// notify suspends the Swift task without blocking a cooperative thread;
    /// task cancellation must not bypass this resource-lifetime barrier.
    func stopAndWait() async {
      stop()
      await withCheckedContinuation { continuation in
        cancellations.notify(queue: .global()) { continuation.resume() }
      }
    }
  }

  /// Synchronously borrowed by the C linkoutput callback, exclusively while an
  /// engine actor method is executing. The C API never retains packet pointers.
  /// This is the only Swift/C pointer bridge; packet policy uses checked arrays.
  final class LWIPOutput {
    private var packets: [[UInt8]] = []
    private var first = 0
    private static let limit = 256

    func append(_ packet: [UInt8]) {
      // Dropping an Ethernet frame is preferable to buffering without a bound.
      // TCP retransmission recovers loss; DNS clients may retry their datagram.
      guard packets.count - first < Self.limit else { return }
      if first > 0 && packets.count == Self.limit {
        packets.removeFirst(first)
        first = 0
      }
      packets.append(packet)
    }

    var next: [UInt8]? { first < packets.count ? packets[first] : nil }

    func containsTCP(sourcePort: UInt16) -> Bool {
      packets[first...].contains { frame in
        frame.count >= 54 && Packet.u16(frame, 12) == 0x0800
          && frame[23] == 6 && Packet.u16(frame, 34) == sourcePort
      }
    }

    func removeFirst() {
      first += 1
      if first == packets.count {
        packets.removeAll(keepingCapacity: true)
        first = 0
      }
    }

    func initialize() -> Bool {
      agentc_lwip_init(
        { context, bytes, length in
          guard let context, let bytes else { return }
          let output = Unmanaged<LWIPOutput>.fromOpaque(context).takeUnretainedValue()
          output.append(Array(UnsafeBufferPointer(start: bytes, count: length)))
        },
        Unmanaged.passUnretained(self).toOpaque()
      ) != 0
    }

    static func input(_ packet: [UInt8]) {
      packet.withUnsafeBufferPointer { buffer in
        agentc_lwip_input(buffer.baseAddress, buffer.count)
      }
    }

    static func read(slot: UInt32) -> Data {
      let available = agentc_lwip_readable(slot)
      // Allocate only for pending data, bounded by the configured receive window.
      guard available > 0, available <= 32768 else { return Data() }
      var bytes = [UInt8](repeating: 0, count: available)
      let length = bytes.withUnsafeMutableBufferPointer { buffer in
        agentc_lwip_read(slot, buffer.baseAddress, buffer.count)
      }
      return Data(bytes.prefix(length))
    }

    static func write(slot: UInt32, data: Data) -> Bool {
      data.withUnsafeBytes { buffer in
        agentc_lwip_write(slot, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count) != 0
      }
    }
  }
#endif
