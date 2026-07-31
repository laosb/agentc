#if ContainerRuntimeDocker
  import AgentIsolation
  @testable import AgentIsolationDockerRuntime
  import Foundation
  import Testing

  // MARK: - Create Request Environment Unit Tests

  /// Unlike the Apple runtime, the Docker runtime does not reconcile our variables with the
  /// image's `ENV` — the daemon merges them by name, with ours winning. So these tests pin
  /// what we put on the wire; ``DockerRuntimeEnvironmentIntegrationTests`` pins the merge
  /// the daemon performs.
  @Suite("DockerRuntime Create Request Environment")
  struct DockerCreateRequestEnvironmentTests {

    private func request(
      environment: [String: String],
      entrypoint: [String] = ["echo", "hi"]
    ) -> DockerCreateContainerRequest {
      DockerRuntime.makeCreateRequest(
        imageRef: "alpine:latest",
        configuration: ContainerConfiguration(
          entrypoint: entrypoint,
          environment: environment,
          io: .standardIO
        )
      )
    }

    /// Parse `Env` back into names → values for order-independent checks.
    private func parsed(_ entries: [String]) -> [String: String] {
      var result: [String: String] = [:]
      for entry in entries {
        guard let separator = entry.firstIndex(of: "=") else { continue }
        if result[String(entry[..<separator])] == nil {
          result[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
      }
      return result
    }

    // MARK: - Absent vs. present

    @Test("Env is nil when no variables are set, leaving the image's ENV untouched")
    func envOmittedWhenEmpty() {
      #expect(request(environment: [:]).Env == nil)
    }

    @Test("Env is omitted from the JSON payload when no variables are set")
    func envAbsentFromJSON() throws {
      let data = try JSONEncoder().encode(request(environment: [:]))
      let json = String(decoding: data, as: UTF8.self)
      #expect(!json.contains("\"Env\""))
      // And it is present once variables exist.
      let withEnv = try JSONEncoder().encode(request(environment: ["TZ": "UTC"]))
      #expect(String(decoding: withEnv, as: UTF8.self).contains("\"Env\":[\"TZ=UTC\"]"))
    }

    @Test("Env carries every variable as a single KEY=VALUE entry")
    func envEntries() {
      let env = request(environment: ["TZ": "America/Los_Angeles", "LC_ALL": "en_US.UTF-8"]).Env
      #expect(env == ["LC_ALL=en_US.UTF-8", "TZ=America/Los_Angeles"])
    }

    @Test("Every variable reaches the payload exactly once")
    func allVariablesPresentOnce() {
      let environment = ["TZ": "UTC", "LANG": "C.UTF-8", "FOO": "bar", "PATH": "/opt/bin"]
      let env = request(environment: environment).Env ?? []
      #expect(env.count == environment.count)
      for (name, value) in environment {
        #expect(env.filter { $0.hasPrefix("\(name)=") } == ["\(name)=\(value)"])
      }
    }

    // MARK: - Determinism

    @Test("Entries are sorted, so the same configuration always yields the same payload")
    func entriesAreSorted() {
      let environment = [
        "TZ": "UTC", "LC_ALL": "en_US.UTF-8", "AGENTC_CONFIGURATIONS": "claude",
        "EDITOR": "vim", "LANG": "en_US.UTF-8",
      ]
      let expected = [
        "AGENTC_CONFIGURATIONS=claude",
        "EDITOR=vim",
        "LANG=en_US.UTF-8",
        "LC_ALL=en_US.UTF-8",
        "TZ=UTC",
      ]
      // Repeat: dictionary iteration order varies per instance, so a single pass could
      // pass by luck if the output depended on it.
      for _ in 0..<10 {
        #expect(request(environment: environment).Env == expected)
      }
    }

    // MARK: - Value shapes

    @Test("Empty value is sent as a set-but-empty variable")
    func emptyValue() {
      let env = request(environment: ["EMPTY": ""]).Env
      #expect(env == ["EMPTY="])
      #expect(parsed(env ?? [])["EMPTY"] == "")
    }

    @Test("Values containing '=' are preserved intact")
    func valueWithEquals() {
      let env = request(environment: ["JAVA_TOOL_OPTIONS": "-Dfoo=bar -Dbaz=qux"]).Env
      #expect(env == ["JAVA_TOOL_OPTIONS=-Dfoo=bar -Dbaz=qux"])
    }

    @Test("Values with spaces, newlines, and non-ASCII text survive JSON encoding")
    func exoticValuesRoundTrip() throws {
      let environment = [
        "SPACED": "a b  c",
        "MULTILINE": "line1\nline2",
        "UNICODE": "日本語 🌏",
        "QUOTED": #"say "hi""#,
      ]
      let data = try JSONEncoder().encode(request(environment: environment))
      let decoded = try JSONDecoder().decode(DockerCreateContainerRequest.self, from: data)
      #expect(parsed(decoded.Env ?? []) == environment)
    }

    // MARK: - Independence from other fields

    @Test("Setting variables does not disturb entrypoint dispatch")
    func envDoesNotAffectEntrypoint() {
      let withEnv = request(environment: ["TZ": "UTC"], entrypoint: ["echo", "hi"])
      let without = request(environment: [:], entrypoint: ["echo", "hi"])
      #expect(withEnv.Cmd == without.Cmd)
      #expect(withEnv.Entrypoint == without.Entrypoint)
      #expect(withEnv.Cmd == ["echo", "hi"])
      #expect(withEnv.Entrypoint == nil)
    }

    @Test("Variables are sent the same way when the image entrypoint is overridden")
    func envWithEntrypointOverride() {
      let request = DockerRuntime.makeCreateRequest(
        imageRef: "alpine:latest",
        configuration: ContainerConfiguration(
          entrypoint: ["/entrypoint-bootstrap/bootstrap"],
          overridesImageEntrypoint: true,
          environment: ["TZ": "UTC"],
          io: .standardIO
        )
      )
      #expect(request.Env == ["TZ=UTC"])
      #expect(request.Entrypoint == ["/entrypoint-bootstrap/bootstrap"])
      #expect(request.Cmd == nil)
    }
  }

  // MARK: - Environment Integration Tests

  @Suite("DockerRuntime Environment Integration", .enabled(if: isDockerAvailable()))
  struct DockerRuntimeEnvironmentIntegrationTests {

    private func makeRuntime() -> DockerRuntime {
      let endpoint = ProcessInfo.processInfo.environment["CLAUDEC_DOCKER_ENDPOINT"]
      let config = ContainerRuntimeConfiguration(
        storagePath: "/tmp/claudec-test-docker", endpoint: endpoint)
      return DockerRuntime(config: config)
    }

    /// Run `sh -c script` in alpine and return its stdout.
    private func capture(script: String, environment: [String: String]) async throws -> (
      exitCode: Int32, stdout: String
    ) {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()

      _ = try await runtime.pullImage(ref: "alpine:latest")

      let stdout = MockWriter()
      let container = try await runtime.runContainer(
        imageRef: "alpine:latest",
        configuration: ContainerConfiguration(
          entrypoint: ["/bin/sh", "-c", script],
          environment: environment,
          io: .custom(stdin: EmptyReaderStream(), stdout: stdout, stderr: MockWriter())
        )
      )

      let exitCode = try await container.wait(timeoutInSeconds: 30)
      try await runtime.removeContainer(container)
      return (exitCode, stdout.string)
    }

    @Test("Our value overrides a variable the image already sets")
    func overridesImageEnv() async throws {
      // alpine's image config sets PATH; keep the real directories on it so the shell
      // still works, and prepend a marker we can assert on.
      let result = try await capture(
        script: "printf '%s' \"$PATH\"",
        environment: ["PATH": "/custom/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
      )
      #expect(result.exitCode == 0)
      #expect(result.stdout == "/custom/bin:/usr/sbin:/usr/bin:/sbin:/bin")
    }

    @Test("Variables the image sets are inherited when we do not override them")
    func inheritsImageEnv() async throws {
      let result = try await capture(
        script: "printf '%s|%s' \"$PATH\" \"$TZ\"",
        environment: ["TZ": "Europe/Berlin"]
      )
      #expect(result.exitCode == 0)
      // The image's PATH survives alongside the variable we added.
      #expect(result.stdout.hasSuffix("|Europe/Berlin"))
      #expect(result.stdout.contains("/usr/bin"))
      #expect(!result.stdout.hasPrefix("|"))
    }

    @Test("An empty value arrives as a set-but-empty variable, not as unset")
    func emptyValueIsSet() async throws {
      // `${VAR+set}` expands to "set" only when VAR is defined, empty or not.
      let result = try await capture(
        script: "printf '%s|%s' \"${EMPTY+set}\" \"${EMPTY}\"",
        environment: ["EMPTY": ""]
      )
      #expect(result.exitCode == 0)
      #expect(result.stdout == "set|")
    }

    @Test("A value containing '=' arrives intact")
    func valueWithEqualsArrivesIntact() async throws {
      let result = try await capture(
        script: "printf '%s' \"$OPTS\"",
        environment: ["OPTS": "-Dfoo=bar -Dbaz=qux"]
      )
      #expect(result.exitCode == 0)
      #expect(result.stdout == "-Dfoo=bar -Dbaz=qux")
    }
  }
#endif
