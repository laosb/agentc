import AgentIsolation
import CSOCKSNetwork
import Darwin
import Foundation

private enum Failure: Error {
  case timeout
  case invalid(String)
}

private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw Failure.invalid(message) }
}

private func tcp(
  destination: UInt32 = 0xcb00_7107, port: UInt16 = 443, sourcePort: UInt16 = 40000,
  sequence: UInt32, acknowledgment: UInt32, flags: UInt8, payload: [UInt8] = []
) -> [UInt8] {
  var b = Packet.gatewayMAC + Packet.guestMAC + [0x08, 0x00]
  b += [UInt8](repeating: 0, count: 40)
  b[14] = 0x45
  Packet.put16(UInt16(40 + payload.count), &b, 16)
  b[22] = 64
  b[23] = 6
  Packet.put32(Packet.guest, &b, 26)
  Packet.put32(destination, &b, 30)
  Packet.put16(Packet.checksum(b[14..<34]), &b, 24)
  Packet.put16(sourcePort, &b, 34)
  Packet.put16(port, &b, 36)
  Packet.put32(sequence, &b, 38)
  Packet.put32(acknowledgment, &b, 42)
  b[46] = 0x50
  b[47] = flags
  Packet.put16(32768, &b, 48)
  b += payload
  Packet.put16(Packet.transportChecksum(b), &b, 50)
  return b
}

private func send(_ bytes: [UInt8], _ fd: Int32) throws {
  let count = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
  try require(count == bytes.count, "send failed: \(errno)")
}

private func sendEventually(_ bytes: [UInt8], _ fd: Int32) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while ContinuousClock.now < deadline {
    let count = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }
    if count == bytes.count { return }
    try require(
      count < 0 && [EAGAIN, EWOULDBLOCK, ENOBUFS].contains(errno), "send failed: \(errno)")
    try await Task.sleep(for: .milliseconds(2))
  }
  throw Failure.timeout
}

private func receive(_ fd: Int32, timeout: Duration = .seconds(3)) async throws -> [UInt8] {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  var bytes = [UInt8](repeating: 0, count: 2048)
  while ContinuousClock.now < deadline {
    let count = bytes.withUnsafeMutableBytes {
      Darwin.recv(fd, $0.baseAddress, $0.count, MSG_DONTWAIT)
    }
    if count >= 0 { return Array(bytes.prefix(count)) }
    if errno != EAGAIN && errno != EWOULDBLOCK { throw Failure.invalid("recv failed") }
    try await Task.sleep(for: .milliseconds(2))
  }
  throw Failure.timeout
}

private func receiveTCP(
  _ fd: Int32, flags: UInt8 = 0, payload: Bool = false,
  timeout: Duration = .seconds(3)
) async throws -> [UInt8] {
  for _ in 0..<100 {
    let b = try await receive(fd, timeout: timeout)
    if b.count >= 54 && b[23] == 6 && b[47] & flags == flags {
      let header = 34 + Int(b[46] >> 4) * 4
      if !payload || b.count > header { return b }
    }
  }
  throw Failure.timeout
}

