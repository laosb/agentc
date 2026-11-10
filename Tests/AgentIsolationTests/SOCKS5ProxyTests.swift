import AgentIsolation
import Foundation
import Testing

@Suite("SOCKS5 configuration")
struct SOCKS5ProxyTests {
  @Test func endpointAndHostOnlyCredentials() throws {
    let proxy = try SOCKS5Proxy(
      url: "socks5://127.0.0.1:1080",
      environment: [
        "AGENTC_SOCKS5_USERNAME": "test-user", "AGENTC_SOCKS5_PASSWORD": "test-password",
      ])
    #expect(proxy.host == "127.0.0.1")
    #expect(proxy.port == 1080)
    #expect(proxy.username == "test-user")
    #expect(proxy.password == "test-password")
    #expect(proxy.dns == .default)
    #expect(try SOCKS5Proxy(url: "socks5://[::1]:1080").host == "::1")
    #expect(try SOCKS5Proxy(url: "socks5://proxy.example:1080").host == "proxy.example")
  }

  @Test func dnsEndpointAndWireRoundTrip() throws {
    #expect(SOCKS5DNS.default.host == "1.1.1.1")
    #expect(SOCKS5DNS.default.port == 53)
    let dns = try SOCKS5DNS(url: "9.9.9.9:0053")
    #expect(dns.host == "9.9.9.9")
    #expect(dns.port == 53)
    #expect(try SOCKS5DNS(url: "tcp://9.9.9.9:0053") == dns)
    #expect(try SOCKS5DNS(url: "192.0.2.255:65535").port == 65535)
    let proxy = try SOCKS5Proxy(url: "socks5://localhost:1080", dns: dns)
    #expect(try JSONDecoder().decode(SOCKS5Proxy.self, from: JSONEncoder().encode(proxy)) == proxy)
    let oldWire = Data(#"{"host":"localhost","port":1080}"#.utf8)
    #expect(try JSONDecoder().decode(SOCKS5Proxy.self, from: oldWire).dns == .default)
  }

  @Test(arguments: [
    "", "udp://1.1.1.1:53", "TCP://1.1.1.1:53", "tcp://dns.example:53",
    "tcp://[::1]:53", "tcp://::1:53", "tcp://127.1:53", "tcp://2130706433:53",
    "tcp://0x7f.0.0.1:53", "tcp://01.1.1.1:53", "tcp://1.1.1.256:53",
    "tcp://1.1.1.-1:53", "tcp://1.1.1.+1:53", "tcp://1.1.1.1.:53",
    "tcp://1..1.1:53", "tcp://1.1.1.1", "tcp://1.1.1.1:", "tcp://1.1.1.1:0",
    "tcp://1.1.1.1:65536", "tcp://1.1.1.1:-53", "tcp://1.1.1.1:+53",
    "tcp://1.1.1.1:５３", "tcp://１.1.1.1:53", "tcp://1.1.1.1:53/",
    "tcp://1.1.1.1:53/path", "tcp://1.1.1.1:53?query", "tcp://1.1.1.1:53#fragment",
    "tcp://user:secret@1.1.1.1:53", "tcp://@1.1.1.1:53", "tcp://%31.1.1.1:53",
    " tcp://1.1.1.1:53", "tcp://1.1.1.1:53\n", "tcp://1.1.1.1:53\0",
  ])
  func invalidDNSEndpoint(_ value: String) {
    #expect(throws: SOCKS5Proxy.ConfigurationError.self) { try SOCKS5DNS(url: value) }
    if value.hasPrefix("tcp://") {
      #expect(throws: SOCKS5Proxy.ConfigurationError.self) {
        try SOCKS5DNS(url: String(value.dropFirst("tcp://".count)))
      }
    }
  }

