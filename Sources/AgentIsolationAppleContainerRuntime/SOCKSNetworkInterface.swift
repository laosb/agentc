#if canImport(Containerization)
  import Containerization
  import ContainerizationExtras
  import Foundation
  import SOCKSNetwork
  import Virtualization

  /// The sole VM interface in enforced-proxy mode. There is no NAT attachment
  /// to fall back to if the helper fails: the packet socket simply stops moving.
  struct SOCKSNetworkInterface: Interface, VZInterface {
    static let gateway = "10.87.0.1"
    let ipv4Address: CIDRv4
    let ipv4Gateway: IPv4Address?
    let macAddress: MACAddress?
    let mtu: UInt32 = 1500
    private let helper: SOCKSNetworkHelper

    init(helper: SOCKSNetworkHelper) throws {
      self.helper = helper
      ipv4Address = try CIDRv4("10.87.0.2/24")
      ipv4Gateway = try IPv4Address(Self.gateway)
      macAddress = try MACAddress("02:00:00:00:00:02")
    }

    func device() throws -> VZVirtioNetworkDeviceConfiguration {
      try helper.withPacketFileHandle { packet in
        let device = VZVirtioNetworkDeviceConfiguration()
        device.macAddress = VZMACAddress(string: macAddress!.description)!
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: packet)
        attachment.maximumTransmissionUnit = Int(mtu)
        device.attachment = attachment
        return device
      }
    }
  }
#endif
