#if ContainerRuntimeDocker
  import AgentIsolation
  @testable import AgentIsolationDockerRuntime
  import Foundation
  import Testing

  // MARK: - Classification

  @Suite("DockerRuntimeSelection Classification")
  struct DockerRuntimeClassificationTests {

    @Test(
      "Kata aliases and shims classify as kata",
      arguments: [
        "kata", "Kata", "kata-runtime", "kata-qemu", "kata-clh", "kata-fc",
        "io.containerd.kata.v2", "io.containerd.kata-qemu.v2",
        // The form Kata's own Docker guide tells administrators to register.
        "/opt/kata/bin/containerd-shim-kata-v2",
      ])
    func kataAliases(name: String) {
      #expect(DockerRuntimeSelection.classify(token: name) == .kata)
    }

    @Test(
      "gVisor aliases and shims classify as gVisor",
      arguments: [
        "runsc", "RunSC", "gvisor", "runsc-kvm", "io.containerd.runsc.v1",
        "/usr/local/bin/containerd-shim-runsc-v1",
      ])
    func gVisorAliases(name: String) {
      #expect(DockerRuntimeSelection.classify(token: name) == .gVisor)
    }

    @Test(
      "runc aliases and shims classify as standard",
      arguments: [
        "runc", "io.containerd.runc.v2", "io.containerd.runc", "/usr/bin/runc",
      ])
    func standardAliases(name: String) {
      #expect(DockerRuntimeSelection.classify(token: name) == .standard)
    }

    /// Guessing wrong in either direction is worse than admitting we don't know: calling an
    /// unknown runtime `standard` cries wolf, calling it hardened hides a real risk.
    @Test(
      "Unrecognized names stay unknown rather than being guessed",
      arguments: ["crun", "sandbox", "youki", "sysbox-runc", "", "io.containerd.runhcs.v1"])
    func unknownAliases(name: String) {
      #expect(DockerRuntimeSelection.classify(token: name) == .unknown)
    }

    @Test("An opaque alias is classified by its containerd shim type")
    func classifyByShimType() {
      let kind = DockerRuntimeSelection.classify(
        name: "secure-vm", entry: .init(runtimeType: "io.containerd.kata.v2"))
      #expect(kind == .kata)
    }

    /// Kata's Docker guide registers `runtimeType` as an absolute path to the shim binary
    /// rather than the shim's reverse-DNS name.
    @Test("An opaque alias is classified by a shim registered as a binary path")
    func classifyByShimPath() {
      let kind = DockerRuntimeSelection.classify(
        name: "secure-vm", entry: .init(runtimeType: "/opt/kata/bin/containerd-shim-kata-v2"))
      #expect(kind == .kata)
    }

    @Test("An opaque alias is classified by its runtime binary path")
    func classifyByBinaryPath() {
      let kind = DockerRuntimeSelection.classify(
        name: "sandbox", entry: .init(path: "/usr/local/bin/runsc"))
      #expect(kind == .gVisor)
    }

    @Test("An alias with no usable hints stays unknown")
    func classifyWithoutHints() {
      let kind = DockerRuntimeSelection.classify(
        name: "sandbox", entry: .init(path: "/opt/vendor/bin/sandboxd"))
      #expect(kind == .unknown)
    }
  }

  // MARK: - Selection

  @Suite("DockerRuntimeSelection Selection")
  struct DockerRuntimeSelectionTests {

    private func info(
      _ runtimes: [String: DockerInfo.RuntimeEntry], default defaultRuntime: String? = "runc"
    ) -> DockerInfo {
      // Round-trip through JSON so the tests exercise the decoder we actually ship.
      let payload: [String: Any] = [
        "Runtimes": runtimes.mapValues { entry -> [String: Any] in
          var value: [String: Any] = [:]
          if let path = entry.path { value["path"] = path }
          if let type = entry.runtimeType { value["runtimeType"] = type }
          // Fields we deliberately ignore, present on every real daemon response.
          value["status"] = ["org.opencontainers.runtime-spec.features": "{}"]
          return value
        },
        "DefaultRuntime": defaultRuntime as Any,
        "ServerVersion": "27.0.0",
      ]
      let data = try! JSONSerialization.data(withJSONObject: payload)
      return try! JSONDecoder().decode(DockerInfo.self, from: data)
    }

    // MARK: Explicit configuration

    @Test("An explicit runtime wins over anything discoverable")
    func configuredWins() {
      let selection = DockerRuntimeSelection.select(
        configured: "runc", info: info(["runc": .init(), "kata": .init(), "runsc": .init()]))
      #expect(selection.name == "runc")
      #expect(selection.kind == .standard)
      #expect(selection.source == .configured)
    }

    /// The documented escape hatch: choosing `runc` on purpose is a decision, not a mistake.
    @Test("An explicit runc choice silences the warning")
    func configuredRuncIsNotWarnedAbout() {
      let selection = DockerRuntimeSelection.select(
        configured: "runc", info: info(["runc": .init()]))
      #expect(selection.warning == nil)
    }

    @Test("An unrecognized explicit alias is used as-is and not questioned")
    func configuredCustomAlias() {
      let selection = DockerRuntimeSelection.select(
        configured: "io.containerd.my-vendor-shim.v1", info: nil)
      #expect(selection.name == "io.containerd.my-vendor-shim.v1")
      #expect(selection.kind == .unknown)
      #expect(selection.source == .configured)
      #expect(selection.warning == nil)
    }

    @Test("Surrounding whitespace is trimmed from an explicit alias")
    func configuredIsTrimmed() {
      #expect(DockerRuntimeSelection.select(configured: "  runsc  ", info: nil).name == "runsc")
    }

    @Test("A blank explicit alias falls through to discovery")
    func blankConfiguredFallsThrough() {
      let selection = DockerRuntimeSelection.select(
        configured: "   ", info: info(["runc": .init(), "runsc": .init()]))
      #expect(selection.name == "runsc")
      #expect(selection.source == .discovered)
    }

    // MARK: Preference order

    @Test("Kata is preferred over gVisor and runc")
    func prefersKata() {
      let selection = DockerRuntimeSelection.select(
        configured: nil, info: info(["runc": .init(), "runsc": .init(), "kata": .init()]))
      #expect(selection.name == "kata")
      #expect(selection.kind == .kata)
      #expect(selection.source == .discovered)
      #expect(selection.warning == nil)
    }

    @Test("gVisor is preferred over runc when Kata is absent")
    func prefersGVisor() {
      let selection = DockerRuntimeSelection.select(
        configured: nil, info: info(["runc": .init(), "runsc": .init()]))
      #expect(selection.name == "runsc")
      #expect(selection.kind == .gVisor)
      #expect(selection.warning == nil)
    }

    @Test("A hardened runtime hiding behind an opaque alias is still found")
    func findsAliasedHardenedRuntime() {
      let selection = DockerRuntimeSelection.select(
        configured: nil,
        info: info([
          "runc": .init(path: "/usr/bin/runc"),
          "vm": .init(runtimeType: "io.containerd.kata.v2"),
        ]))
      #expect(selection.name == "vm")
      #expect(selection.kind == .kata)
    }

    /// Several runtimes of one kind must not make the choice depend on dictionary order.
    @Test("Ties are broken deterministically, preferring canonical names")
    func deterministicTieBreak() {
      let entries = ["kata-clh": DockerInfo.RuntimeEntry(), "kata-qemu": .init(), "kata": .init()]
      for _ in 0..<20 {
        #expect(DockerRuntimeSelection.select(configured: nil, info: info(entries)).name == "kata")
      }
      let noCanonical = ["kata-fc": DockerInfo.RuntimeEntry(), "kata-clh": .init()]
      for _ in 0..<20 {
        #expect(
          DockerRuntimeSelection.select(configured: nil, info: info(noCanonical)).name == "kata-clh"
        )
      }
    }

    @Test("The default runtime is considered even when absent from the runtimes map")
    func defaultRuntimeIsFoldedIn() {
      let selection = DockerRuntimeSelection.select(
        configured: nil, info: info([:], default: "kata"))
      #expect(selection.name == "kata")
      #expect(selection.kind == .kata)
    }

    // MARK: runc-only warning

    @Test("A runc-only host selects runc and warns")
    func runcOnlyWarns() throws {
      let selection = DockerRuntimeSelection.select(
        configured: nil, info: info(["runc": .init(path: "/usr/bin/runc")]))
      #expect(selection.name == "runc")
      #expect(selection.kind == .standard)
      #expect(selection.source == .discovered)

      let warning = try #require(selection.warning)
      #expect(warning.contains("only exposes the standard `runc` runtime"))
      #expect(warning.contains("kata-containers/kata-containers"))
      #expect(warning.contains("gvisor.dev/docs/user_guide/quick_start/docker/"))
      #expect(warning.contains("docs.docker.com/engine/daemon/alternative-runtimes/"))
      #expect(warning.contains("docs.docker.com/reference/cli/dockerd/"))
      // The warning has to carry its own opt-out, or it is just noise the user can't act on.
      #expect(warning.contains("--docker-runtime runc"))
    }

    @Test("Unrecognized runtimes on a runc-only host are named in the warning")
    func warningNamesUnclassifiedRuntimes() throws {
      let selection = DockerRuntimeSelection.select(
        configured: nil, info: info(["runc": .init(), "crun": .init(), "youki": .init()]))
      #expect(selection.name == "runc")
      #expect(selection.unclassifiedNames == ["crun", "youki"])

      let warning = try #require(selection.warning)
      #expect(warning.contains("crun, youki"))
    }

    // MARK: Discovery failures

    @Test("An unreadable daemon info falls back to the daemon default and warns")
    func noInfoUsesDaemonDefault() throws {
      let selection = DockerRuntimeSelection.select(configured: nil, info: nil)
      #expect(selection.name == nil)
      #expect(selection.source == .daemonDefault)

      let warning = try #require(selection.warning)
      #expect(warning.contains("Could not determine"))
      // We must not claim to know the host is runc-only when we could not look.
      #expect(!warning.contains("only exposes"))
      #expect(warning.contains("--docker-runtime"))
    }

    @Test("A host with only unrecognized runtimes defers to the daemon default and warns")
    func onlyUnknownRuntimes() throws {
      let selection = DockerRuntimeSelection.select(
        configured: nil, info: info(["youki": .init()], default: "youki"))
      #expect(selection.name == nil)
      #expect(selection.kind == .unknown)
      #expect(selection.source == .daemonDefault)

      let warning = try #require(selection.warning)
      #expect(warning.contains("youki"))
    }
  }

  // MARK: - Create Request

  @Suite("DockerRuntime Create Request Runtime")
  struct DockerCreateRequestRuntimeTests {

    private func request(runtimeName: String?) -> DockerCreateContainerRequest {
      DockerRuntime.makeCreateRequest(
        imageRef: "alpine:latest",
        configuration: ContainerConfiguration(entrypoint: ["echo", "hi"], io: .standardIO),
        runtimeName: runtimeName)
    }

    @Test("The selected runtime is sent as HostConfig.Runtime")
    func runtimeIsSent() throws {
      #expect(request(runtimeName: "runsc").HostConfig?.Runtime == "runsc")
      let json = String(
        decoding: try JSONEncoder().encode(request(runtimeName: "runsc")), as: UTF8.self)
      #expect(json.contains("\"Runtime\":\"runsc\""))
    }

    @Test("HostConfig.Runtime is omitted entirely when no runtime was selected")
    func runtimeOmitted() throws {
      #expect(request(runtimeName: nil).HostConfig?.Runtime == nil)
      let json = String(
        decoding: try JSONEncoder().encode(request(runtimeName: nil)), as: UTF8.self)
      #expect(!json.contains("\"Runtime\""))
    }

    /// The rest of the create payload is what it always was — runtime selection is the
    /// only thing this change touches.
    @Test("Selecting a runtime changes nothing else in the payload")
    func onlyRuntimeChanges() throws {
      let with = request(runtimeName: "kata")
      let without = request(runtimeName: nil)
      #expect(with.Image == without.Image)
      #expect(with.Cmd == without.Cmd)
      #expect(with.HostConfig?.Binds == without.HostConfig?.Binds)
      #expect(with.HostConfig?.Memory == without.HostConfig?.Memory)
      #expect(with.HostConfig?.NanoCpus == without.HostConfig?.NanoCpus)
      #expect(with.HostConfig?.CpusetCpus == without.HostConfig?.CpusetCpus)
      #expect(with.HostConfig?.Init == without.HostConfig?.Init)
    }
  }

  // MARK: - Failure Surfacing

  @Suite("DockerRuntime Runtime Failure Surfacing")
  struct DockerRuntimeFailureSurfacingTests {

    private func selection(_ name: String?, _ kind: DockerRuntimeKind) -> DockerRuntimeSelection {
      .init(name: name, kind: kind, source: .configured)
    }

    @Test("A create failure under a hardened runtime is reported as a runtime failure")
    func hardenedFailureIsSurfaced() throws {
      let error = DockerRuntime.surfaceRuntimeFailure(
        DockerRuntimeError.apiError(400, "Unknown runtime specified kata"),
        runtime: selection("kata", .kata))

      let described = try #require((error as? DockerRuntimeError)?.errorDescription)
      #expect(described.contains("`kata`"))
      #expect(described.contains("Unknown runtime specified kata"))
      // The whole point: the user learns the container did not start, not that it quietly ran.
      #expect(described.contains("was not started"))
    }

    @Test("An unrecognized configured alias also surfaces as a runtime failure")
    func customAliasFailureIsSurfaced() {
      let error = DockerRuntime.surfaceRuntimeFailure(
        DockerRuntimeError.apiError(400, "Unknown runtime"),
        runtime: selection("my-shim", .unknown))
      guard case DockerRuntimeError.runtimeUnavailable(let runtime, _) = error else {
        Issue.record("expected runtimeUnavailable, got \(error)")
        return
      }
      #expect(runtime == "my-shim")
    }

    /// A missing image is not a runtime problem; dressing it up as one sends the user off
    /// to debug their Kata install.
    @Test("A create failure the daemon blames on something else is passed through")
    func unrelatedFailureIsUntouched() {
      let error = DockerRuntime.surfaceRuntimeFailure(
        DockerRuntimeError.apiError(404, "No such image: alpine:latest"),
        runtime: selection("kata", .kata))
      guard case DockerRuntimeError.apiError(let code, _) = error else {
        Issue.record("expected the original apiError, got \(error)")
        return
      }
      #expect(code == 404)
    }

    @Test("A plain runc failure is passed through untouched")
    func standardFailureIsUntouched() {
      let original = DockerRuntimeError.apiError(500, "no space left on device")
      let error = DockerRuntime.surfaceRuntimeFailure(
        original, runtime: selection("runc", .standard))
      guard case DockerRuntimeError.apiError(let code, _) = error else {
        Issue.record("expected the original apiError, got \(error)")
        return
      }
      #expect(code == 500)
    }

    @Test("Non-API errors are passed through untouched")
    func nonAPIErrorIsUntouched() {
      let error = DockerRuntime.surfaceRuntimeFailure(
        DockerRuntimeError.socketError("broken pipe"), runtime: selection("kata", .kata))
      guard case DockerRuntimeError.socketError = error else {
        Issue.record("expected the original socketError, got \(error)")
        return
      }
    }
  }

  // MARK: - Integration

  @Suite("DockerRuntime Runtime Selection Integration", .enabled(if: isDockerAvailable()))
  struct DockerRuntimeSelectionIntegrationTests {

    private func makeRuntime(ociRuntime: String? = nil) -> DockerRuntime {
      DockerRuntime(
        config: ContainerRuntimeConfiguration(
          storagePath: "/tmp/claudec-test-docker-runtime-selection",
          endpoint: ProcessInfo.processInfo.environment["CLAUDEC_DOCKER_ENDPOINT"],
          ociRuntime: ociRuntime))
    }

    @Test("The daemon reports its registered runtimes")
    func daemonReportsRuntimes() async throws {
      let client = DockerAPIClient(
        endpoint: ProcessInfo.processInfo.environment["CLAUDEC_DOCKER_ENDPOINT"]
          ?? "/var/run/docker.sock")
      defer { Task { try? await client.shutdown() } }

      let info = try await client.info()
      let names = (info.Runtimes ?? [:]).keys.sorted()
      print("DIAG registered runtimes: \(names), default=\(info.DefaultRuntime ?? "<none>")")
      #expect(!names.isEmpty)
    }

    @Test("Selection picks a runtime the daemon actually offers")
    func selectionMatchesDaemon() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()

      let selection = await runtime.selectedRuntime()
      print("DIAG selected runtime: \(selection.name ?? "<daemon default>") (\(selection.kind))")
      #expect(selection.source != .configured)
    }

    /// The no-silent-downgrade guarantee, checked against a real daemon: a runtime the
    /// host cannot provide must fail loudly instead of quietly running under `runc`.
    @Test("An unavailable configured runtime fails instead of falling back")
    func unavailableRuntimeDoesNotFallBack() async throws {
      let runtime = makeRuntime(ociRuntime: "agentc-nonexistent-runtime")
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()
      _ = try await runtime.pullImage(ref: "alpine:latest")

      await #expect(throws: DockerRuntimeError.self) {
        let container = try await runtime.runContainer(
          imageRef: "alpine:latest",
          configuration: ContainerConfiguration(entrypoint: ["true"], io: .standardIO))
        // Should be unreachable; clean up if the daemon surprised us.
        try? await runtime.removeContainer(container)
      }
    }

    @Test("An explicitly configured runc runs containers normally")
    func explicitRuncRuns() async throws {
      let runtime = makeRuntime(ociRuntime: "runc")
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()
      _ = try await runtime.pullImage(ref: "alpine:latest")

      let selection = await runtime.selectedRuntime()
      #expect(selection.name == "runc")
      #expect(selection.warning == nil)

      let stdout = MockWriter()
      let container = try await runtime.runContainer(
        imageRef: "alpine:latest",
        configuration: ContainerConfiguration(
          entrypoint: ["echo", "explicit-runc"],
          io: .custom(stdin: EmptyReaderStream(), stdout: stdout, stderr: MockWriter())))
      let exitCode = try await container.wait(timeoutInSeconds: 30)
      try await runtime.removeContainer(container)

      #expect(exitCode == 0)
      #expect(stdout.string.contains("explicit-runc"))
    }
  }

  // MARK: - Hardened Runtime E2E

  /// The runtime alias CI installed on the Docker host, e.g. `runsc` or `kata`.
  ///
  /// Set by the `runtime-e2e` job in `.github/workflows/test.yml`. Unset everywhere else,
  /// which skips this suite — installing Kata or gVisor is a host-level change no
  /// developer machine should be assumed to have made.
  func expectedHardenedRuntime() -> String? {
    ProcessInfo.processInfo.environment["AGENTC_TEST_DOCKER_RUNTIME"]
  }

  /// The host's kernel release, used to prove a container is *not* sharing it.
  func hostKernelRelease() -> String? {
    guard
      let release = try? String(contentsOfFile: "/proc/sys/kernel/osrelease", encoding: .utf8)
    else { return nil }
    return release.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// End-to-end proof that discovery, selection, and `HostConfig.Runtime` combine into a
  /// real isolation boundary — not just the right bytes on the wire.
  @Suite(
    "DockerRuntime Hardened Runtime E2E",
    .enabled(if: isDockerAvailable() && expectedHardenedRuntime() != nil))
  struct DockerHardenedRuntimeE2ETests {

    private var expected: String { expectedHardenedRuntime() ?? "" }

    private func makeRuntime(ociRuntime: String? = nil) -> DockerRuntime {
      DockerRuntime(
        config: ContainerRuntimeConfiguration(
          storagePath: "/tmp/claudec-test-docker-hardened",
          endpoint: ProcessInfo.processInfo.environment["CLAUDEC_DOCKER_ENDPOINT"],
          ociRuntime: ociRuntime))
    }

    /// Run a command and return its stdout.
    private func output(
      _ runtime: DockerRuntime, _ command: String, expectSuccess: Bool = true
    ) async throws -> String {
      let stdout = MockWriter()
      let stderr = MockWriter()
      let container = try await runtime.runContainer(
        imageRef: "alpine:latest",
        configuration: ContainerConfiguration(
          entrypoint: ["/bin/sh", "-c", command],
          io: .custom(stdin: EmptyReaderStream(), stdout: stdout, stderr: stderr)))
      let exitCode = try await container.wait(timeoutInSeconds: 120)
      try await runtime.removeContainer(container)
      if expectSuccess {
        #expect(exitCode == 0, "stderr: \(stderr.string)")
      }
      return stdout.string
    }

    /// Discovery must find the hardened runtime on its own — CI registers it with the
    /// daemon and tells us nothing else.
    @Test("Discovery auto-selects the hardened runtime the host provides")
    func autoSelectsHardenedRuntime() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()

      let selection = await runtime.selectedRuntime()
      print("DIAG hardened E2E: expected=\(expected) selected=\(selection.name ?? "<default>")")
      #expect(selection.name == expected)
      #expect(selection.source == .discovered)
      #expect(selection.kind == .kata || selection.kind == .gVisor)
      // A host that offers real isolation must not be nagged about runc.
      #expect(selection.warning == nil)
    }

    @Test("Containers actually run under the hardened runtime")
    func containersRunHardened() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()
      _ = try await runtime.pullImage(ref: "alpine:latest")

      let marker = try await output(runtime, "echo hardened-ok")
      #expect(marker.contains("hardened-ok"))

      // Both Kata (real guest kernel) and gVisor (synthetic kernel) report a release that
      // differs from the host's. Under runc they would be identical.
      let containerRelease = try await output(runtime, "uname -r")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      print("DIAG hardened E2E: host=\(hostKernelRelease() ?? "?") container=\(containerRelease)")
      if let host = hostKernelRelease() {
        #expect(
          containerRelease != host,
          "container shares the host kernel — \(expected) did not take effect")
      }
    }

    @Test("The runtime can also be selected explicitly by name")
    func explicitHardenedRuntime() async throws {
      let runtime = makeRuntime(ociRuntime: expected)
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()
      _ = try await runtime.pullImage(ref: "alpine:latest")

      let selection = await runtime.selectedRuntime()
      #expect(selection.name == expected)
      #expect(selection.source == .configured)
      #expect(try await output(runtime, "echo explicit-ok").contains("explicit-ok"))
    }

    /// A full session — mounts, bootstrap-less entrypoint, wait, cleanup — under the
    /// hardened runtime, so we learn if anything in the adapter breaks outside runc.
    @Test("An AgentSession runs end to end under the hardened runtime")
    func agentSessionUnderHardenedRuntime() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()
      _ = try await runtime.pullImage(ref: "alpine:latest")

      let tmpBase = URL(fileURLWithPath: "/tmp/claudec-test-hardened-\(UUID().uuidString)")
      let configsDir = tmpBase.appendingPathComponent("configurations")
      try FileManager.default.createDirectory(at: configsDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmpBase) }

      let session = AgentSession(
        config: IsolationConfig(
          image: "alpine:latest",
          profileHomeDir: tmpBase.appendingPathComponent("home"),
          workspace: tmpBase,
          configurationsDir: configsDir,
          configurations: [],
          bootstrapMode: .imageDefault,
          arguments: ["/bin/sh", "-c", "echo session-ok"],
          customPTY: true
        ),
        runtime: runtime)

      let collector = Task { () -> Data in
        var buffer = Data()
        for await chunk in session.rawOut { buffer.append(contentsOf: chunk) }
        return buffer
      }

      try await session.start()
      let exitCode = try await session.wait()
      let text = String(decoding: await collector.value, as: UTF8.self)
      print("DIAG hardened E2E session: exit=\(exitCode) output=\(text)")

      #expect(exitCode == 0)
      #expect(text.contains("session-ok"))
    }
  }
#endif
