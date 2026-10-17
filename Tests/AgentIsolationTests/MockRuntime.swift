import AgentIsolation
import Foundation

/// A mock container runtime that captures the configuration passed to `runContainer`
/// and returns a controllable container, for testing `AgentSession` orchestration logic.
final class MockRuntime: ContainerRuntime, @unchecked Sendable {
  typealias Image = MockImage
  typealias Container = MockContainer

  var prepareCallCount = 0
  var lastContainerConfiguration: ContainerConfiguration?
  var lastImageRef: String?
  var lastContainer: MockContainer?
  var containerExitCode: Int32 = 0
  var removedImageRefs: [String] = []
  var removedImageDigests: [String] = []
  var supportsHostBridge = false

  required init(config: ContainerRuntimeConfiguration) {}

  func validateHostSocketRelay() async throws {
    if !supportsHostBridge { throw ContainerRuntimeError.hostSocketRelayNotSupported }
  }

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
    let container = MockContainer(id: "mock-container", exitCode: containerExitCode)
    lastContainer = container
    return container
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
  var resizeCalls: [(cols: Int, rows: Int)] = []
  var lastTimeoutInSeconds: Int64? = nil
  /// Raised by ``stop()``, for testing what a wedged container leaves behind.
  var stopError: (any Error)?

  init(id: String, exitCode: Int32) {
    self.id = id
    self.exitCode = exitCode
  }

  func wait(timeoutInSeconds: Int64?) async throws -> Int32 {
    lastTimeoutInSeconds = timeoutInSeconds
    return exitCode
  }

  func stop() async throws {
    stopped = true
    if let stopError { throw stopError }
  }

  func resize(cols: Int, rows: Int) async throws {
    resizeCalls.append((cols: cols, rows: rows))
  }
}

/// A mock runtime that declares an ownership mapping, and optionally plays the
/// guest side of the profile-ownership handshake.
///
/// `runContainer` finds this session's control mount, writes the report the test
/// asked for, and then waits for the host's acknowledgement in the background —
/// exactly the sequence a real bootstrap follows.
final class OwnershipMockRuntime: ContainerRuntime, @unchecked Sendable {
  typealias Image = MockImage
  typealias Container = MockContainer

  /// What the fake guest reports on each successive launch.
  var scriptedReports: [ProfileOwnershipReport] = []
  /// The mapping this runtime claims. `nil` keeps the fast path off.
  var mapping: ProfileOwnershipMapping? = ProfileOwnershipMapping(
    identity: "mock", isCharacterized: true)

  private(set) var launches = 0
  private(set) var environments: [[String: String]] = []
  private(set) var controlDirectories: [URL] = []
  private(set) var removedContainers: [String] = []

  required init(config: ContainerRuntimeConfiguration) {}

  var profileOwnershipMapping: ProfileOwnershipMapping? { mapping }

  func prepare() async throws {}
  func pullImage(ref: String) async throws -> MockImage? { MockImage(ref: ref, digest: "d") }
  func inspectImage(ref: String) async throws -> MockImage? { MockImage(ref: ref, digest: "d") }
  func removeImage(ref: String) async throws {}
  func removeImage(digest: String) async throws {}

  func runContainer(
    imageRef: String, configuration: ContainerConfiguration
  ) async throws -> MockContainer {
    let index = launches
    launches += 1
    environments.append(configuration.environment)

    let controlMount = configuration.mounts.first {
      $0.containerPath == ProfileOwnershipProtocol.controlMountPath
    }
    if let controlMount {
      let directory = URL(fileURLWithPath: controlMount.hostPath)
      controlDirectories.append(directory)
      if index < scriptedReports.count {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(scriptedReports[index])
        try data.write(
          to: directory.appendingPathComponent(ProfileOwnershipProtocol.reportFileName),
          options: .atomic)
      }
    }
    return MockContainer(id: "mock-container-\(index)", exitCode: 0)
  }

  func removeContainer(_ container: MockContainer) async throws {
    removedContainers.append(container.id)
    container.removed = true
  }
}
