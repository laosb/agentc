#if os(macOS)
  import AgentIsolation
  import Darwin
  import Foundation
  @testable import SOCKSNetwork
  import Testing

  @Suite("Private SOCKS network child")
  struct SOCKSNetworkHelperTests {
    @Test("Wire format is bounded length-prefixed JSON with an exact host exception")
    func wireFormat() throws {
      let proxy = try SOCKS5Proxy(
        url: "socks5://127.0.0.1:1080",
        environment: [
          "AGENTC_SOCKS5_USERNAME": "test-user", "AGENTC_SOCKS5_PASSWORD": "test-pass",
        ],
        dns: SOCKS5DNS(url: "tcp://9.9.9.9:5353"))
      let config = SOCKSNetworkHelper.Configuration(proxy: proxy, hostMCPPort: 12345)
      try config.validate()
      let frame = try config.frame()
      let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      #expect(length == frame.count - 4)
      let decoded = try JSONDecoder().decode(
        SOCKSNetworkHelper.Configuration.self, from: frame.dropFirst(4))
      try decoded.validate()
      #expect(decoded.proxy == proxy)
      #expect(decoded.hostMCPPort == 12345)
    }

    @Test("DNS wire values are validated and only an absent field uses the default")
    func dnsWireValidation() throws {
      let oldWire = Data(#"{"version":1,"proxy":{"host":"localhost","port":1080}}"#.utf8)
      let oldConfig = try JSONDecoder().decode(SOCKSNetworkHelper.Configuration.self, from: oldWire)
      try oldConfig.validate()
      #expect(oldConfig.proxy.dns == .default)
      for dns in [
        "null", #"{"host":"dns.example","port":53}"#, #"{"host":"::1","port":53}"#,
        #"{"host":"127.1","port":53}"#, #"{"host":"1.1.1.1","port":0}"#,
      ] {
        let json = #"{"version":1,"proxy":{"host":"localhost","port":1080,"dns":\#(dns)}}"#
        #expect(throws: DecodingError.self) {
          try JSONDecoder().decode(SOCKSNetworkHelper.Configuration.self, from: Data(json.utf8))
        }
      }
    }

    @Test("Decoded configuration is revalidated rather than trusting Codable")
    func invalidConfiguration() throws {
      for json in [
        #"{"version":2,"proxy":{"host":"localhost","port":1080}}"#,
        #"{"version":1,"proxy":{"host":"","port":1080}}"#,
        #"{"version":1,"proxy":{"host":"localhost","port":0}}"#,
        #"{"version":1,"proxy":{"host":"localhost","port":1080,"username":"u"}}"#,
        #"{"version":1,"proxy":{"host":"localhost","port":1080},"hostMCPPort":0}"#,
      ] {
        let config = try JSONDecoder().decode(
          SOCKSNetworkHelper.Configuration.self, from: Data(json.utf8))
        #expect(throws: SOCKSNetworkHelper.HelperError.self) { try config.validate() }
      }
    }

    @Test("Stop closes descriptors and reaps the child; repeated stops are safe")
    func stop() throws {
      let fixture = try Fixture(behavior: "printf '\\001'; exec /bin/cat <&1 >/dev/null")
      defer { fixture.remove() }
      let helper = try SOCKSNetworkHelper.start(
        proxy: fixture.proxy, executableURL: fixture.executable)
      let pid = try fixture.pid()
      let fd = try helper.withPacketFileHandle { $0.fileDescriptor }
      #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
      helper.stop()
      helper.stop()
      #expect(fcntl(fd, F_GETFD) == -1)
      #expect(kill(pid, 0) == -1)
      #expect(throws: SOCKSNetworkHelper.HelperError.self) {
        try helper.withPacketFileHandle { _ in }
      }
    }

    @Test("Async launch and concurrent teardown use the same lifecycle")
    func concurrentStop() async throws {
      let fixture = try Fixture(behavior: "printf '\\001'; exec /bin/cat <&1 >/dev/null")
      defer { fixture.remove() }
      let helper = try await SOCKSNetworkHelper.launch(
        proxy: fixture.proxy, executableURL: fixture.executable)
      let pid = try fixture.pid()
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
          group.addTask { await helper.stopAsync() }
        }
      }
      #expect(kill(pid, 0) == -1)
    }

    @Test("Dropping the owner also terminates the child")
    func deinitStops() throws {
      let fixture = try Fixture(behavior: "printf '\\001'; exec /bin/cat <&1 >/dev/null")
      defer { fixture.remove() }
      var helper: SOCKSNetworkHelper? = try .start(
        proxy: fixture.proxy, executableURL: fixture.executable)
      let pid = try fixture.pid()
      #expect(helper != nil)
      helper = nil
      #expect(kill(pid, 0) == -1)
    }

    @Test("A child that never becomes ready is killed after a bounded deadline")
    func timeout() throws {
      let fixture = try Fixture(behavior: "exec /bin/sleep 30")
      defer { fixture.remove() }
      let start = ContinuousClock.now
      #expect(throws: SOCKSNetworkHelper.HelperError.self) {
        try SOCKSNetworkHelper.start(
          proxy: fixture.proxy, executableURL: fixture.executable, startupTimeout: 0.2)
      }
      #expect(start.duration(to: .now) < .seconds(3))
      let pid = try fixture.pid()
      #expect(kill(pid, 0) == -1)
    }

    @Test("Wrong readiness and immediate child failure fail closed")
    func invalidReadiness() throws {
      for behavior in ["printf '\\002'; exec /bin/cat <&1 >/dev/null", "exit 1"] {
        let fixture = try Fixture(behavior: behavior)
        defer { fixture.remove() }
        #expect(throws: SOCKSNetworkHelper.HelperError.self) {
          try SOCKSNetworkHelper.start(proxy: fixture.proxy, executableURL: fixture.executable)
        }
        let pid = try fixture.pid()
        #expect(kill(pid, 0) == -1)
      }
    }

    @Test("Normal invocations do not enter private mode")
    func normalMode() async {
      #expect(await SOCKSNetworkHelper.runPrivateMode(arguments: ["agentc", "run"]) == nil)
      #expect(
        await SOCKSNetworkHelper.runPrivateMode(
          arguments: ["agentc", SOCKSNetworkHelper.privateArgument, "extra"]) == 64)
    }

    private struct Fixture {
      let directory: URL
      let executable: URL
      let proxy: SOCKS5Proxy

      init(behavior: String) throws {
        directory = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
        executable = directory.appendingPathComponent("child")
        proxy = try SOCKS5Proxy(url: "socks5://127.0.0.1:1080")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Uses only system tools. The shell intentionally acts as a stand-in for
        // the engine: lifecycle tests don't require a proxy, VM, or network.
        let script = """
          #!/bin/sh
          test "$#" = 1 && test "$1" = "--agentc-socks-network-v1" || exit 2
          test -z "${AGENTC_SOCKS5_PASSWORD+x}" || exit 3
          test -z "${DYLD_INSERT_LIBRARIES+x}" || exit 4
          echo $$ > '\(directory.appendingPathComponent("pid").path)'
          \(behavior)
          """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: executable.path)
      }

      func pid() throws -> pid_t {
        let text = try String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8)
        return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
      }

      func remove() { try? FileManager.default.removeItem(at: directory) }
    }
  }
#endif
