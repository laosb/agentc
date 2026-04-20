#if ContainerRuntimeDocker
  import AgentIsolation
  @testable import AgentIsolationDockerRuntime
  import Foundation
  import Testing

  // MARK: - DockerRuntime Unit Tests

  @Suite("DockerRuntime")
  struct DockerRuntimeTests {

    @Test("DockerImage conforms to ContainerRuntimeImage")
    func imageConformance() {
      var image = DockerImage(ref: "nginx:latest", digest: "sha256:abc123")
      #expect(image.ref == "nginx:latest")
      #expect(image.digest == "sha256:abc123")

      image.ref = "nginx:1.25"
      image.digest = "sha256:def456"
      #expect(image.ref == "nginx:1.25")
      #expect(image.digest == "sha256:def456")
    }

    @Test("DockerContainer conforms to ContainerRuntimeContainer")
    func containerConformance() {
      let _: any ContainerRuntimeContainer.Type = DockerContainer.self
    }

    @Test("DockerRuntime init accepts configuration")
    func runtimeInit() async throws {
      let config = ContainerRuntimeConfiguration(
        storagePath: "/tmp/test",
        endpoint: "/var/run/docker.sock"
      )
      let runtime = DockerRuntime(config: config)
      try await runtime.shutdown()
    }

    @Test("DockerRuntime init uses default endpoint when nil")
    func runtimeDefaultEndpoint() async throws {
      let config = ContainerRuntimeConfiguration(storagePath: "/tmp/test")
      let runtime = DockerRuntime(config: config)
      try await runtime.shutdown()
    }

    @Test("DockerRuntimeError has descriptive messages")
    func errorDescriptions() {
      let errors: [DockerRuntimeError] = [
        .dockerNotAccessible("connection refused"),
        .pullFailed("image not found"),
        .imageNotFound("nginx:latest"),
        .apiError(500, "internal server error"),
        .attachFailed("connection timeout"),
        .socketError("permission denied"),
      ]

      for error in errors {
        let description = error.errorDescription ?? ""
        #expect(!description.isEmpty, "Error should have a description: \(error)")
      }
    }

    @Test("currentPlatform returns os/arch format for current architecture")
    func platformString() {
      let platform = DockerRuntime.currentPlatform
      #expect(!platform.isEmpty, "Platform should not be empty on supported architectures")

      let parts = platform.split(separator: "/")
      #expect(parts.count == 2, "Platform should have os/arch format")
      #expect(parts[0] == "linux")

      #if arch(arm64)
        #expect(parts[1] == "arm64")
      #elseif arch(x86_64)
        #expect(parts[1] == "amd64")
      #endif
    }

    @Test("DockerRuntime is Sendable")
    func runtimeSendable() async throws {
      let config = ContainerRuntimeConfiguration(storagePath: "/tmp/test")
      let runtime = DockerRuntime(config: config)
      defer { Task { try? await runtime.shutdown() } }

      // Verify Sendable by passing across isolation boundaries
      let _: any Sendable = runtime
    }

    @Test("DockerImage is Sendable")
    func imageSendable() {
      let image = DockerImage(ref: "test:latest", digest: "sha256:abc")
      let _: any Sendable = image
    }

    @Test("ContainerConfiguration cpuCount and memoryLimitMiB defaults")
    func containerConfigurationDefaults() {
      let config = ContainerConfiguration(entrypoint: ["echo"])
      #expect(config.cpuCount == 1)
      #expect(config.memoryLimitMiB == 1536)
    }

    @Test("ContainerConfiguration accepts custom cpuCount and memoryLimitMiB")
    func containerConfigurationCustomValues() {
      let config = ContainerConfiguration(
        entrypoint: ["echo"],
        cpuCount: 4,
        memoryLimitMiB: 4096
      )
      #expect(config.cpuCount == 4)
      #expect(config.memoryLimitMiB == 4096)
    }
  }

  // MARK: - DockerAPIClient URL Construction Tests

  @Suite("DockerAPIClient URL Construction")
  struct DockerAPIClientURLTests {

    // MARK: - parseImageRef

    @Test("parseImageRef splits simple image:tag")
    func parseSimpleRef() {
      let (image, tag) = DockerAPIClient.parseImageRef("nginx:latest")
      #expect(image == "nginx")
      #expect(tag == "latest")
    }

    @Test("parseImageRef defaults to 'latest' when no tag")
    func parseNoTag() {
      let (image, tag) = DockerAPIClient.parseImageRef("ubuntu")
      #expect(image == "ubuntu")
      #expect(tag == "latest")
    }

    @Test("parseImageRef handles registry with port and tag")
    func parseRegistryPortAndTag() {
      let (image, tag) = DockerAPIClient.parseImageRef("myhost:5000/myimage:v2")
      #expect(image == "myhost:5000/myimage")
      #expect(tag == "v2")
    }

    @Test("parseImageRef handles registry with port but no tag")
    func parseRegistryPortNoTag() {
      let (image, tag) = DockerAPIClient.parseImageRef("myhost:5000/myimage")
      #expect(image == "myhost:5000/myimage")
      #expect(tag == "latest")
    }

    @Test("parseImageRef handles fully qualified ghcr.io ref")
    func parseGHCR() {
      let (image, tag) = DockerAPIClient.parseImageRef("ghcr.io/user/repo:sha-abc123")
      #expect(image == "ghcr.io/user/repo")
      #expect(tag == "sha-abc123")
    }

    @Test("parseImageRef handles numeric tag like ubuntu:22.04")
    func parseNumericTag() {
      let (image, tag) = DockerAPIClient.parseImageRef("ubuntu:22.04")
      #expect(image == "ubuntu")
      #expect(tag == "22.04")
    }

    @Test("parseImageRef handles sha256 digest reference with @")
    func parseDigestRef() {
      // Docker digest refs use '@' separator, but parseImageRef is designed
      // for ':' tag syntax. With @sha256:..., the last ':' splits it.
      // This is expected — digest refs should be used as-is, not parsed for tags.
      let ref = "ubuntu@sha256:abcdef1234567890"
      let (image, tag) = DockerAPIClient.parseImageRef(ref)
      #expect(image == "ubuntu@sha256")
      #expect(tag == "abcdef1234567890")
    }

    @Test("parseImageRef handles empty string")
    func parseEmptyRef() {
      let (image, tag) = DockerAPIClient.parseImageRef("")
      #expect(image == "")
      #expect(tag == "latest")
    }

    // MARK: - pathEncodeComponent

    @Test("pathEncodeComponent encodes slashes in image refs")
    func pathEncodeSlashes() {
      let encoded = DockerAPIClient.pathEncodeComponent("library/nginx")
      #expect(encoded == "library%2Fnginx")
    }

    @Test("pathEncodeComponent encodes special characters")
    func pathEncodeSpecial() {
      let encoded = DockerAPIClient.pathEncodeComponent("image name:tag")
      #expect(encoded.contains("%20") || encoded.contains("+"))
      #expect(!encoded.contains(" "))
    }

    @Test("pathEncodeComponent preserves safe characters")
    func pathEncodeSafe() {
      let encoded = DockerAPIClient.pathEncodeComponent("alpine")
      #expect(encoded == "alpine")
    }

    @Test("pathEncodeComponent handles colons in digest refs")
    func pathEncodeDigest() {
      // Colons are allowed in URL path segments per RFC 3986, so they are NOT encoded
      let encoded = DockerAPIClient.pathEncodeComponent("sha256:abc123")
      #expect(encoded == "sha256:abc123")
    }

    // MARK: - buildURL with Unix socket

    @Test("buildURL produces correct path for Unix socket endpoint")
    func buildURLUnixSocket() async throws {
      let client = DockerAPIClient(endpoint: "/var/run/docker.sock")
      defer { Task { try? await client.shutdown() } }

      let url = client.buildURL(path: "/_ping")
      #expect(url.hasPrefix("http+unix://"))
      #expect(url.contains("%2Fvar%2Frun%2Fdocker.sock"))
      #expect(url.hasSuffix("/v1.44/_ping"))
    }

    @Test("buildURL includes query items properly encoded")
    func buildURLWithQuery() async throws {
      let client = DockerAPIClient(endpoint: "/var/run/docker.sock")
      defer { Task { try? await client.shutdown() } }

      let url = client.buildURL(
        path: "/images/create",
        queryItems: [
          URLQueryItem(name: "fromImage", value: "ghcr.io/user/repo"),
          URLQueryItem(name: "tag", value: "v1.0"),
        ])
      #expect(url.contains("/v1.44/images/create?"))
      #expect(
        url.contains("fromImage=ghcr.io/user/repo")
          || url.contains("fromImage=ghcr.io%2Fuser%2Frepo"))
      #expect(url.contains("tag=v1.0"))
    }

    @Test("buildURL with platform query encodes slashes")
    func buildURLWithPlatform() async throws {
      let client = DockerAPIClient(endpoint: "/var/run/docker.sock")
      defer { Task { try? await client.shutdown() } }

      let platform = "linux/arm64"
      let url = client.buildURL(
        path: "/images/create",
        queryItems: [
          URLQueryItem(name: "fromImage", value: "alpine"),
          URLQueryItem(name: "tag", value: "latest"),
          URLQueryItem(name: "platform", value: platform),
        ])
      #expect(url.contains("platform="))
      #expect(url.contains("linux"))
      #expect(url.contains("arm64"))
    }

    @Test("buildURL with no query items omits question mark")
    func buildURLNoQuery() async throws {
      let client = DockerAPIClient(endpoint: "/var/run/docker.sock")
      defer { Task { try? await client.shutdown() } }

      let url = client.buildURL(path: "/containers/abc123/start")
      #expect(!url.contains("?"))
      #expect(url.hasSuffix("/v1.44/containers/abc123/start"))
    }

    // MARK: - buildURL with TCP endpoint

    @Test("buildURL produces correct URL for TCP endpoint")
    func buildURLTCP() async throws {
      let client = DockerAPIClient(endpoint: "http://localhost:2375")
      defer { Task { try? await client.shutdown() } }

      let url = client.buildURL(path: "/_ping")
      #expect(url == "http://localhost:2375/v1.44/_ping")
    }

    @Test("buildURL for TCP endpoint without scheme adds http")
    func buildURLTCPNoScheme() async throws {
      let client = DockerAPIClient(endpoint: "localhost:2375")
      defer { Task { try? await client.shutdown() } }

      let url = client.buildURL(path: "/_ping")
      #expect(url.hasPrefix("http://"))
      #expect(url.hasSuffix("/v1.44/_ping"))
    }

    @Test("buildURL strips trailing slash from TCP endpoint")
    func buildURLTCPTrailingSlash() async throws {
      let client = DockerAPIClient(endpoint: "http://myhost:2375/")
      defer { Task { try? await client.shutdown() } }

      let url = client.buildURL(path: "/_ping")
      #expect(url == "http://myhost:2375/v1.44/_ping")
    }

    // MARK: - Unix socket with unix:// prefix

    @Test("buildURL handles unix:// prefix in endpoint")
    func buildURLUnixPrefix() async throws {
      let client = DockerAPIClient(endpoint: "unix:///var/run/docker.sock")
      defer { Task { try? await client.shutdown() } }

      let url = client.buildURL(path: "/_ping")
      #expect(url.hasPrefix("http+unix://"))
      #expect(url.contains("%2Fvar%2Frun%2Fdocker.sock"))
      #expect(url.hasSuffix("/v1.44/_ping"))
    }
  }

  // MARK: - Custom IO Helpers

  /// Captures all data written to it; thread-safe.
  final class MockWriter: Writer, @unchecked Sendable {
    private var _data = Data()
    private let lock = NSLock()

    var data: Data { lock.withLock { _data } }
    var string: String { String(data: data, encoding: .utf8) ?? "" }

    func write(_ data: Data) throws { lock.withLock { _data.append(data) } }
    func close() throws {}
  }

  /// A ReaderStream that immediately finishes without yielding data.
  struct EmptyReaderStream: ReaderStream {
    func stream() -> AsyncStream<Data> {
      AsyncStream { $0.finish() }
    }
  }

  /// A ReaderStream that yields a single data chunk then finishes.
  struct DataReaderStream: ReaderStream {
    let data: Data
    func stream() -> AsyncStream<Data> {
      AsyncStream { continuation in
        continuation.yield(data)
        continuation.finish()
      }
    }
  }

  // MARK: - DockerRuntime Integration Tests

  private func isDockerAvailable() -> Bool {
    FileManager.default.fileExists(atPath: "/var/run/docker.sock")
      || ProcessInfo.processInfo.environment["CLAUDEC_DOCKER_ENDPOINT"] != nil
  }

  @Suite("DockerRuntime Integration", .enabled(if: isDockerAvailable()))
  struct DockerRuntimeIntegrationTests {

    private func makeRuntime() -> DockerRuntime {
      let endpoint = ProcessInfo.processInfo.environment["CLAUDEC_DOCKER_ENDPOINT"]
      let config = ContainerRuntimeConfiguration(
        storagePath: "/tmp/claudec-test-docker", endpoint: endpoint)
      return DockerRuntime(config: config)
    }

    private func makeClient() -> DockerAPIClient {
      let endpoint =
        ProcessInfo.processInfo.environment["CLAUDEC_DOCKER_ENDPOINT"]
        ?? "/var/run/docker.sock"
      return DockerAPIClient(endpoint: endpoint)
    }

    @Test("buildURL produces correct URLs for Docker API")
    func verifyURLConstruction() async throws {
      let client = makeClient()
      defer { Task { try? await client.shutdown() } }

      let pingURL = client.buildURL(path: "/_ping")
      print("DIAG ping URL: \(pingURL)")
      #expect(pingURL.hasSuffix("/v1.44/_ping"))

      let inspectURL = client.buildURL(path: "/images/alpine:latest/json")
      print("DIAG inspect URL: \(inspectURL)")
      #expect(inspectURL.contains("/v1.44/images/"))

      let pullURL = client.buildURL(
        path: "/images/create",
        queryItems: [
          URLQueryItem(name: "fromImage", value: "alpine"),
          URLQueryItem(name: "tag", value: "latest"),
        ])
      print("DIAG pull URL: \(pullURL)")
      #expect(pullURL.contains("fromImage=alpine"))
    }

    @Test("prepare succeeds when Docker is available")
    func prepareSucceeds() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()
    }

    @Test("inspectImage returns nil for non-existent image")
    func inspectNonExistent() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()

      let image = try await runtime.inspectImage(
        ref: "this-image-definitely-does-not-exist-\(UUID().uuidString.lowercased()):latest")
      #expect(image == nil)
    }

    @Test("pullImage and inspectImage work for a small image")
    func pullAndInspect() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()

      let image = try await runtime.pullImage(ref: "alpine:latest")
      #expect(image != nil)
      #expect(image?.ref == "alpine:latest")
      #expect(image?.digest.isEmpty == false)

      let inspected = try await runtime.inspectImage(ref: "alpine:latest")
      #expect(inspected != nil)
      #expect(inspected?.digest == image?.digest)
    }

    @Test("removeImage removes a pulled image")
    func removeImage() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()

      let image = try await runtime.pullImage(ref: "alpine:3.18")
      try #require(image != nil, "Failed to pull alpine:3.18")

      try await runtime.removeImage(ref: "alpine:3.18")
    }

    @Test("resize forwards to Docker API for a TTY container")
    func resizeOnTTYContainer() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()
      _ = try await runtime.pullImage(ref: "alpine:latest")
      print("DIAG resizeOnTTYContainer: pulled alpine:latest")

      // Use a sleep so the container stays alive long enough to resize.
      // Attach with custom IO + isTerminal so useTTY=true.
      let config = ContainerConfiguration(
        entrypoint: ["/bin/sh", "-c", "sleep 2"],
        io: .custom(
          stdin: EmptyReaderStream(),
          stdout: MockWriter(),
          stderr: MockWriter(),
          isTerminal: true)
      )

      let container = try await runtime.runContainer(
        imageRef: "alpine:latest", configuration: config)
      print("DIAG resizeOnTTYContainer: container=\(container.id) started")

      do {
        try await container.resize(cols: 100, rows: 30)
        print("DIAG resizeOnTTYContainer: resize call succeeded")
      } catch {
        print("DIAG resizeOnTTYContainer: resize failed with error=\(error)")
        try? await runtime.removeContainer(container)
        throw error
      }

      let exitCode = try await container.wait(timeoutInSeconds: 10)
      print("DIAG resizeOnTTYContainer: exitCode=\(exitCode)")
      try await runtime.removeContainer(container)
    }

    @Test("runContainer executes a command and returns exit code")
    func runContainer() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()

      _ = try await runtime.pullImage(ref: "alpine:latest")

      let containerConfig = ContainerConfiguration(
        entrypoint: ["echo", "hello-from-docker"],
        io: .standardIO
      )

      let container = try await runtime.runContainer(
        imageRef: "alpine:latest",
        configuration: containerConfig
      )

      let exitCode = try await container.wait(timeoutInSeconds: 30)
      #expect(exitCode == 0)

      try await runtime.removeContainer(container)
    }
  }

  // MARK: - Custom IO Integration Tests

  @Suite("DockerRuntime Custom IO", .enabled(if: isDockerAvailable()))
  struct DockerRuntimeCustomIOTests {

    private func makeRuntime() -> DockerRuntime {
      let endpoint = ProcessInfo.processInfo.environment["CLAUDEC_DOCKER_ENDPOINT"]
      let config = ContainerRuntimeConfiguration(
        storagePath: "/tmp/claudec-test-docker-custom-io", endpoint: endpoint)
      return DockerRuntime(config: config)
    }

    @Test("custom IO captures stdout")
    func capturesStdout() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()
      _ = try await runtime.pullImage(ref: "alpine:latest")

      let stdout = MockWriter()
      let config = ContainerConfiguration(
        entrypoint: ["echo", "hello from custom io"],
        io: .custom(stdin: EmptyReaderStream(), stdout: stdout, stderr: MockWriter())
      )

      let container = try await runtime.runContainer(
        imageRef: "alpine:latest", configuration: config)
      let exitCode = try await container.wait(timeoutInSeconds: 30)
      try await runtime.removeContainer(container)

      #expect(exitCode == 0)
      #expect(stdout.string.contains("hello from custom io"))
    }

    @Test("custom IO separates stderr from stdout")
    func separatesStderr() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()
      _ = try await runtime.pullImage(ref: "alpine:latest")

      let stdout = MockWriter()
      let stderr = MockWriter()
      let config = ContainerConfiguration(
        entrypoint: ["/bin/sh", "-c", "echo to-stdout; echo to-stderr >&2"],
        io: .custom(stdin: EmptyReaderStream(), stdout: stdout, stderr: stderr)
      )

      let container = try await runtime.runContainer(
        imageRef: "alpine:latest", configuration: config)
      let exitCode = try await container.wait(timeoutInSeconds: 30)
      try await runtime.removeContainer(container)

      #expect(exitCode == 0)
      #expect(stdout.string.contains("to-stdout"))
      #expect(!stdout.string.contains("to-stderr"))
      #expect(stderr.string.contains("to-stderr"))
      #expect(!stderr.string.contains("to-stdout"))
    }

    @Test("AgentSession customPTY streams output via rawOut and accepts resize")
    func agentSessionCustomPTY() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()
      _ = try await runtime.pullImage(ref: "alpine:latest")

      let tmpBase = URL(fileURLWithPath: "/tmp/claudec-test-custompty-docker-\(UUID().uuidString)")
      let profileDir = tmpBase.appendingPathComponent("home")
      let configsDir = tmpBase.appendingPathComponent("configurations")
      try FileManager.default.createDirectory(
        at: configsDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmpBase) }

      let config = IsolationConfig(
        image: "alpine:latest",
        profileHomeDir: profileDir,
        workspace: URL(fileURLWithPath: "/tmp"),
        configurationsDir: configsDir,
        configurations: [],
        bootstrapMode: .imageDefault,
        arguments: ["/bin/sh", "-c", "echo pty-ok; sleep 0.2"],
        customPTY: true
      )

      let session = AgentSession(config: config, runtime: runtime)

      // Collect rawOut off the task so it runs concurrently with start/wait.
      let collector = Task { () -> Data in
        var buf = Data()
        for await chunk in session.rawOut {
          buf.append(contentsOf: chunk)
        }
        return buf
      }

      try await session.start()
      print("DIAG agentSessionCustomPTY: session started")
      try await session.resize(cols: 100, rows: 30)
      print("DIAG agentSessionCustomPTY: resize invoked")

      let exitCode = try await session.wait()
      let output = await collector.value
      print(
        "DIAG agentSessionCustomPTY: exitCode=\(exitCode) bytes=\(output.count) text=\(String(data: output, encoding: .utf8) ?? "<non-utf8>")"
      )

      #expect(exitCode == 0)
      #expect(String(data: output, encoding: .utf8)?.contains("pty-ok") == true)
    }

    @Test("AgentSession customPTY write delivers stdin to container")
    func agentSessionCustomPTYWrite() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()
      _ = try await runtime.pullImage(ref: "alpine:latest")

      let tmpBase = URL(
        fileURLWithPath: "/tmp/claudec-test-custompty-docker-write-\(UUID().uuidString)")
      let profileDir = tmpBase.appendingPathComponent("home")
      let configsDir = tmpBase.appendingPathComponent("configurations")
      try FileManager.default.createDirectory(
        at: configsDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmpBase) }

      // `head -c 5` echoes the first 5 stdin bytes then exits.
      let config = IsolationConfig(
        image: "alpine:latest",
        profileHomeDir: profileDir,
        workspace: URL(fileURLWithPath: "/tmp"),
        configurationsDir: configsDir,
        configurations: [],
        bootstrapMode: .imageDefault,
        arguments: ["/bin/sh", "-c", "head -c 5"],
        customPTY: true
      )

      let session = AgentSession(config: config, runtime: runtime)
      let collector = Task { () -> Data in
        var buf = Data()
        for await chunk in session.rawOut {
          buf.append(contentsOf: chunk)
          if buf.count >= 5 { break }
        }
        return buf
      }

      try await session.start()
      print("DIAG agentSessionCustomPTYWrite: session started")
      try session.write(Data("hello".utf8))
      print("DIAG agentSessionCustomPTYWrite: wrote 5 bytes")

      let exitCode = try await session.wait()
      let output = await collector.value
      print(
        "DIAG agentSessionCustomPTYWrite: exitCode=\(exitCode) bytes=\(output.count) text=\(String(data: output, encoding: .utf8) ?? "<non-utf8>")"
      )

      #expect(exitCode == 0)
      // A TTY echoes input, so the output contains our bytes (possibly with
      // an echoed prefix). Verify the payload appears somewhere.
      #expect(String(data: output, encoding: .utf8)?.contains("hello") == true)
    }

    @Test("custom IO sends stdin to container")
    func sendsStdin() async throws {
      let runtime = makeRuntime()
      defer { Task { try? await runtime.shutdown() } }
      try await runtime.prepare()
      _ = try await runtime.pullImage(ref: "alpine:latest")

      let stdout = MockWriter()
      let stdinData = Data("hello".utf8)
      let config = ContainerConfiguration(
        entrypoint: ["head", "-c", "5"],
        io: .custom(
          stdin: DataReaderStream(data: stdinData), stdout: stdout, stderr: MockWriter())
      )

      let container = try await runtime.runContainer(
        imageRef: "alpine:latest", configuration: config)
      let exitCode = try await container.wait(timeoutInSeconds: 30)
      try await runtime.removeContainer(container)

      #expect(exitCode == 0)
      #expect(stdout.data == stdinData)
    }
  }
#endif
