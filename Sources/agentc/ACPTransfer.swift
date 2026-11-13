import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// Fixed bounds for the ACP proxy. Injected so tests can exercise them cheaply.
struct ACPLimits: Sendable {
  /// Messages up to this size stay in memory; larger ones are spooled to disk.
  var inlineBytes = 256 * 1024
  /// Largest message the proxy will decode in order to rewrite it semantically.
  var controlBytes = 1024 * 1024
  /// Largest single message accepted from either peer.
  var messageBytes = 1024 * 1024 * 1024
  /// Disk held by all spooled messages that are in flight at once.
  var spoolBytes = 4 * 1024 * 1024 * 1024
  /// Per input stream: undelivered messages (including rejections) and their
  /// in-memory bytes. A full window stops reading that stream.
  var windowFrames = 64
  var windowBytes = 4 * 1024 * 1024
  /// Session requests held, across all workspaces, while backends start.
  var queuedControlBytes = 8 * 1024 * 1024
  /// Bytes read from a spool file, or handed to a writer, at a time.
  var chunkBytes = 256 * 1024

  static let standard = ACPLimits()
}

// MARK: - Spool

/// Private on-disk storage for large in-flight messages. Files are unlinked as
/// soon as they are opened, so the only reference is a descriptor: storage is
/// reclaimed on every exit path, including a crash, and the directory is
/// always empty.
final class ACPSpool: @unchecked Sendable {
  let directory: String
  private let limit: Int
  private let lock = NSLock()
  private var used = 0
  private var files = 0
  private var sequence = 0
  private var removed = false
  /// Named files that could not be unlinked at creation; retried on removal.
  private var leftovers: [String] = []

  init(limits: ACPLimits) throws {
    limit = limits.spoolBytes
    let template = FileManager.default.temporaryDirectory
      .appendingPathComponent("agentc-acp-spool-XXXXXX").path
    var bytes = Array(template.utf8CString)
    // mkdtemp creates the directory with mode 0700.
    guard mkdtemp(&bytes) != nil else {
      throw ACPError("Cannot create ACP spool directory: \(String(cString: strerror(errno)))")
    }
    directory = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  }

  var usedBytes: Int { lock.withLock { used } }
  var openFiles: Int { lock.withLock { files } }

  func makeFile() throws -> ACPSpoolFile {
    let name = lock.withLock { () -> String in
      sequence += 1
      return "\(directory)/\(sequence)"
    }
    let descriptor = open(
      name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw ACPError("Cannot create ACP spool file: \(String(cString: strerror(errno)))")
    }
    guard unlink(name) == 0 else {
      let reason = String(cString: strerror(errno))
      close(descriptor)
      // Never use a file that still has a name; retry removing it later.
      if unlink(name) != 0 { lock.withLock { leftovers.append(name) } }
      throw ACPError("Cannot make ACP spool file private: \(reason)")
    }
    lock.withLock { files += 1 }
    return ACPSpoolFile(spool: self, descriptor: descriptor)
  }

  /// Removes the (empty) directory; idempotent. In-flight files stay readable
  /// until released. Also runs when the last reference, including those held
  /// by in-flight files, goes away.
  func remove() {
    let names = lock.withLock { () -> [String]? in
      guard !removed else { return nil }
      removed = true
      return leftovers
    }
    guard let names else { return }
    for name in names { unlink(name) }
    rmdir(directory)
  }

  deinit { remove() }

  fileprivate func reserve(_ bytes: Int) -> Bool {
    lock.withLock {
      guard bytes <= limit - used else { return false }
      used += bytes
      return true
    }
  }

  fileprivate func release(_ bytes: Int) {
    lock.withLock {
      used -= bytes
      files -= 1
    }
  }
}

/// One spooled message. Written by a single ingress, then immutable and shared.
final class ACPSpoolFile: @unchecked Sendable {
  private let spool: ACPSpool
  private let descriptor: Int32
  private(set) var count = 0
  private var reserved = 0
  private static let reservation = 1024 * 1024

  fileprivate init(spool: ACPSpool, descriptor: Int32) {
    self.spool = spool
    self.descriptor = descriptor
  }

  deinit {
    close(descriptor)
    spool.release(reserved)
  }

