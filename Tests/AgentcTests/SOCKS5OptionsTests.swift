import AgentIsolation
import Foundation
import Testing

@testable import agentc

@Suite("SOCKS5 options")
struct SOCKS5OptionsTests {
  @Test func unsetAndPrecedence() throws {
    let absent = try SharedOptions.parse(["--runtime", "apple-container"])
    #expect(try absent.resolveSOCKS5Proxy() == nil)
    let settings = ProjectSettings(agent: .init(socks5Proxy: "socks5://localhost:1080"))
    #expect(try absent.resolveSOCKS5Proxy(projectSettings: settings)?.port == 1080)
    #expect(try absent.resolveSOCKS5Proxy(projectSettings: settings)?.dns == .default)
    let explicit = try SharedOptions.parse([
      "--runtime", "apple-container", "--socks5-proxy", "socks5://localhost:2080",
    ])
    #expect(try explicit.resolveSOCKS5Proxy(projectSettings: settings)?.port == 2080)
    #expect(explicit.resolveEnvironment(projectSettings: settings).isEmpty)
  }

  @Test(arguments: ["", "tcp://"])
  func dnsPrecedenceAndHostOnlyPolicy(_ prefix: String) throws {
    let settings = ProjectSettings(
      agent: .init(socks5Proxy: "socks5://localhost:1080", socks5Dns: "\(prefix)9.9.9.9:5353"))
    let inherited = try SharedOptions.parse(["--runtime", "apple-container"])
    #expect(
      try inherited.resolveSOCKS5Proxy(projectSettings: settings)?.dns
        == SOCKS5DNS(url: "9.9.9.9:5353"))
    let explicit = try SharedOptions.parse([
      "--runtime", "apple-container", "--socks5-dns", "\(prefix)8.8.8.8:53",
    ])
    #expect(
      try explicit.resolveSOCKS5Proxy(projectSettings: settings)?.dns
        == SOCKS5DNS(url: "8.8.8.8:53"))
    #expect(explicit.resolveEnvironment(projectSettings: settings).isEmpty)
    // Each field has independent CLI precedence.
    let proxyOnly = try SharedOptions.parse([
      "--runtime", "apple-container", "--socks5-proxy", "socks5://localhost:2080",
    ])
    #expect(try proxyOnly.resolveSOCKS5Proxy(projectSettings: settings)?.dns.port == 5353)
  }

  @Test func dnsWithoutProxyIsRejected() throws {
    let explicit = try SharedOptions.parse(["--socks5-dns", "9.9.9.9:53"])
    #expect(throws: SOCKS5Proxy.ConfigurationError.self) { try explicit.resolveSOCKS5Proxy() }
    let inherited = try SharedOptions.parse([])
    #expect(throws: SOCKS5Proxy.ConfigurationError.self) {
      try inherited.resolveSOCKS5Proxy(
        projectSettings: .init(agent: .init(socks5Dns: "tcp://9.9.9.9:53")))
    }
  }

  @Test func malformedDNSPolicyIsRejected() throws {
    let options = try SharedOptions.parse(["--runtime", "apple-container"])
    let settings = ProjectSettings(
      agent: .init(socks5Proxy: "socks5://localhost:1080", socks5Dns: "tcp://dns.example:53"))
    #expect(throws: SOCKS5Proxy.ConfigurationError.self) {
      try options.resolveSOCKS5Proxy(projectSettings: settings)
    }
    let explicit = try SharedOptions.parse([
      "--runtime", "apple-container", "--socks5-dns", "tcp://9.9.9.9:53",
    ])
    #expect(try explicit.resolveSOCKS5Proxy(projectSettings: settings)?.dns.host == "9.9.9.9")
  }

  @Test func initPersistsOnlyExplicitDNS() async throws {
    for dns in [nil, "9.9.9.9:5353", "tcp://9.9.9.9:5353"] as [String?] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      var arguments = [
        root.path, "--skip-container-init", "--runtime", "apple-container",
        "--socks5-proxy", "socks5://localhost:1080",
      ]
      if let dns { arguments += ["--socks5-dns", dns] }
      var command = try InitCommand.parse(arguments)
      try await command.run()
      let settings = try ProjectSettings.loadValidated(
        fromFolder: root.appendingPathComponent(".agentc"))
      #expect(settings?.agent?.socks5Dns == dns)
      #expect(settings?.agent?.socks5Proxy == "socks5://localhost:1080")
    }
  }

  @Test func initRejectsInvalidPolicyBeforeWriting() async throws {
    for policy in [
      ["--socks5-dns", "tcp://9.9.9.9:53"],
      [
        "--socks5-proxy", "socks5://localhost:1080",
        "--socks5-dns", "tcp://user:secret@9.9.9.9:53",
      ],
      [
        "--socks5-proxy", "socks5://user:secret@localhost:1080",
        "--socks5-dns", "tcp://9.9.9.9:53",
      ],
    ] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      var command = try InitCommand.parse(
        [root.path, "--skip-container-init", "--runtime", "apple-container"] + policy)
      await #expect(throws: SOCKS5Proxy.ConfigurationError.self) { try await command.run() }
      #expect(!FileManager.default.fileExists(atPath: root.path))
    }
  }

  @Test func dockerRejectsRatherThanIgnores() throws {
    let options = try SharedOptions.parse(["--runtime", "docker"])
    #expect(throws: SOCKS5Proxy.ConfigurationError.self) {
      try options.resolveSOCKS5Proxy(
        projectSettings: .init(agent: .init(socks5Proxy: "socks5://localhost:1080")))
    }
  }

  @Test func bridgeOptionsRemainCompatible() throws {
    let command = try #require(
      AgentcCommand.parseAsRoot([
        "acp", "--runtime", "apple-container", "--socks5-proxy", "socks5://localhost:1080",
        "--socks5-dns", "9.9.9.9:53", "--bridge-host-stdio-mcp", "--allow-host-binaries",
      ]) as? ACPCommand)
    #expect(command.bridgeHostStdioMcp == true)
    #expect(command.options.allowHostBinaries)
    #expect(try command.options.resolveSOCKS5Proxy()?.port == 1080)
    #expect(try command.options.resolveSOCKS5Proxy()?.dns.host == "9.9.9.9")
  }
}
