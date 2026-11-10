import Foundation

/// The child's complete guest-facing packet policy. Unsupported EtherTypes,
/// IPv4 options, fragments, ICMP, and IPv6 are dropped.
/// Checksums are verified before any address translation is permitted.
enum Packet {
  static let guest: UInt32 = 0x0a57_0002
  static let gateway: UInt32 = 0x0a57_0001
  static let guestMAC: [UInt8] = [2, 0, 0, 0, 0, 2]
  static let gatewayMAC: [UInt8] = [2, 0, 0, 0, 0, 1]

  struct Tuple: Hashable, Sendable {
    let guestPort: UInt16
    let destination: UInt32
    let destinationPort: UInt16

    var address: String {
      "\(destination >> 24).\((destination >> 16) & 255).\((destination >> 8) & 255).\(destination & 255)"
    }
  }

  enum Inbound {
    case arp([UInt8])
    case tcp([UInt8], Tuple, syn: Bool)
    case dns(DNSQuery)
    case udp(Datagram)
  }

  static func u16(_ b: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(b[offset]) << 8 | UInt16(b[offset + 1])
  }

  static func u32(_ b: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(u16(b, offset)) << 16 | UInt32(u16(b, offset + 2))
  }

  static func put16(_ value: UInt16, _ b: inout [UInt8], _ offset: Int) {
    b[offset] = UInt8(truncatingIfNeeded: value >> 8)
    b[offset + 1] = UInt8(truncatingIfNeeded: value)
  }

  static func put32(_ value: UInt32, _ b: inout [UInt8], _ offset: Int) {
    put16(UInt16(truncatingIfNeeded: value >> 16), &b, offset)
    put16(UInt16(truncatingIfNeeded: value), &b, offset + 2)
  }

  static func checksum(_ bytes: ArraySlice<UInt8>, initial: UInt32 = 0) -> UInt16 {
    var sum = initial
    var index = bytes.startIndex
    while index + 1 < bytes.endIndex {
      sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
      index += 2
    }
    if index < bytes.endIndex { sum += UInt32(bytes[index]) << 8 }
    while sum >> 16 != 0 { sum = (sum & 65535) + (sum >> 16) }
    return ~UInt16(sum)
  }

  static func transportChecksum(_ b: [UInt8]) -> UInt16 {
    let length = b.count - 34
    let pseudo =
      UInt32(u16(b, 26)) + UInt32(u16(b, 28))
      + UInt32(u16(b, 30)) + UInt32(u16(b, 32)) + UInt32(b[23]) + UInt32(length)
    return checksum(b[34...], initial: pseudo)
  }

  static func inbound(_ bytes: [UInt8]) -> Inbound? {
    guard bytes.count >= 14, bytes.count <= 1514,
      Array(bytes[6..<12]) == guestMAC
    else { return nil }
    let etherType = u16(bytes, 12)
    if etherType == 0x0806 {
      guard bytes.count >= 42,
        Array(bytes[0..<6]) == gatewayMAC
          || Array(bytes[0..<6]) == [UInt8](repeating: 255, count: 6),
        u16(bytes, 14) == 1, u16(bytes, 16) == 0x0800,
        bytes[18] == 6, bytes[19] == 4,
        u16(bytes, 20) == 1 || u16(bytes, 20) == 2,
        Array(bytes[22..<28]) == guestMAC,
        u32(bytes, 28) == guest, u32(bytes, 38) == gateway
      else { return nil }
      return .arp(Array(bytes.prefix(42)))
    }
    guard etherType == 0x0800, bytes.count >= 34,
      Array(bytes[0..<6]) == gatewayMAC, bytes[14] == 0x45,
      bytes[22] > 0, u16(bytes, 20) & 0xbfff == 0,
      u32(bytes, 26) == guest, checksum(bytes[14..<34]) == 0
    else { return nil }
    let total = Int(u16(bytes, 16))
    guard total >= 20, total <= 1500, bytes.count >= total + 14 else { return nil }
    let b = Array(bytes.prefix(total + 14))
    let destination = u32(b, 30)
    guard destination != 0, destination >> 28 < 14 else { return nil }
    switch b[23] {
    case 6:
      guard b.count >= 54 else { return nil }
      let headerLength = Int(b[46] >> 4) * 4
      guard headerLength >= 20, headerLength <= b.count - 34,
        transportChecksum(b) == 0, u16(b, 34) != 0, u16(b, 36) != 0
      else { return nil }
      let tuple = Tuple(
        guestPort: u16(b, 34), destination: destination,
        destinationPort: u16(b, 36))
      // Only a bare initial SYN may allocate a listener. A repeated SYN uses
      // the existing mapping; ACK/RST/FIN never allocate state.
      return .tcp(b, tuple, syn: b[47] & 0x17 == 0x02)
    case 17:
      guard b.count >= 42, u16(b, 34) != 0, u16(b, 36) != 0,
        Int(u16(b, 38)) == b.count - 34,
        u16(b, 40) == 0 || transportChecksum(b) == 0
      else { return nil }
      let payload = Array(b.dropFirst(42))
      if destination == gateway && u16(b, 36) == 53 {
        guard let query = DNSQuery(port: u16(b, 34), message: payload) else { return nil }
        return .dns(query)
      }
      return .udp(
        Datagram(
          tuple: Tuple(
            guestPort: u16(b, 34), destination: destination,
            destinationPort: u16(b, 36)),
          payload: payload))
    default:
      return nil
    }
  }