  func append(_ bytes: UnsafeRawBufferPointer) throws {
    while count + bytes.count > reserved {
      // Deny rather than wait: capacity is held by other partial messages
      // that may themselves be waiting, so waiting here could never end.
      guard spool.reserve(Self.reservation) else {
        throw ACPError("ACP spool quota is exhausted by in-flight messages")
      }
      reserved += Self.reservation
    }
    var offset = 0
    while offset < bytes.count {
      let written = pwrite(
        descriptor, bytes.baseAddress! + offset, bytes.count - offset, off_t(count + offset))
      if written < 0 && errno == EINTR { continue }
      guard written > 0 else {
        throw ACPError("Cannot write ACP spool file: \(String(cString: strerror(errno)))")
      }
      offset += written
    }
    count += bytes.count
  }

  func read(_ range: Range<Int>) throws -> Data {
    var data = Data(count: range.count)
    try data.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let got = pread(
          descriptor, buffer.baseAddress! + offset, buffer.count - offset,
          off_t(range.lowerBound + offset))
        if got < 0 && errno == EINTR { continue }
        guard got > 0 else {
          throw ACPError(
            "Cannot read ACP spool file: \(got == 0 ? "truncated" : String(cString: strerror(errno)))")
        }
        offset += got
      }
    }
    return data
  }
}

// MARK: - Flow control

/// The receive window of one input stream. Every message or rejection that
/// stream produces holds a permit until everything derived from it has been
/// written to its destination or dropped; a full window blocks the stream's
/// reader, which is how backpressure reaches the peer.
///
/// `acquire` blocks its thread. Call it only from a dedicated reader thread or
/// a runtime I/O callback, never from Swift's cooperative executor.
final class ACPGate: @unchecked Sendable {
  private let condition = NSCondition()
  private let maximumFrames: Int
  private let maximumBytes: Int
  private var frames = 0
  private var bytes = 0
  private var closed = false

  init(frames: Int, bytes: Int) {
    maximumFrames = frames
    maximumBytes = bytes
  }

  convenience init(limits: ACPLimits) {
    self.init(frames: limits.windowFrames, bytes: limits.windowBytes)
  }

  /// Returns nil once the gate is closed; the caller must then stop producing.
  func acquire(bytes cost: Int) -> ACPPermit? {
    condition.lock()
    defer { condition.unlock() }
    // A lone message may exceed the byte window; it can never exceed the
    // inline threshold, so the overshoot is bounded.
    while !closed, frames >= maximumFrames || (frames > 0 && bytes + cost > maximumBytes) {
      condition.wait()
    }
    guard !closed else { return nil }
    frames += 1
    bytes += cost
    return ACPPermit(gate: self, bytes: cost)
  }

  /// Wakes and fails every waiter. Must precede any shutdown step that could
  /// wait on a lock held by a blocked producer.
  func close() {
    condition.lock()
    closed = true
    condition.broadcast()
    condition.unlock()
  }

  var inFlight: (frames: Int, bytes: Int) {
    condition.lock()
    defer { condition.unlock() }
    return (frames, bytes)
  }

  fileprivate func release(_ cost: Int) {
    condition.lock()
    frames -= 1
    bytes -= cost
    condition.broadcast()
    condition.unlock()
  }
}

/// Released when the last reference goes away, so a permit shared by several
/// outputs of one input lasts until the slowest of them is done.
final class ACPPermit: Sendable {
  private let gate: ACPGate
  private let bytes: Int

  fileprivate init(gate: ACPGate, bytes: Int) {
    self.gate = gate
    self.bytes = bytes
  }

  deinit { gate.release(bytes) }
}

// MARK: - Messages in transit

enum ACPBody: Sendable {
  case inline(Data)
  case spooled(ACPSpoolFile)

  var count: Int {
    switch self {
    case .inline(let data): return data.count
    case .spooled(let file): return file.count
    }
  }

  func read(_ range: Range<Int>) throws -> Data {
    switch self {
    case .inline(let data):
      return data.subdata(in: data.startIndex + range.lowerBound..<data.startIndex + range.upperBound)
    case .spooled(let file): return try file.read(range)
    }
  }
}

struct ACPFrame: Sendable {
  var envelope: ACPEnvelope
  var body: ACPBody
}

/// What an input stream produced for one line.
enum ACPInbound: Sendable {
  case message(ACPFrame, ACPPermit)
  /// Well-formed JSON the proxy must not forward (bad envelope, or too large).
  case rejected(String, ACPEnvelope, ACPPermit)
  case malformed(String, ACPPermit)
}

/// A message to write: the original bytes with a few values replaced, plus a
/// terminating newline. Nothing is copied until a writer asks for chunks.
struct ACPOutbound: Sendable {
  struct Edit: Sendable {
    var range: Range<Int>
    var replacement: Data
  }