private func packetUnitTests() throws {
  let original = tcp(sequence: 100, acknowledgment: 0, flags: 2)
  guard case .tcp(_, let tuple, true) = Packet.inbound(original) else {
    throw Failure.invalid("valid SYN rejected")
  }
  try require(tuple.address == "203.0.113.7", "destination parsing")
  let translated = Packet.translatedInbound(original, localPort: 20000)
  try require(Packet.u32(translated, 30) == Packet.gateway, "NAT destination")
  try require(Packet.transportChecksum(translated) == 0, "translated TCP checksum")
  try require(Packet.checksum(translated[14..<34]) == 0, "translated IP checksum")
  for length in 0..<original.count {
    try require(Packet.inbound(Array(original.prefix(length))) == nil, "short packet accepted")
  }
  for offset in [14, 16, 20, 22, 26, 30, 34, 38, 47, 50] {
    var damaged = original
    damaged[offset] ^= 1
    try require(Packet.inbound(damaged) == nil, "damaged packet accepted at \(offset)")
  }
  for protocolNumber: UInt8 in [1, 2, 17, 58, 255] {
    var unsupported = original
    unsupported[23] = protocolNumber
    Packet.put16(0, &unsupported, 24)
    Packet.put16(Packet.checksum(unsupported[14..<34]), &unsupported, 24)
    try require(Packet.inbound(unsupported) == nil, "unsupported protocol accepted")
  }
  var fragmented = original
  Packet.put16(0x2000, &fragmented, 20)
  Packet.put16(0, &fragmented, 24)
  Packet.put16(Packet.checksum(fragmented[14..<34]), &fragmented, 24)
  try require(Packet.inbound(fragmented) == nil, "fragment accepted")
  // Preserve complete DNS questions when returning TC for an oversized answer.
  let queryBytes: [UInt8] = [0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 97, 0, 0, 1, 0, 1]
  let query = Packet.DNSQuery(port: 41000, message: queryBytes)!
  var largeAnswer = queryBytes + [UInt8](repeating: 0, count: 2000)
  largeAnswer[2] |= 0x80
  let truncated = query.response(largeAnswer)!
  try require(
    truncated.count == 42 + queryBytes.count && truncated[44] & 0x82 == 0x82,
    "oversized DNS response must preserve question and set TC")
  try require(Packet.transportChecksum(truncated) == 0, "truncated DNS checksum")
  var wrongID = queryBytes
  wrongID[0] ^= 1
  wrongID[2] |= 0x80
  try require(query.response(wrongID) == nil, "mismatched DNS transaction accepted")
  var compressed = queryBytes
  compressed[12] = 0xc0
  try require(
    Packet.DNSQuery(port: 41000, message: compressed) == nil,
    "compressed DNS query name accepted")
  // Deterministic malformed-input sweep exercises every short header boundary.
  var state: UInt64 = 0x1234_5678
  for index in 0..<10000 {
    var b: [UInt8] = []
    for _ in 0..<(index % 1516) {
      state = state &* 6_364_136_223_846_793_005 &+ 1
      b.append(UInt8(truncatingIfNeeded: state >> 32))
    }
    _ = Packet.inbound(b)
  }
}

private func largeHalfCloseTransfer(_ fd: Int32) async throws {
  let source: UInt16 = 40003
  try send(tcp(port: 444, sourcePort: source, sequence: 1000, acknowledgment: 0, flags: 2), fd)
  let synack = try await receiveTCP(fd, flags: 0x12)
  var remoteSequence = Packet.u32(synack, 38) &+ 1
  var guestSequence: UInt32 = 1001
  try send(
    tcp(
      port: 444, sourcePort: source, sequence: guestSequence,
      acknowledgment: remoteSequence, flags: 0x10), fd)
  let size = 1024 * 1024
  var uploaded = 0
  while uploaded < size {
    let batchStart = uploaded
    let batchEnd = min(size, uploaded + 16 * 1460)
    while uploaded < batchEnd {
      let length = min(1460, batchEnd - uploaded)
      let data = (uploaded..<(uploaded + length)).map { UInt8(truncatingIfNeeded: $0) }
      try await sendEventually(
        tcp(
          port: 444, sourcePort: source, sequence: guestSequence,
          acknowledgment: remoteSequence, flags: 0x18, payload: data), fd)
      uploaded += length
      guestSequence += UInt32(length)
      try await Task.sleep(for: .milliseconds(8))
    }
    var lastACK = UInt32(1001 + batchStart)
    var retries = 0
    while true {
      let ack: [UInt8]
      do { ack = try await receiveTCP(fd, flags: 0x10, timeout: .milliseconds(300)) } catch {
        // Minimal deterministic test-peer retransmission: lwIP may refuse
        // data while the deliberately slow upstream send is applying pressure.
        retries += 1
        try require(
          retries <= 20,
          "upload ACK timeout at byte \(uploaded), ACK \(lastACK), expected \(guestSequence)")
        var offset = Int(lastACK - 1001)
        while offset < uploaded {
          let length = min(1460, uploaded - offset)
          let data = (offset..<(offset + length)).map { UInt8(truncatingIfNeeded: $0) }
          try await sendEventually(
            tcp(
              port: 444, sourcePort: source, sequence: UInt32(1001 + offset),
              acknowledgment: remoteSequence, flags: 0x18, payload: data), fd)
          offset += length
          try await Task.sleep(for: .milliseconds(10))
        }
        continue
      }
      if Packet.u16(ack, 36) == source { lastACK = max(lastACK, Packet.u32(ack, 42)) }
      if Packet.u16(ack, 36) == source && Packet.u32(ack, 42) == guestSequence { break }
    }
  }
  try send(
    tcp(
      port: 444, sourcePort: source, sequence: guestSequence,
      acknowledgment: remoteSequence, flags: 0x11), fd)
  guestSequence += 1
  var downloaded = 0
  var sawFIN = false
  while !sawFIN {
    let frame: [UInt8]
    do { frame = try await receiveTCP(fd) } catch {
      throw Failure.invalid("download timeout at byte \(downloaded): \(error)")
    }
    guard Packet.u16(frame, 36) == source else { continue }
    try require(Packet.transportChecksum(frame) == 0, "large transfer checksum")
    let sequence = Packet.u32(frame, 38)
    let header = 34 + Int(frame[46] >> 4) * 4
    let payload = Array(frame.dropFirst(header))
    if sequence == remoteSequence {
      let expected = (downloaded..<(downloaded + payload.count)).map {
        UInt8(truncatingIfNeeded: $0)
      }
      try require(payload == expected, "large transfer content")
      downloaded += payload.count
      remoteSequence += UInt32(payload.count)
      if frame[47] & 1 != 0 {
        remoteSequence += 1
        sawFIN = true
      }
    }
    if !payload.isEmpty || frame[47] & 1 != 0 {
      try await sendEventually(
        tcp(
          port: 444, sourcePort: source, sequence: guestSequence,
          acknowledgment: remoteSequence, flags: 0x10), fd)
    }
  }
  try require(downloaded == size, "large transfer size")
  let finished = await MockConnections.shared.finishedBytes
  try require(finished.contains(size), "FIN propagated before all upstream bytes drained")
}

