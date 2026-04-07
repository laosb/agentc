import AgentIsolation

/// A mock container runtime that captures the configuration passed to `runContainer`
/// and returns a controllable container, for testing `AgentSession` orchestration logic.
final class MockRuntime: ContainerRuntime, @unchecked Sendable {
  typealias Image = MockImage
  typealias Container = MockContainer

  var prepareCallCount = 0
  var lastContainerConfiguration: ContainerConfiguration?
  var lastImageRef: String?
  var containerExitCode: Int32 = 0
  var removedImageRefs: [String] = []
  var removedImageDigests: [String] = []

  required init(config: ContainerRuntimeConfiguration) {}

  func prepare() async throws {
    prepareCallCount += 1
  }

  func pullImage(ref: String) async throws -> MockImage? {
    MockImage(ref: ref, digest: "sha256:mock")
  }

  func inspectImage(ref: String) async throws -> MockImage? {
    MockImage(ref: ref, digest: "sha256:mock")
  }

  func removeImage(ref: String) async throws {
    removedImageRefs.append(ref)
  }

  func removeImage(digest: String) async throws {
    removedImageDigests.append(digest)
  }

  func runContainer(
    imageRef: String,
    configuration: ContainerConfiguration
  ) async throws -> MockContainer {
    lastImageRef = imageRef
    lastContainerConfiguration = configuration
    return MockContainer(id: "mock-container", exitCode: containerExitCode)
  }

  func removeContainer(_ container: MockContainer) async throws {
    container.removed = true
  }
}

struct MockImage: ContainerRuntimeImage {
  var ref: String
  var digest: String
}

final class MockContainer: ContainerRuntimeContainer, @unchecked Sendable {
  let id: String
  let exitCode: Int32
  var stopped = false
  var removed = false

  init(id: String, exitCode: Int32) {
    self.id = id
    self.exitCode = exitCode
  }

  func wait(timeoutInSeconds: Int64?) async throws -> Int32 {
    exitCode
  }

  func stop() async throws {
    stopped = true
  }
}
