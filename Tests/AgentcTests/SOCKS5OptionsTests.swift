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
    let explicit = try SharedOptions.parse([
      "--runtime", "apple-container", "--socks5-proxy", "socks5://localhost:2080",
    ])
    #expect(try explicit.resolveSOCKS5Proxy(projectSettings: settings)?.port == 2080)
    #expect(explicit.resolveEnvironment(projectSettings: settings).isEmpty)
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
        "--bridge-host-stdio-mcp", "--allow-host-binaries",
      ]) as? ACPCommand)
    #expect(command.bridgeHostStdioMcp == true)
    #expect(command.options.allowHostBinaries)
    #expect(try command.options.resolveSOCKS5Proxy()?.port == 1080)
  }
}