  var body: ACPBody
  /// Sorted by position and non-overlapping.
  var edits: [Edit] = []
  var permit: ACPPermit?

  var count: Int {
    edits.reduce(body.count + 1) { $0 - $1.range.count + $1.replacement.count }
  }

  func materialize() throws -> Data {
    var reader = Reader(self)
    var data = Data()
    while let chunk = try reader.next(limit: 1024 * 1024) { data.append(chunk) }
    return data
  }

  struct Reader: Sendable {
    private let outbound: ACPOutbound
    private var position = 0
    private var edit = 0
    private var terminated = false

    init(_ outbound: ACPOutbound) { self.outbound = outbound }

    /// Returns roughly `limit` bytes, or nil after the trailing newline.
    mutating func next(limit: Int) throws -> Data? {
      var chunk = Data()
      while chunk.count < limit {
        let edits = outbound.edits
        if edit < edits.count, position == edits[edit].range.lowerBound {
          chunk.append(edits[edit].replacement)
          position = edits[edit].range.upperBound
          edit += 1
          continue
        }
        let end = edit < edits.count ? edits[edit].range.lowerBound : outbound.body.count
        if position < end {
          let count = min(end - position, limit - chunk.count)
          let piece = try outbound.body.read(position..<position + count)
          if chunk.isEmpty { chunk = piece } else { chunk.append(piece) }
          position += count
          continue
        }
        if !terminated {
          chunk.append(0x0A)
          terminated = true
        }
        break
      }
      return chunk.isEmpty ? nil : chunk
    }
  }
}

// MARK: - Ingress

/// Frames, validates, and stores one input stream. Not thread-safe: one reader
/// owns it. `receive` blocks while the stream's window is full.
final class ACPIngress {
  private let limits: ACPLimits
  private let spool: ACPSpool
  private let gate: ACPGate
  private var scanner = ACPScanner()
  private var inline = Data()
  private var file: ACPSpoolFile?
  private var length = 0
  /// Why the current line's bytes are no longer being kept.
  private var overflow: String?
  private var stopped = false

  init(limits: ACPLimits, spool: ACPSpool, gate: ACPGate) {
    self.limits = limits
    self.spool = spool
    self.gate = gate
  }

  /// True when the stream ended inside a message.
  var truncated: Bool { scanner.midLine || length > 0 }

  func receive(_ data: Data, emit: (ACPInbound) -> Void) {
    data.withUnsafeBytes { receive($0, emit: emit) }
  }

  func receive(_ bytes: UnsafeRawBufferPointer, emit: (ACPInbound) -> Void) {
    var rest = bytes
    while !stopped, !rest.isEmpty {
      let (consumed, line) = scanner.scan(rest)
      store(UnsafeRawBufferPointer(rebasing: rest[..<(line == nil ? consumed : consumed - 1)]))
      rest = UnsafeRawBufferPointer(rebasing: rest[consumed...])
      guard let line else { continue }
      let body: ACPBody = file.map { .spooled($0) } ?? .inline(inline)
      let overflow = overflow
      inline = Data()
      file = nil
      length = 0
      self.overflow = nil
      let cost: Int
      if case .message = line, overflow == nil, case .inline(let data) = body {
        cost = data.count + Self.overhead
      } else {
        cost = Self.overhead
      }
      if case .blank = line { continue }
      // Rejections hold permits too: a flood of bad lines is still bounded.
      guard let permit = gate.acquire(bytes: cost) else {
        stopped = true
        return
      }
      switch line {
      case .blank: break
      case .malformed(let reason): emit(.malformed(reason, permit))
      case .invalid(let reason, let envelope): emit(.rejected(reason, envelope, permit))
      case .message(let envelope):
        if let overflow {
          emit(.rejected(overflow, envelope, permit))
        } else {
          emit(.message(ACPFrame(envelope: envelope, body: body), permit))
        }
      }
    }
  }

  private static let overhead = 512

  private func store(_ bytes: UnsafeRawBufferPointer) {
    length += bytes.count
    guard overflow == nil, !bytes.isEmpty else { return }
    if scanner.failed {
      discard("malformed")
      return
    }
    guard length <= limits.messageBytes else {
      discard("ACP message exceeds the \(limits.messageBytes)-byte limit")
      return
    }
    do {
      if file == nil, inline.count + bytes.count > limits.inlineBytes {
        let file = try spool.makeFile()
        try inline.withUnsafeBytes { try file.append($0) }
        inline = Data()
        self.file = file
      }
      if let file { try file.append(bytes) } else { inline.append(contentsOf: bytes) }
    } catch {
      discard(String(describing: error))
    }
  }

