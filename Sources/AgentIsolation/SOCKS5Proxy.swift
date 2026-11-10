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

  public init(url: String, environment: [String: String] = [:]) throws {
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
  }

  public struct ConfigurationError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
  }
}
