// Separate executable from PacketEngineHarness.swift: validates readiness,
// coalescing and quiet shutdown without the transport double's idle polling.
import AgentIsolation
import Darwin
import Dispatch
import Foundation

private enum ReadinessFailure: Error { case failed(String) }

private func check(_ condition: Bool, _ message: String) throws {
  if !condition { throw ReadinessFailure.failed(message) }
}

private func sendByte(_ fd: Int32) throws {
  var byte: UInt8 = 1
  try check(Darwin.send(fd, &byte, 1, MSG_DONTWAIT) == 1, "send: \(errno)")
}

private func cpuSeconds() -> Double {
  var usage = rusage()
  _ = getrusage(RUSAGE_SELF, &usage)
  return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
    + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

private func sources(packet: [Int32], control: [Int32]) async throws {
  let wakeups = PacketEngineWakeups(packetFD: packet[1], controlFD: control[1])
  defer { wakeups.stop() }
  for _ in 0..<10_000 { wakeups.signal() }
  var turns = 0
  var timers = 0
  for await _ in wakeups.stream {
    turns += 1
    if wakeups.takeEvents().contains(.timer) { timers += 1 }
    if timers == 3 { break }
    try check(turns <= 4, "mailbox did not coalesce burst or spun while idle")
  }
  try check(turns <= 4, "more than one work turn plus three timer turns")

  // Leave data unread after each two-packet budget. The level source must
  // schedule another turn, rather than requiring a new edge or polling.
  for _ in 0..<8 { try sendByte(packet[0]) }
  wakeups.armReads()
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  var received = 0
  for await _ in wakeups.stream {
    let events = wakeups.takeEvents()
    try check(ContinuousClock.now < deadline, "bounded read drain stalled")
    if events.contains(.packet) {
      for _ in 0..<2 {
        var byte: UInt8 = 0
        if Darwin.recv(packet[1], &byte, 1, MSG_DONTWAIT) == 1 { received += 1 }
      }
      wakeups.armReads()
    }
    if received == 8 { break }
  }

  // Simulate a descriptor that keeps claiming writability after ENOBUFS.
  // Readiness is tried once, then retry backoff must prevent a tight loop.
  let start = ContinuousClock.now
  var writes = 0
  wakeups.outputBlocked()
  for await _ in wakeups.stream {
    let events = wakeups.takeEvents()
    if events.contains(.write) {
      writes += 1
      wakeups.outputBlocked()
    }
    try check(writes <= 12, "write readiness spun on a writable descriptor")
    if start.duration(to: .now) >= .milliseconds(100) { break }
  }
  try check(writes >= 2, "blocked output did not retry")
  wakeups.outputDrained()
  await wakeups.stopAndWait()
}

private actor CancellationProgress {
  private(set) var started = false
  private(set) var finished = false
  func start() { started = true }
  func finish() { finished = true }
}

private func cancellationBarrier(packet: [Int32], control: [Int32]) async throws {
  let queue = DispatchQueue(label: "readiness-test-delayed-cancellation")
  // Hold back all five cancellation handlers without blocking a Swift executor.
  queue.suspend()
  var suspended = true
  defer { if suspended { queue.resume() } }
  let wakeups = PacketEngineWakeups(packetFD: packet[1], controlFD: control[1], queue: queue)
  wakeups.armReads()
  wakeups.outputBlocked()
  wakeups.stop()
  let progress = CancellationProgress()
  let waiter = Task {
    await progress.start()
    await wakeups.stopAndWait()
    await progress.finish()
  }
  while !(await progress.started) { await Task.yield() }
  waiter.cancel()
  try await Task.sleep(for: .milliseconds(20))
  let prematurelyFinished = await progress.finished
  try check(!prematurelyFinished, "cancelled task bypassed pending cancellation handlers")
  queue.resume()
  suspended = false
  await waiter.value
  let finished = await progress.finished
  try check(finished, "cancellation barrier did not complete")
  // Waiting after completion and stopping repeatedly must also be safe.
  await wakeups.stopAndWait()
}

private func descriptorReuse() async throws {
  var previous: Set<Int32> = []
  var reused = 0
  for iteration in 0..<256 {
    var packet: [Int32] = [-1, -1]
    var control: [Int32] = [-1, -1]
    try check(socketpair(AF_UNIX, SOCK_DGRAM, 0, &packet) == 0, "reuse packet socketpair")
    try check(socketpair(AF_UNIX, SOCK_STREAM, 0, &control) == 0, "reuse control socketpair")
    let descriptors = Set(packet + control)
    reused += descriptors.intersection(previous).count
    let wakeups = PacketEngineWakeups(packetFD: packet[1], controlFD: control[1])
    if iteration % 2 == 0 {
      wakeups.armReads()
      wakeups.outputBlocked()
      try sendByte(packet[0])
      try sendByte(control[0])
    }
    // Exercise both active sources with pending events and never-resumed ones.
    // Close immediately after the barrier, so the next iteration can reuse FDs.
    await wakeups.stopAndWait()
    for fd in descriptors { try check(Darwin.close(fd) == 0, "reuse close") }
    previous = descriptors
  }
  try check(reused > 0, "test did not exercise descriptor-number reuse")
}

@main
private enum ReadinessHarness {
  static func main() async throws {
    var packet: [Int32] = [-1, -1]
    var control: [Int32] = [-1, -1]
    try check(socketpair(AF_UNIX, SOCK_DGRAM, 0, &packet) == 0, "packet socketpair")
    try check(socketpair(AF_UNIX, SOCK_STREAM, 0, &control) == 0, "control socketpair")
    defer {
      for fd in packet + control where fd >= 0 { _ = Darwin.close(fd) }
    }
    try await sources(packet: packet, control: control)
    try await cancellationBarrier(packet: packet, control: control)
    try await descriptorReuse()
    let packetFD = packet[1]
    let controlFD = control[1]
    let packetFlags = fcntl(packetFD, F_GETFL)
    let controlFlags = fcntl(controlFD, F_GETFL)
    let proxy = try SOCKS5Proxy(url: "socks5://127.0.0.1:1080")
    let readinessFailure = CommandLine.arguments.contains("--readiness-failure")
    if readinessFailure {
      _ = Darwin.close(control[0])
      control[0] = -1
    }
    let task = Task {
      try await SOCKSNetworkEngine.run(
        proxy: proxy, packetFD: packetFD, controlFD: controlFD, hostMCPPort: nil)
    }
    if readinessFailure {
      var failed = false
      do { try await task.value } catch { failed = true }
      try check(failed, "readiness send to closed control peer unexpectedly succeeded")
      try check(fcntl(packetFD, F_GETFL) == packetFlags, "failure changed packet FD flags")
      try check(fcntl(controlFD, F_GETFL) == controlFlags, "failure changed control FD flags")
      print("PASS: cancellation barrier, descriptor reuse, engine readiness-send failure cleanup")
      return
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    var ready: UInt8 = 0
    while Darwin.recv(control[0], &ready, 1, MSG_DONTWAIT) != 1 {
      try check(ContinuousClock.now < deadline, "engine readiness timeout")
      try await Task.sleep(for: .milliseconds(1))
    }
    let cpuStart = cpuSeconds()
    try await Task.sleep(for: .seconds(2))
    let idleCPU = cpuSeconds() - cpuStart
    let stopStart = ContinuousClock.now
    if CommandLine.arguments.contains("--control-eof") {
      _ = Darwin.close(control[0])
      control[0] = -1
    } else if CommandLine.arguments.contains("--control-byte") {
      try sendByte(control[0])
    } else {
      task.cancel()
    }
    try await task.value
    let latency = stopStart.duration(to: .now)
    try check(latency < .milliseconds(200), "quiet shutdown latency: \(latency)")
    try check(fcntl(packetFD, F_GETFL) == packetFlags, "borrowed packet FD flags changed")
    try check(fcntl(controlFD, F_GETFL) == controlFlags, "borrowed control FD flags changed")
    print(
      "PASS: bounded mailbox, level read rearming, nonspinning write retry, quiet shutdown, cancellation barrier, 256 descriptor-reuse cycles"
    )
    print("Idle CPU over 2s: \(idleCPU)s; shutdown: \(latency)")
  }
}