  /// Keep scanning (a trailing `id` still identifies the request to reject)
  /// but stop holding the line's bytes.
  private func discard(_ reason: String) {
    overflow = reason
    inline = Data()
    file = nil
  }
}

// MARK: - Sinks

/// FIFO feeding one backend's stdin. Producers never block: what is queued is
/// bounded by the permits its entries hold. The consumer suspends rather than
/// blocking a thread, so it is safe on the cooperative executor.
final class ACPOutboundQueue: @unchecked Sendable {
  private let lock = NSLock()
  /// Slots before `head` are already taken and nil, so a consumed message
  /// gives back its permit and storage while later ones are still queued.
  private var items: [ACPOutbound?] = []
  private var head = 0
  private var waiter: CheckedContinuation<ACPOutbound?, Never>?
  private var finished = false

  func push(_ outbound: ACPOutbound) {
    let waiter = lock.withLock { () -> CheckedContinuation<ACPOutbound?, Never>? in
      guard !finished else { return nil }
      if let waiter = self.waiter {
        self.waiter = nil
        return waiter
      }
      items.append(outbound)
      return nil
    }
    waiter?.resume(returning: outbound)
  }

  /// Drops everything queued (releasing its permits) and ends the consumer,
  /// which also abandons a partly sent message on its next pull.
  func finish() {
    let (waiter, dropped) = lock.withLock {
      () -> (CheckedContinuation<ACPOutbound?, Never>?, [ACPOutbound?]) in
      finished = true
      defer {
        self.waiter = nil
        items = []
        head = 0
      }
      return (self.waiter, items)
    }
    waiter?.resume(returning: nil)
    _ = dropped  // Released here, outside the lock.
  }

  var isEmpty: Bool { lock.withLock { head == items.count } }
  private var isFinished: Bool { lock.withLock { finished } }

  private func pop() async -> ACPOutbound? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        // Decide under the lock; resume outside it.
        let (ready, superseded) = lock.withLock {
          () -> (ACPOutbound??, CheckedContinuation<ACPOutbound?, Never>?) in
          if finished { return (.some(nil), nil) }
          if head < items.count {
            let item = items[head]
            items[head] = nil
            head += 1
            if head == items.count {
              items.removeAll(keepingCapacity: true)
              head = 0
            } else if head >= 64, head * 2 >= items.count {
              items.removeFirst(head)
              head = 0
            }
            return (.some(item), nil)
          }
          let previous = waiter
          waiter = continuation
          return (nil, previous)
        }
        // A stream has one consumer; a second waiter would be a caller bug,
        // but must still never leak a continuation.
        superseded?.resume(returning: nil)
        if let ready { continuation.resume(returning: ready) }
      }
    } onCancel: {
      finish()
    }
  }

  /// A pull stream: each element is produced only when the consumer asks for
  /// it, so at most one chunk per backend is in memory. A message (and its
  /// permit) is released on the request after its last chunk, i.e. once the
  /// consumer has finished with every byte of it. After `finish()` or
  /// cancellation the next request ends the stream, even mid-message.
  func stream(chunkBytes: Int, failed: @escaping @Sendable (String) -> Void) -> AsyncStream<Data> {
    let cursor = Cursor()
    return AsyncStream(
      unfolding: { [self] in
        while true {
          if Task.isCancelled { finish() }
          if isFinished {
            cursor.reader = nil
            return nil
          }
          if cursor.reader != nil {
            do {
              if let chunk = try cursor.reader!.next(limit: chunkBytes) { return chunk }
            } catch {
              // Part of the line may already be written; the stream is unusable.
              cursor.reader = nil
              finish()
              failed(String(describing: error))
              return nil
            }
            cursor.reader = nil
          }
          guard let next = await pop() else { return nil }
          cursor.reader = ACPOutbound.Reader(next)
        }
      }, onCancel: { [self] in finish() })
  }

  /// Touched only by the stream's single consumer, one `next()` at a time.
  private final class Cursor: @unchecked Sendable {
    var reader: ACPOutbound.Reader?
  }
}

