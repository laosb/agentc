#if canImport(Containerization)
  import AgentIsolation
  @testable import AgentIsolationAppleContainerRuntime
  import Foundation
  import Testing

  // MARK: - Image Reference Normalization Unit Tests

  @Suite("AppleContainerRuntime Image Ref Normalization")
  struct ImageRefNormalizationTests {

    // MARK: - Bare names (no slash, no registry)

    @Test("Bare name with tag is normalized to docker.io/library/")
    func bareNameWithTag() {
      let result = AppleContainerRuntime.normalizedDockerHubRef("swift:6.3")
      #expect(result == "docker.io/library/swift:6.3")
    }

    @Test("Bare name with 'latest' tag is normalized")
    func bareNameLatest() {
      let result = AppleContainerRuntime.normalizedDockerHubRef("ubuntu:latest")
      #expect(result == "docker.io/library/ubuntu:latest")
    }

    @Test("Bare name without tag is normalized")
    func bareNameNoTag() {
      let result = AppleContainerRuntime.normalizedDockerHubRef("alpine")
      #expect(result == "docker.io/library/alpine")
    }

    @Test("Bare name with numeric tag is normalized")
    func bareNameNumericTag() {
      let result = AppleContainerRuntime.normalizedDockerHubRef("ubuntu:22.04")
      #expect(result == "docker.io/library/ubuntu:22.04")
    }

    // MARK: - User namespaces (slash, no registry domain)

    @Test("User namespace with tag is normalized to docker.io/")
    func userNamespaceWithTag() {
      let result = AppleContainerRuntime.normalizedDockerHubRef("myuser/myimage:v1")
      #expect(result == "docker.io/myuser/myimage:v1")
    }

    @Test("User namespace without tag is normalized")
    func userNamespaceNoTag() {
      let result = AppleContainerRuntime.normalizedDockerHubRef("myuser/myimage")
      #expect(result == "docker.io/myuser/myimage")
    }

    // MARK: - Fully qualified references (returned unchanged)

    @Test("docker.io/library/ reference is unchanged")
    func dockerIoLibrary() {
      let ref = "docker.io/library/swift:6.3"
      let result = AppleContainerRuntime.normalizedDockerHubRef(ref)
      #expect(result == ref)
    }

    @Test("docker.io user namespace is unchanged")
    func dockerIoUser() {
      let ref = "docker.io/myuser/myimage:latest"
      let result = AppleContainerRuntime.normalizedDockerHubRef(ref)
      #expect(result == ref)
    }

    @Test("ghcr.io reference is unchanged")
    func ghcrReference() {
      let ref = "ghcr.io/apple/containerization/vminit:0.29.0"
      let result = AppleContainerRuntime.normalizedDockerHubRef(ref)
      #expect(result == ref)
    }

    @Test("Custom registry with port is unchanged")
    func registryWithPort() {
      let ref = "myregistry:5000/myimage:v2"
      let result = AppleContainerRuntime.normalizedDockerHubRef(ref)
      #expect(result == ref)
    }

    @Test("localhost registry is unchanged")
    func localhostRegistry() {
      let ref = "localhost/myimage:latest"
      let result = AppleContainerRuntime.normalizedDockerHubRef(ref)
      #expect(result == ref)
    }

    @Test("localhost with port registry is unchanged")
    func localhostWithPort() {
      let ref = "localhost:5000/myimage:latest"
      let result = AppleContainerRuntime.normalizedDockerHubRef(ref)
      #expect(result == ref)
    }

    // MARK: - Digest references

    @Test("Bare name with digest is normalized")
    func bareNameWithDigest() {
      let ref = "alpine@sha256:abcdef1234567890"
      let result = AppleContainerRuntime.normalizedDockerHubRef(ref)
      #expect(result == "docker.io/library/alpine@sha256:abcdef1234567890")
    }

    @Test("Fully qualified reference with digest is unchanged")
    func qualifiedWithDigest() {
      let ref = "ghcr.io/user/image@sha256:abcdef1234567890"
      let result = AppleContainerRuntime.normalizedDockerHubRef(ref)
      #expect(result == ref)
    }

    // MARK: - Edge cases

    @Test("Nested path with registry domain is unchanged")
    func nestedPath() {
      let ref = "registry.example.com/org/team/image:v1"
      let result = AppleContainerRuntime.normalizedDockerHubRef(ref)
      #expect(result == ref)
    }

    @Test("Reference with only a dot-less custom domain is treated as user namespace")
    func noDotDomain() {
      // "myregistry/myimage:v1" looks like a Docker Hub user namespace
      // since "myregistry" has no dot, colon, or "localhost" — same as Docker behavior
      let ref = "myregistry/myimage:v1"
      let result = AppleContainerRuntime.normalizedDockerHubRef(ref)
      #expect(result == "docker.io/myregistry/myimage:v1")
    }
  }

  // MARK: - AppleContainerRuntime Unit Tests

  @Suite("AppleContainerRuntime")
  struct AppleContainerRuntimeUnitTests {

    @Test("AppleContainerImage conforms to ContainerRuntimeImage")
    func imageConformance() {
      var image = AppleContainerImage(ref: "swift:6.3", digest: "sha256:abc123")
      #expect(image.ref == "swift:6.3")
      #expect(image.digest == "sha256:abc123")

      image.ref = "docker.io/library/swift:6.3"
      image.digest = "sha256:def456"
      #expect(image.ref == "docker.io/library/swift:6.3")
      #expect(image.digest == "sha256:def456")
    }

    @Test("AppleContainerContainer conforms to ContainerRuntimeContainer")
    func containerConformance() {
      let _: any ContainerRuntimeContainer.Type = AppleContainerContainer.self
    }

    @Test("AppleContainerRuntimeError has descriptive messages")
    func errorDescriptions() {
      let error = AppleContainerRuntimeError.notPrepared
      let description = error.errorDescription ?? ""
      #expect(!description.isEmpty)
      #expect(description.contains("prepare"))
    }

    @Test("pullImage throws when not prepared")
    func pullImageNotPrepared() async {
      let config = ContainerRuntimeConfiguration(storagePath: "/tmp/test-apple-container")
      let runtime = AppleContainerRuntime(config: config)
      await #expect(throws: AppleContainerRuntimeError.self) {
        _ = try await runtime.pullImage(ref: "alpine:latest")
      }
    }

    @Test("inspectImage throws when not prepared")
    func inspectImageNotPrepared() async {
      let config = ContainerRuntimeConfiguration(storagePath: "/tmp/test-apple-container")
      let runtime = AppleContainerRuntime(config: config)
      await #expect(throws: AppleContainerRuntimeError.self) {
        _ = try await runtime.inspectImage(ref: "alpine:latest")
      }
    }

    @Test("removeImage throws when not prepared")
    func removeImageNotPrepared() async {
      let config = ContainerRuntimeConfiguration(storagePath: "/tmp/test-apple-container")
      let runtime = AppleContainerRuntime(config: config)
      await #expect(throws: AppleContainerRuntimeError.self) {
        try await runtime.removeImage(ref: "alpine:latest")
      }
    }

    @Test("AppleContainerRuntime is Sendable")
    func runtimeSendable() {
      let config = ContainerRuntimeConfiguration(storagePath: "/tmp/test-apple-container")
      let runtime = AppleContainerRuntime(config: config)
      let _: any Sendable = runtime
    }

    @Test("AppleContainerImage is Sendable")
    func imageSendable() {
      let image = AppleContainerImage(ref: "test:latest", digest: "sha256:abc")
      let _: any Sendable = image
    }
  }
#endif
