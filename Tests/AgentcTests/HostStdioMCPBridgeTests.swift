import AgentIsolation
import Foundation
import Testing

@testable import agentc

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

@Suite("Host stdio MCP bridge")
struct HostStdioMCPBridgeTests: Sendable {
  @Test func relayRequiresUpdatedStaticBootstrap() throws {
    let directory = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let binary = directory.appendingPathComponent("bootstrap")
    var header = Data(repeating: 0, count: 120)
    header.replaceSubrange(0..<6, with: [0x7f, 0x45, 0x4c, 0x46, 2, 1])
    header[18] = HostArchitecture.label == "arm64" ? 183 : 62
    header[32] = 64  // Program headers start after the ELF header.
    header[54] = 56
    header[56] = 1
    header[64] = 1  // PT_LOAD, not PT_INTERP.
    header.append(Data(BootstrapManager.mcpRelayArgument.utf8))
    try header.write(to: binary)
    try BootstrapManager.validateMCPRelay(at: binary)
    header[64] = 3
    try header.write(to: binary)
    #expect(throws: ACPError.self) { try BootstrapManager.validateMCPRelay(at: binary) }
    try Data("#!/bin/sh\n".utf8).write(to: binary)
    #expect(throws: ACPError.self) { try BootstrapManager.validateMCPRelay(at: binary) }
    try Data(header.prefix(120)).write(to: binary)
    #expect(throws: ACPError.self) { try BootstrapManager.validateMCPRelay(at: binary) }
  }