  static func translatedInbound(_ bytes: [UInt8], localPort: UInt16) -> [UInt8] {
    var b = bytes
    put32(gateway, &b, 30)
    put16(localPort, &b, 36)
    repairTCPChecksums(&b)
    return b
  }

  static func translatedOutbound(_ bytes: [UInt8], tuple: Tuple) -> [UInt8]? {
    guard bytes.count >= 54, bytes[14] == 0x45, bytes[23] == 6,
      u32(bytes, 26) == gateway, u32(bytes, 30) == guest,
      u16(bytes, 36) == tuple.guestPort
    else { return nil }
    var b = bytes
    put32(tuple.destination, &b, 26)
    put16(tuple.destinationPort, &b, 34)
    repairTCPChecksums(&b)
    return b
  }

  private static func repairTCPChecksums(_ b: inout [UInt8]) {
    put16(0, &b, 24)
    put16(checksum(b[14..<34]), &b, 24)
    put16(0, &b, 50)
    put16(transportChecksum(b), &b, 50)
  }

  struct Datagram: Sendable {
    // An unfragmented IPv4 UDP packet on the guest's MTU1500 interface.
    static let maximumPayloadSize = 1472
    let tuple: Tuple
    let payload: [UInt8]

    /// Construct a reply from the original destination, not the relay endpoint.
    func response(_ payload: [UInt8]) -> [UInt8]? {
      guard payload.count <= Self.maximumPayloadSize else { return nil }
      var b = guestMAC + gatewayMAC + [0x08, 0x00]
      b += [UInt8](repeating: 0, count: 28)
      b[14] = 0x45
      put16(UInt16(28 + payload.count), &b, 16)
      b[22] = 64
      b[23] = 17
      put32(tuple.destination, &b, 26)
      put32(guest, &b, 30)
      put16(checksum(b[14..<34]), &b, 24)
      put16(tuple.destinationPort, &b, 34)
      put16(tuple.guestPort, &b, 36)
      put16(UInt16(8 + payload.count), &b, 38)
      b += payload
      let sum = transportChecksum(b)
      put16(sum == 0 ? 0xffff : sum, &b, 40)
      return b
    }
  }

  struct DNSQuery: Sendable {
    let port: UInt16
    let message: [UInt8]
    let questionEnd: Int

    init?(port: UInt16, message: [UInt8]) {
      guard message.count >= 17, message.count <= 1472,
        message[2] & 0xf8 == 0, u16(message, 4) == 1,
        u16(message, 6) == 0, u16(message, 8) == 0
      else { return nil }
      // DNS query names are uncompressed. Refuse compression pointers rather
      // than walking attacker-controlled pointer graphs.
      var offset = 12
      while offset < message.count && message[offset] != 0 {
        let length = Int(message[offset])
        guard length <= 63, offset + length + 1 < message.count else { return nil }
        offset += length + 1
        guard offset - 12 <= 254 else { return nil }
      }
      guard offset + 5 <= message.count else { return nil }
      self.port = port
      self.message = message
      self.questionEnd = offset + 5
    }

    func response(_ answer: [UInt8]) -> [UInt8]? {
      guard answer.count >= 12, answer[0..<2] == message[0..<2],
        answer[2] & 0x80 != 0
      else { return nil }
      var payload = answer
      if payload.count > 1472 {
        // Return a valid TC response, not a truncated byte stream. The guest
        // can retry TCP, which is transparently proxied like any other TCP.
        payload = Array(message.prefix(questionEnd))
        payload[2] = 0x82 | (message[2] & 1)
        payload[3] = answer[3]
        for offset in [6, 8, 10] { put16(0, &payload, offset) }
      }
      return Datagram(
        tuple: Tuple(guestPort: port, destination: gateway, destinationPort: 53),
        payload: []
      ).response(payload)
    }
  }
}