/// Writes client-bound messages on a dedicated thread, so the proxy never
/// blocks on a client that has stopped reading.
final class ACPClientWriter: @unchecked Sendable {
  private let descriptor: Int32
  private let chunkBytes: Int
  private let observe: (@Sendable (Data) -> Void)?
  private let failed: @Sendable (String) -> Void
  private let condition = NSCondition()
  private var items: [ACPOutbound] = []
  private var writing = false
  private var stopped = false
  private var idle: [CheckedContinuation<Void, Never>] = []

  init(
    descriptor: Int32, chunkBytes: Int, observe: (@Sendable (Data) -> Void)? = nil,
    failed: @escaping @Sendable (String) -> Void
  ) {
    self.descriptor = descriptor
    self.chunkBytes = chunkBytes
    self.observe = observe
    self.failed = failed
    Thread.detachNewThread { [self] in run() }
  }

  func push(_ outbound: ACPOutbound) {
    condition.lock()
    if !stopped { items.append(outbound) }
    condition.signal()
    condition.unlock()
  }

  /// Waits for queued output to be written, but only for `grace`: a client
  /// that has stopped reading must not hold up shutdown. After that the writer
  /// is abandoned; its thread may stay blocked in write(2) until the process
  /// exits or the descriptor fails, and it drops everything else it held.
  func finish(grace: Duration) async {
    let timeout = Task { [self] in
      try? await Task.sleep(for: grace)
      stop()
    }
    await withCheckedContinuation { continuation in
      condition.lock()
      let done = stopped || (items.isEmpty && !writing)
      if !done { idle.append(continuation) }
      condition.unlock()
      if done { continuation.resume() }
    }
    timeout.cancel()
    stop()
  }

  private func stop() {
    condition.lock()
    stopped = true
    let dropped = items
    items = []
    let waiters = idle
    idle = []
    condition.broadcast()
    condition.unlock()
    for waiter in waiters { waiter.resume() }
    _ = dropped
  }

  private func run() {
    while true {
      condition.lock()
      writing = false
      if items.isEmpty {
        let waiters = idle
        idle = []
        condition.unlock()
        for waiter in waiters { waiter.resume() }
        condition.lock()
      }
      while items.isEmpty, !stopped { condition.wait() }
      guard !stopped else {
        condition.unlock()
        return
      }
      let outbound = items.removeFirst()
      writing = true
      condition.unlock()
      do {
        var reader = ACPOutbound.Reader(outbound)
        while let chunk = try reader.next(limit: chunkBytes) {
          if isStopped { return }
          observe?(chunk)
          try writeAll(chunk)
        }
      } catch {
        stop()
        failed("Cannot write ACP output: \(error)")
        return
      }
    }
  }

  private var isStopped: Bool {
    condition.lock()
    defer { condition.unlock() }
    return stopped
  }

  private func writeAll(_ data: Data) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
          // A non-blocking descriptor: wait briefly so shutdown is noticed.
          var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
          _ = poll(&event, 1, 100)
          if isStopped { throw ACPError("stopped") }
          continue
        }
        guard count > 0 else { throw ACPError(String(cString: strerror(errno))) }
        offset += count
      }
    }
  }
}

/// Reads the client's stream on a dedicated thread, which is where framing,
/// validation, spooling, and window waits happen. Polling keeps the thread
/// stoppable without closing or reconfiguring the descriptor.
final class ACPClientReader: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false

  /// `emit(nil)` reports end of input, with a diagnostic if it was not clean.
  init(
    descriptor: Int32, ingress: sending ACPIngress, chunkBytes: Int,
    observe: (@Sendable (Data) -> Void)? = nil,
    emit: @escaping @Sendable (ACPInbound?, String?) -> Void
  ) {
    nonisolated(unsafe) let ingress = ingress
    Thread.detachNewThread { [self] in
      let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkBytes, alignment: 16)
      defer { buffer.deallocate() }
      while true {
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&event, 1, 100)
        if lock.withLock({ stopped }) { return }
        if ready == 0 || (ready < 0 && errno == EINTR) { continue }
        let count = read(descriptor, buffer.baseAddress!, buffer.count)
        if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
        guard count > 0 else {
          let reason =
            count < 0
            ? "Cannot read ACP input: \(String(cString: strerror(errno)))"
            : ingress.truncated ? "Truncated ACP message at EOF" : nil
          emit(nil, reason)
          return
        }
        let bytes = UnsafeRawBufferPointer(rebasing: buffer[..<count])
        observe?(Data(bytesNoCopy: buffer.baseAddress!, count: count, deallocator: .none))
        ingress.receive(bytes) { emit($0, nil) }
      }
    }
  }

  func stop() { lock.withLock { stopped = true } }
}