  @Test func optInOptionsAndSettings() throws {
    let absent = try #require(AgentcCommand.parseAsRoot(["acp"]) as? ACPCommand)
    let enabled = try #require(
      AgentcCommand.parseAsRoot(["acp", "--bridge-host-stdio-mcp"]) as? ACPCommand)
    let disabled = try #require(
      AgentcCommand.parseAsRoot(["acp", "--no-bridge-host-stdio-mcp"]) as? ACPCommand)
    #expect(absent.bridgeHostStdioMcp == nil)
    #expect(enabled.bridgeHostStdioMcp == true)
    #expect(disabled.bridgeHostStdioMcp == false)
    let settings = try JSONDecoder().decode(
      ProjectSettings.self,
      from: Data(#"{"agent":{"acp":{"bridgeHostStdioMcp":true}}}"#.utf8))
    #expect(settings.agent?.acp?.bridgeHostStdioMcp == true)
    #expect(
      disabled.bridgeHostStdioMcp ?? settings.agent?.acp?.bridgeHostStdioMcp ?? false == false)
    #expect(
      try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(settings))
        == settings)
  }

  @Test func rewritesOnlyStdio() async throws {
    let bridge = try HostStdioMCPBridge()
    do {
      let original: [ACPValue] = [
        ["name": "local", "command": "/bin/cat", "args": [], "env": [], "_meta": ["keep": true]],
        ["type": "http", "name": "remote", "url": "https://example.test/mcp", "headers": []],
        ["type": "sse", "name": "events", "url": "https://example.test/sse"],
        ["type": "unknown", "command": "opaque", "_meta": ["keep": true]],
      ]
      let request: ACPProxy.Object = ["params": ["mcpServers": .array(original)]]
      let result = try bridge.rewrite(
        request, backend: "one", cwd: FileManager.default.temporaryDirectory)
      let values = try servers(result)
      #expect(values[0].object?["command"] == .string(IsolationConfig.mcpRelayExecutable))
      #expect(values[0].object?["_meta"] == original[0].object?["_meta"])
      #expect(Array(values.dropFirst()) == Array(original.dropFirst()))
      #expect(HostStdioMCPBridge.hasStdioServers(request))
      #expect(
        !HostStdioMCPBridge.hasStdioServers([
          "params": ["mcpServers": .array(Array(original.dropFirst()))]
        ]))
    } catch {
      await bridge.shutdown()
      throw error
    }
    await bridge.shutdown()
  }

  @Test func authenticatedByteRelayAndHostContext() async throws {
    let directory = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bridge = try HostStdioMCPBridge()
    do {
      let definition: ACPValue = [
        "name": "host-test", "command": "/bin/sh",
        "args": ["-c", "printf '%s\\n' \"$MCP_TEST_VALUE\"; pwd; exec cat"],
        "env": [["name": "MCP_TEST_VALUE", "value": "literal $(not-executed)"]],
      ]
      let request: ACPProxy.Object = ["params": ["mcpServers": [definition]]]
      let rewritten = try bridge.rewrite(request, backend: "one", cwd: directory)
      let token = try token(rewritten)
      let socket = try connect(port: bridge.port)
      defer { _ = close(socket) }
      try write(socket, Array((token + "\n").utf8))
      #expect(try await read(socket, count: 3) == Array("OK\n".utf8))
      #expect(try await readLine(socket) == "literal $(not-executed)")
      let actualCwd = URL(fileURLWithPath: try await readLine(socket))
      // Linux Foundation can preserve different directory URL hints (trailing
      // slash) for the same path. Check the host cwd, not URL representation.
      #expect(
        actualCwd.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)
      let opaque: [UInt8] = [0, 255, 123, 34, 120, 34, 58, 49, 125, 10]
      try write(socket, opaque)
      let echoed = try await read(socket, count: opaque.count)
      #expect(echoed == opaque)
      bridge.stop(backend: "one")
      let revoked = try connect(port: bridge.port)
      defer { _ = close(revoked) }
      try write(revoked, Array((token + "\n").utf8))
      #expect(try await read(revoked, count: 3).isEmpty)
    } catch {
      await bridge.shutdown()
      throw error
    }
    await bridge.shutdown()
  }

  @Test func unauthorizedClientsCannotExecuteCommands() async throws {
    let bridge = try HostStdioMCPBridge()
    do {
      let socket = try connect(port: bridge.port)
      defer { _ = close(socket) }
      try write(socket, Array((String(repeating: "x", count: 64) + "\n").utf8))
      #expect(try await read(socket, count: 3).isEmpty)
      // A peer stalled during authentication must not delay shutdown.
      let stalled = try connect(port: bridge.port)
      defer { _ = close(stalled) }
      try write(stalled, Array("partial".utf8))
    } catch {
      await bridge.shutdown()
      throw error
    }
    await bridge.shutdown()
  }

  @Test func shutdownTerminatesHostProcess() async throws {
    let bridge = try HostStdioMCPBridge()
    var pid: Int32?
    do {
      let message: ACPProxy.Object = [
        "params": [
          "mcpServers": [
            [
              "name": "long-running", "command": "/bin/sh",
              "args": ["-c", "echo $$; exec sleep 60"],
            ]
          ]
        ]
      ]
      let rewritten = try bridge.rewrite(
        message, backend: "one", cwd: FileManager.default.temporaryDirectory)
      let socket = try connect(port: bridge.port)
      defer { _ = close(socket) }
      try write(socket, Array((try token(rewritten) + "\n").utf8))
      #expect(try await read(socket, count: 3) == Array("OK\n".utf8))
      var line: [UInt8] = []
      while line.last != 10, line.count < 32 {
        let next = try await read(socket, count: 1)
        guard !next.isEmpty else { break }
        line += next
      }
      pid = Int32(
        String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
      #expect(pid != nil)
    } catch {
      await bridge.shutdown()
      throw error
    }
    await bridge.shutdown()
    if let pid { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
  }

  private func servers(_ message: ACPProxy.Object) throws -> [ACPValue] {
    guard case .array(let result) = message["params"]?.object?["mcpServers"] else {
      throw ACPError("Missing rewritten servers")
    }
    return result
  }

  private func token(_ message: ACPProxy.Object) throws -> String {
    guard case .array(let args) = try servers(message)[0].object?["args"],
      let token = args.last?.string
    else { throw ACPError("Missing bridge capability") }
    return token
  }

  private func connect(port: UInt16) throws -> Int32 {
    #if canImport(Glibc)
      let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
      let fd = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { throw ACPError("socket failed") }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        #if canImport(Darwin)
          Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        #elseif canImport(Glibc)
          Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        #else
          Musl.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        #endif
      }
    }
    guard result == 0 else {
      _ = close(fd)
      throw ACPError("connect failed")
    }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
  }

  private func write(_ socket: Int32, _ bytes: [UInt8]) throws {
    let count = bytes.withUnsafeBytes { send(socket, $0.baseAddress, $0.count, 0) }
    guard count == bytes.count else { throw ACPError("test socket write failed") }
  }

  private func read(_ socket: Int32, count: Int) async throws -> [UInt8] {
    try await blockingIO { try readBlocking(socket, count: count) }
  }

  private func readBlocking(_ socket: Int32, count: Int) throws -> [UInt8] {
    var result: [UInt8] = []
    while result.count < count {
      var buffer = [UInt8](repeating: 0, count: count - result.count)
      let length = recv(socket, &buffer, buffer.count, 0)
      guard length >= 0 else { throw ACPError("test socket read failed: errno \(errno)") }
      if length == 0 { break }
      result += buffer.prefix(length)
    }
    return result
  }

  private func readLine(_ socket: Int32) async throws -> String {
    try await blockingIO {
      var bytes: [UInt8] = []
      while bytes.count < 4096 {
        let next = try readBlocking(socket, count: 1)
        if next.isEmpty || next == [10] { return String(decoding: bytes, as: UTF8.self) }
        bytes += next
      }
      throw ACPError("Test line too long")
    }
  }
}