private func remoteHalfCloseFirst(_ fd: Int32) async throws {
  let source: UInt16 = 40004
  try send(tcp(port: 445, sourcePort: source, sequence: 2000, acknowledgment: 0, flags: 2), fd)
  let synack = try await receiveTCP(fd, flags: 0x12)
  let remoteSequence = Packet.u32(synack, 38) &+ 1
  try send(
    tcp(
      port: 445, sourcePort: source, sequence: 2001,
      acknowledgment: remoteSequence, flags: 0x10), fd)
  let fin = try await receiveTCP(fd, flags: 1)
  // Sending data after receiving the upstream FIN must still work.
  let payload = [UInt8](repeating: 0x5a, count: 100)
  try send(
    tcp(
      port: 445, sourcePort: source, sequence: 2001,
      acknowledgment: Packet.u32(fin, 38) + 1, flags: 0x19, payload: payload), fd)
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while !(await MockConnections.shared.finishedBytes).contains(100) {
    if ContinuousClock.now >= deadline { throw Failure.timeout }
    try await Task.sleep(for: .milliseconds(5))
  }
}

private func backpressuredLASTACK(_ fd: Int32) async throws {
  let source: UInt16 = 40005
  try send(tcp(port: 446, sourcePort: source, sequence: 3000, acknowledgment: 0, flags: 2), fd)
  let synack = try await receiveTCP(fd, flags: 0x12)
  let remoteSequence = Packet.u32(synack, 38) &+ 1
  try send(
    tcp(
      port: 446, sourcePort: source, sequence: 3001,
      acknowledgment: remoteSequence, flags: 0x18,
      payload: [UInt8](repeating: 0x11, count: 256)), fd)
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while await MockConnections.shared.slowSends == 0 {
    if ContinuousClock.now >= deadline { throw Failure.timeout }
    try await Task.sleep(for: .milliseconds(2))
  }
  // Append another pbuf while the first is awaiting a backpressured send.
  try send(
    tcp(
      port: 446, sourcePort: source, sequence: 3257,
      acknowledgment: remoteSequence, flags: 0x19,
      payload: [UInt8](repeating: 0x22, count: 768)), fd)
  let fin = try await receiveTCP(fd, flags: 1)
  // This ACK destroys LAST_ACK immediately, before either upload has drained.
  try send(
    tcp(
      port: 446, sourcePort: source, sequence: 4026,
      acknowledgment: Packet.u32(fin, 38) + 1, flags: 0x10), fd)
  while !(await MockConnections.shared.finishedBytes).contains(1024) {
    if ContinuousClock.now >= deadline {
      throw Failure.invalid("orderly PCB destruction cancelled backpressured upload")
    }
    try await Task.sleep(for: .milliseconds(5))
  }
}

private func repeatedRefusals(_ fd: Int32) async throws {
  // More than the entire 128-slot table: failed handshakes must recycle
  // promptly, while their queued RST still receives the old tuple translation.
  for index in 0..<140 {
    let source = UInt16(42000 + index)
    try send(
      tcp(
        destination: 0xcb00_7109, sourcePort: source, sequence: 5000,
        acknowledgment: 0, flags: 2), fd)
    let synack = try await receiveTCP(fd, flags: 0x12)
    try require(Packet.u16(synack, 36) == source, "refusal slot tuple reuse")
    try send(
      tcp(
        destination: 0xcb00_7109, sourcePort: source, sequence: 5001,
        acknowledgment: Packet.u32(synack, 38) + 1, flags: 0x10), fd)
    let rst = try await receiveTCP(fd, flags: 4)
    try require(
      Packet.u16(rst, 36) == source && Packet.u32(rst, 26) == 0xcb00_7109,
      "retired slot RST translation")
  }
}

