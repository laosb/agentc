#if ContainerRuntimeDocker
  import AgentIsolation
  import AgentIsolationDockerRuntime
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
        ref: "this-image-definitely-does-not-exist-\(UUID().uuidString):latest")
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
#endif
