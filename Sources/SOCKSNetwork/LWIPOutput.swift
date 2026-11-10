#if os(macOS)
  import CSOCKSNetwork
  import Foundation

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
