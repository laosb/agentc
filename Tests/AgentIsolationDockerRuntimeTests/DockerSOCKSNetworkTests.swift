#if ContainerRuntimeDocker
  import AgentIsolation
  import AgentIsolationDockerRuntime
  import Testing

  @Suite("Docker rejects enforced SOCKS networking")
  struct DockerSOCKSNetworkTests {
    @Test("prepare rejects before contacting Docker")
    func prepare() async throws {
      let runtime = try runtime()
      do {
        try await runtime.prepare()
        Issue.record("prepare unexpectedly accepted a SOCKS5 proxy")
      } catch DockerRuntimeError.socks5ProxyUnsupported {
        // Expected, without attempting the deliberately nonexistent endpoint.
      }
      try await runtime.shutdown()
    }

    @Test("runContainer also rejects when prepare was skipped")
    func runWithoutPrepare() async throws {
      let runtime = try runtime()
      do {
        _ = try await runtime.runContainer(
          imageRef: "unused", configuration: .init(entrypoint: ["true"]))
        Issue.record("runContainer unexpectedly accepted a SOCKS5 proxy")
      } catch DockerRuntimeError.socks5ProxyUnsupported {
        // Direct library entrypoints must not silently bypass enforcement.
      }
      try await runtime.shutdown()
    }

    private func runtime() throws -> DockerRuntime {
      DockerRuntime(
        config: .init(
          storagePath: "/unused", endpoint: "/nonexistent-agentc-test.sock",
          socks5Proxy: try SOCKS5Proxy(url: "socks5://127.0.0.1:1080")))
    }
  }
#endif
