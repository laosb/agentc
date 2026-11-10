#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Host-only proxy configuration. Never pass this through the guest environment.
public struct SOCKS5Proxy: Codable, Sendable, Equatable {
  public let host: String
  public let port: UInt16
  public let username: String?
  public let password: String?
  public let dns: SOCKS5DNS

  public init(
    url: String, environment: [String: String] = [:], dns: SOCKS5DNS = .default
  ) throws {
    guard let parts = URLComponents(string: url),
      parts.scheme == "socks5", let host = parts.host, !host.isEmpty,
      let port = parts.port, (1...65535).contains(port),
      parts.user == nil, parts.password == nil,
      parts.path.isEmpty, parts.query == nil, parts.fragment == nil,
      !host.contains("\0")
    else {
      throw ConfigurationError(
        "Expected socks5://HOST:PORT without credentials, path, query, or fragment.")
    }
    let username = environment["AGENTC_SOCKS5_USERNAME"]
    let password = environment["AGENTC_SOCKS5_PASSWORD"]
    guard (username == nil) == (password == nil),
      [username, password].compactMap({ $0 }).allSatisfy({
        (1...255).contains($0.utf8.count) && !$0.contains("\0")
      })
    else {
      throw ConfigurationError(
        "Set both AGENTC_SOCKS5_USERNAME and AGENTC_SOCKS5_PASSWORD (1–255 UTF-8 bytes each), or neither."
      )
    }
    self.host = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
    self.port = UInt16(port)
    self.username = username
    self.password = password
    self.dns = dns
  }

  private enum CodingKeys: String, CodingKey { case host, port, username, password, dns }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    host = try values.decode(String.self, forKey: .host)
    port = try values.decode(UInt16.self, forKey: .port)
    username = try values.decodeIfPresent(String.self, forKey: .username)
    password = try values.decodeIfPresent(String.self, forKey: .password)
    // Older helper fixtures omit DNS. A supplied but invalid value (including
    // null) must never silently fall back to the default resolver.
    dns = try values.contains(.dns) ? values.decode(SOCKS5DNS.self, forKey: .dns) : .default
  }

  public struct ConfigurationError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
  }
}