  @Test func repeatedDNSSchemeIsRejected() {
    #expect(throws: SOCKS5Proxy.ConfigurationError.self) {
      try SOCKS5DNS(url: "tcp://tcp://1.1.1.1:53")
    }
  }

  @Test(arguments: [
    "null", "false", #""tcp://9.9.9.9:53""#, "{}",
    #"{"host":"dns.example","port":53}"#, #"{"host":"::1","port":53}"#,
    #"{"host":"127.1","port":53}"#, #"{"host":"01.1.1.1","port":53}"#,
    #"{"host":"1.1.1.1","port":0}"#, #"{"host":"1.1.1.1","port":65536}"#,
    #"{"host":"1.1.1.1","port":-1}"#, #"{"host":"1.1.1.1","port":"53"}"#,
    #"{"host":"1.1.1.1:53","port":53}"#,
    #"{"host":"tcp://1.1.1.1","port":53}"#,
  ])
  func invalidDNSWireCannotFallBack(_ dns: String) {
    let wire = Data(#"{"host":"localhost","port":1080,"dns":\#(dns)}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(SOCKS5Proxy.self, from: wire) }
  }

  @Test(arguments: [
    "", "http://localhost:1080", "socks5h://localhost:1080", "socks5://localhost",
    "socks5://localhost:0", "socks5://localhost:65536", "socks5://localhost:1080/path",
    "socks5://localhost:1080?x=1", "socks5://localhost:1080#fragment",
    "socks5://user:password@localhost:1080",
  ])
  func invalidEndpointNeverDisablesProxy(_ value: String) {
    #expect(throws: SOCKS5Proxy.ConfigurationError.self) { try SOCKS5Proxy(url: value) }
  }

  @Test func invalidCredentialsAreRejectedWithoutEchoingThem() {
    for environment in [
      ["AGENTC_SOCKS5_USERNAME": "test-user"],
      ["AGENTC_SOCKS5_PASSWORD": "test-password"],
      ["AGENTC_SOCKS5_USERNAME": "", "AGENTC_SOCKS5_PASSWORD": "test-password"],
      [
        "AGENTC_SOCKS5_USERNAME": "test-user",
        "AGENTC_SOCKS5_PASSWORD": String(repeating: "x", count: 256),
      ],
    ] {
      do {
        _ = try SOCKS5Proxy(url: "socks5://localhost:1080", environment: environment)
        Issue.record("Invalid credentials accepted")
      } catch {
        #expect(!String(describing: error).contains("test-password"))
      }
    }
  }

  @Test(arguments: ["9.9.9.9:53", "tcp://9.9.9.9:53"])
  func projectSettingRoundTrips(_ dns: String) throws {
    let settings = ProjectSettings(
      agent: .init(socks5Proxy: "socks5://localhost:1080", socks5Dns: dns))
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(ProjectSettings.self, from: data) == settings)
    let oldSettings = Data(#"{"agent":{"socks5Proxy":"socks5://localhost:1080"}}"#.utf8)
    #expect(
      try JSONDecoder().decode(ProjectSettings.self, from: oldSettings).agent?.socks5Dns == nil)
  }

  @Test func malformedSettingsCannotFallBackToUnrestrictedNetworking() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let parent = root.appendingPathComponent(".agentc")
    let child = root.appendingPathComponent("child")
    let policy = child.appendingPathComponent(".agentc")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: policy, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"agent":{"socks5Proxy":"socks5://localhost:1080"}}"#.utf8)
      .write(to: parent.appendingPathComponent("settings.json"))
    #expect(try ProjectSettings.findValidated(from: child)?.agent?.socks5Proxy != nil)
    for contents in [
      "{", #"{"agent":{"socks5Proxy":false}}"#, #"{"agent":{"socks5Dns":false}}"#,
    ] {
      try Data(contents.utf8).write(to: policy.appendingPathComponent("settings.json"))
      #expect(throws: SOCKS5Proxy.ConfigurationError.self) {
        try ProjectSettings.findValidated(from: child)
      }
      #expect(throws: SOCKS5Proxy.ConfigurationError.self) {
        try ProjectSettings.loadValidated(fromFolder: policy)
      }
    }
  }
}
