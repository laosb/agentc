import Testing

@testable import agentc_bootstrap

@Suite("Native bootstrap MCP relay")
struct MCPStdioRelayTests {
  @Test func gatewayParsing() {
    let routes = """
      Iface Destination Gateway Flags RefCnt Use Metric Mask
      eth0 0010AC00 00000000 0001 0 0 0 0000FFFF
      eth0 00000000 010011AC 0003 0 0 0 00000000
      """
    #expect(MCPStdioRelay.gateway(in: routes) == "172.17.0.1")
    #expect(MCPStdioRelay.gateway(in: "eth0 00000000 010011AC 0001") == nil)
    #expect(MCPStdioRelay.gateway(in: "invalid") == nil)
  }

  @Test func invalidArgumentsFailBeforeNetworking() {
    for args in [
      [], ["0", String(repeating: "a", count: 64)], ["123", "short"],
      ["123", String(repeating: "x", count: 64)], ["--host", "127.0.0.1"],
    ] {
      #expect(throws: MCPStdioRelay.Failure.self) { try MCPStdioRelay.run(args) }
    }
  }
}
