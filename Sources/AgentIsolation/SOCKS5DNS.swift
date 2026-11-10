/// Host-only DNS-over-TCP destination reached through the SOCKS5 proxy.
/// Numeric IPv4 avoids any dependency on the host's resolver.
public struct SOCKS5DNS: Codable, Sendable, Equatable {
  public let host: String
  public let port: UInt16

  public static let `default` = SOCKS5DNS(host: "1.1.1.1", port: 53)

  private init(host: String, port: UInt16) {
    self.host = host
    self.port = port
  }

  public init(url: String) throws {
    // Parse the exact grammar rather than URLComponents or inet_aton, which
    // accept platform-dependent normalization, escaping, or abbreviated IPv4.
    // TCP is implicit; retain the original explicit form for compatibility.
    let endpoint = url.hasPrefix("tcp://") ? url.dropFirst("tcp://".count) : url[...]
    let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, Self.isCanonicalIPv4(parts[0]),
      !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
      let port = UInt16(parts[1]), port != 0
    else { throw Self.invalidEndpoint }
    self.init(host: String(parts[0]), port: port)
  }

  private static func isCanonicalIPv4(_ host: Substring) -> Bool {
    let octets = host.split(separator: ".", omittingEmptySubsequences: false)
    return octets.count == 4
      && octets.allSatisfy { octet in
        !octet.isEmpty && octet.utf8.count <= 3
          && (octet.count == 1 || octet.first != "0")
          && octet.utf8.allSatisfy({ (48...57).contains($0) })
          && UInt8(octet) != nil
      }
  }

  private static var invalidEndpoint: SOCKS5Proxy.ConfigurationError {
    .init(
      "Expected IPv4:PORT for SOCKS5 DNS (optional tcp:// prefix), without credentials, path, query, or fragment."
    )
  }

  private enum CodingKeys: String, CodingKey { case host, port }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let host = try values.decode(String.self, forKey: .host)
    let port = try values.decode(UInt16.self, forKey: .port)
    do {
      try self.init(url: "tcp://\(host):\(port)")
    } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: Self.invalidEndpoint.description))
    }
  }
}
