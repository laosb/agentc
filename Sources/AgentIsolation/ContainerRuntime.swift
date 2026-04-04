#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A protocol that defines the interface for a container runtime, which is responsible for
/// managing container images and running containers.
///
/// This protocol and its parts are intentionally designed to be minimal and flexible as long as
/// they can cover the needs of running isolated agent sessions.
/// The implementation details are left to the conforming types, allowing for different container
/// runtimes (e.g., Docker, Podman, custom runtimes) to be used as needed.
/// `Image` and `Container` are associated types that represent the container image and container
/// instances managed by the runtime, respectively.
public protocol ContainerRuntime: Sendable {
  associatedtype Image: ContainerRuntimeImage
  associatedtype Container: ContainerRuntimeContainer

  init(config: ContainerRuntimeConfiguration)

  /// Prepare necessary setup.
  ///
  /// Download supporting files, start services, etc.
  func prepare() async throws

  /// Pull the specified image.
  ///
  /// The runtime should always check image version with remote to see if there's newer version
  /// to pull. If newer version is available, the runtime should update the local image and return
  /// the new image. Returns `nil` if the image doesn't exist on remote.
  func pullImage(ref: String) async throws -> Image?

  /// Inspect the specified image locally.
  ///
  /// Returns `nil` when the image does not exist locally.
  func inspectImage(ref: String) async throws -> Image?

  /// Remove an image by its reference.
  ///
  /// The image store should always be purged before return.
  func removeImage(ref: String) async throws

  /// Remove an image by its digest.
  ///
  /// The image store should always be purged before return.
  func removeImage(digest: String) async throws

  /// Run a container with specified `imageRef` and container configuration.
  func runContainer(
    imageRef: String,
    configuration: ContainerConfiguration
  ) async throws -> Container

  /// Remove a container.
  func removeContainer(_ container: Container) async throws
}

public struct ContainerRuntimeConfiguration: Sendable {
  public var storagePath: String
  public var endpoint: String?

  public init(storagePath: String, endpoint: String? = nil) {
    self.storagePath = storagePath
    self.endpoint = endpoint
  }
}

public struct ContainerConfiguration: Sendable {
  public var entrypoint: [String]
  public var workingDirectory: String?
  public var mounts: [Mount]
  public var io: IO

  public init(
    entrypoint: [String],
    workingDirectory: String? = nil,
    mounts: [Mount] = [],
    io: IO = .currentTerminal
  ) {
    self.entrypoint = entrypoint
    self.workingDirectory = workingDirectory
    self.mounts = mounts
    self.io = io
  }

  public struct Mount: Sendable {
    public var hostPath: String
    public var containerPath: String
    public var isReadOnly: Bool

    public init(hostPath: String, containerPath: String, isReadOnly: Bool = false) {
      self.hostPath = hostPath
      self.containerPath = containerPath
      self.isReadOnly = isReadOnly
    }
  }

  public enum IO: Sendable {
    case currentTerminal
    case standardIO
    case custom(stdin: any ReaderStream, stdout: any Writer, stderr: any Writer)
  }
}

public protocol ContainerRuntimeImage: Sendable {
  var ref: String { get set }
  var digest: String { get set }
}

public protocol ContainerRuntimeContainer: Identifiable, Sendable, AnyObject {
  var id: String { get }

  /// Wait for the process in the container to end and return its exit code.
  func wait(timeoutInSeconds: Int64?) async throws -> Int32

  /// Stop the current container.
  ///
  /// Will be called even after ``wait(timeoutInSeconds:)``.
  func stop() async throws
}