@main
struct PacketEngineHarness {
  static func main() async throws {
    try packetUnitTests()
    var packet: [Int32] = [-1, -1]
    var control: [Int32] = [-1, -1]
    try require(socketpair(AF_UNIX, SOCK_DGRAM, 0, &packet) == 0, "packet socketpair")
    try require(socketpair(AF_UNIX, SOCK_STREAM, 0, &control) == 0, "control socketpair")
    defer {
      for fd in packet + control where fd >= 0 { _ = Darwin.close(fd) }
    }
    let childPacket = packet[1]
    let childControl = control[1]
    let proxy = try SOCKS5Proxy(url: "socks5://127.0.0.1:1080")
    let task = Task {
      try await SOCKSNetworkEngine.run(
        proxy: proxy, packetFD: childPacket, controlFD: childControl, hostMCPPort: 9123)
    }
    let readiness = try await receive(control[0])
    try require(readiness == [1], "exact readiness byte")

    // Populate lwIP's guest neighbor entry and check gateway ARP identity.
    var arp = [UInt8](repeating: 255, count: 6) + Packet.guestMAC + [0x08, 0x06]
    arp += [0, 1, 8, 0, 6, 4, 0, 1] + Packet.guestMAC + [10, 87, 0, 2]
    arp += [UInt8](repeating: 0, count: 6) + [10, 87, 0, 1]
    try send(arp, packet[0])
    var arpReply = try await receive(packet[0])
    if arpReply.count >= 42 && Packet.u16(arpReply, 20) == 1 {
      arpReply = try await receive(packet[0])
    }
    try require(arpReply.count >= 42 && Packet.u16(arpReply, 20) == 2, "ARP reply")

    try send(tcp(sequence: 100, acknowledgment: 0, flags: 2), packet[0])
    let synack = try await receiveTCP(packet[0], flags: 0x12)
    try require(Packet.u32(synack, 26) == 0xcb00_7107, "reverse translated SYNACK")
    try require(Packet.u16(synack, 34) == 443, "reverse translated source port")
    try require(Packet.transportChecksum(synack) == 0, "SYNACK checksum")
    let remoteSequence = Packet.u32(synack, 38) &+ 1
    try send(tcp(sequence: 101, acknowledgment: remoteSequence, flags: 0x10), packet[0])
    let payload = Array("packet-engine-echo".utf8)
    try send(
      tcp(sequence: 101, acknowledgment: remoteSequence, flags: 0x18, payload: payload), packet[0])
    let echo = try await receiveTCP(packet[0], payload: true)
    let header = 34 + Int(echo[46] >> 4) * 4
    try require(Array(echo[header...]) == payload, "TCP echo payload")
    try require(Packet.transportChecksum(echo) == 0, "echo checksum")
    let nextGuest = 101 + UInt32(payload.count)
    let nextRemote = Packet.u32(echo, 38) + UInt32(payload.count)
    try send(tcp(sequence: nextGuest, acknowledgment: nextRemote, flags: 0x11), packet[0])
    let fin = try await receiveTCP(packet[0], flags: 1)
    try send(
      tcp(sequence: nextGuest + 1, acknowledgment: Packet.u32(fin, 38) + 1, flags: 0x10), packet[0])

    // A proxy handshake failure must reset, never establish a direct path.
    try send(
      tcp(destination: 0xcb00_7109, sourcePort: 40001, sequence: 300, acknowledgment: 0, flags: 2),
      packet[0])
    let failedSyn = try await receiveTCP(packet[0], flags: 0x12)
    try send(
      tcp(
        destination: 0xcb00_7109, sourcePort: 40001, sequence: 301,
        acknowledgment: Packet.u32(failedSyn, 38) + 1, flags: 0x10), packet[0])
    _ = try await receiveTCP(packet[0], flags: 4)

    // Only the exact gateway + configured MCP port selects the local exception.
    try send(
      tcp(
        destination: Packet.gateway, port: 9123, sourcePort: 40002,
        sequence: 500, acknowledgment: 0, flags: 2), packet[0])
    let mcpSyn = try await receiveTCP(packet[0], flags: 0x12)
    try send(
      tcp(
        destination: Packet.gateway, port: 9123, sourcePort: 40002,
        sequence: 501, acknowledgment: Packet.u32(mcpSyn, 38) + 1, flags: 0x10), packet[0])

    let queryBytes: [UInt8] = [0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 97, 0, 0, 1, 0, 1]
    let query = Packet.DNSQuery(port: 41000, message: queryBytes)!
    var answer = queryBytes
    answer[2] |= 0x80
    var udp = query.response(answer)!
    udp.replaceSubrange(0..<6, with: Packet.gatewayMAC)
    udp.replaceSubrange(6..<12, with: Packet.guestMAC)
    Packet.put32(Packet.guest, &udp, 26)
    Packet.put32(Packet.gateway, &udp, 30)
    Packet.put16(41000, &udp, 34)
    Packet.put16(53, &udp, 36)
    udp[44] &= 0x7f
    Packet.put16(0, &udp, 24)
    Packet.put16(Packet.checksum(udp[14..<34]), &udp, 24)
    Packet.put16(0, &udp, 40)
    Packet.put16(Packet.transportChecksum(udp), &udp, 40)
    try send(udp, packet[0])
    var dnsResponse: [UInt8] = []
    for _ in 0..<20 {
      let b = try await receive(packet[0])
      if b.count > 42 && b[23] == 17 {
        dnsResponse = b
        break
      }
    }
    try require(Array(dnsResponse.dropFirst(42)) == answer, "DNS-over-TCP response")
    try require(Packet.transportChecksum(dnsResponse) == 0, "DNS UDP checksum")
    let destinations = await MockConnections.shared.destinations
    try require(destinations.contains("203.0.113.7:443"), "SOCKS original destination")
    try require(destinations.contains("HOST-MCP:9123"), "MCP exception")
    try require(destinations.contains("1.1.1.1:53"), "fixed DNS resolver")

    // TCP fallback uses the gateway service, but CONNECT targets the fixed
    // resolver rather than asking the proxy to connect to private10.87.0.1.
    let resolverCount = destinations.filter { $0 == "1.1.1.1:53" }.count
    try send(
      tcp(
        destination: Packet.gateway, port: 53, sourcePort: 40006,
        sequence: 6000, acknowledgment: 0, flags: 2), packet[0])
    let dnsSyn = try await receiveTCP(packet[0], flags: 0x12)
    let dnsSequence = Packet.u32(dnsSyn, 38) + 1
    let framedQuery = [UInt8(0), UInt8(queryBytes.count)] + queryBytes
    try send(
      tcp(
        destination: Packet.gateway, port: 53, sourcePort: 40006,
        sequence: 6001, acknowledgment: dnsSequence, flags: 0x18,
        payload: framedQuery), packet[0])
    let tcpDNS = try await receiveTCP(packet[0], payload: true)
    let tcpDNSHeader = 34 + Int(tcpDNS[46] >> 4) * 4
    try require(
      Array(tcpDNS.dropFirst(tcpDNSHeader)) == [0, UInt8(answer.count)] + answer,
      "DNS TCP fallback response")
    try require(
      Packet.u32(tcpDNS, 26) == Packet.gateway && Packet.u16(tcpDNS, 34) == 53,
      "DNS TCP service reverse translation")
    let newResolverCount = await MockConnections.shared.destinations.filter { $0 == "1.1.1.1:53" }
      .count
    try require(newResolverCount == resolverCount + 1, "DNS TCP did not select fixed resolver")
    try send(
      tcp(
        destination: Packet.gateway, port: 53, sourcePort: 40006,
        sequence: 6001 + UInt32(framedQuery.count),
        acknowledgment: dnsSequence + UInt32(tcpDNS.count - tcpDNSHeader)
          + (tcpDNS[47] & 1 != 0 ? 1 : 0), flags: 0x11), packet[0])

    try await largeHalfCloseTransfer(packet[0])
    try await remoteHalfCloseFirst(packet[0])
    try await backpressuredLASTACK(packet[0])
    try await repeatedRefusals(packet[0])

    // Either control data or peer EOF stops the child promptly.
    let start = ContinuousClock.now
    if CommandLine.arguments.contains("--control-eof") {
      _ = Darwin.close(control[0])
      control[0] = -1
    } else {
      try send([0], control[0])
    }
    try await task.value
    try require(start.duration(to: .now) < .seconds(1), "control shutdown latency")
    try require(
      fcntl(childPacket, F_GETFL) >= 0 && fcntl(childControl, F_GETFL) >= 0,
      "borrowed descriptors closed")
    print(
      "PASS: packet validation/fuzz, lwIP ARP/TCP translation/echo/FIN/RST, 1MiB half-close/backpressure, remote-first FIN, backpressured LAST_ACK, 140 sequential refusals, DNS-over-TCP, MCP policy, control shutdown"
    )
  }
}
