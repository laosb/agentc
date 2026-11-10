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
    #expect(try SOCKS5Proxy(url: "socks5://[::1]:1080").host == "::1")
    #expect(try SOCKS5Proxy(url: "socks5://proxy.example:1080").host == "proxy.example")
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

  @Test func projectSettingRoundTrips() throws {
    let settings = ProjectSettings(agent: .init(socks5Proxy: "socks5://localhost:1080"))
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(ProjectSettings.self, from: data) == settings)
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
    for contents in ["{", #"{"agent":{"socks5Proxy":false}}"#] {
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
