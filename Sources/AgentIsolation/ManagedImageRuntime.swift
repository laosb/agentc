/// Details about an image stored by a ``ManagedImageRuntime``.
public struct ManagedImage: Sendable, Equatable {
  public let name: String
  public let tag: String
  public let storageUsage: UInt64
  /// Content-addressable digest of the image index, when exposed by the runtime.
  public let digest: String?
  /// OCI media type of the image's root descriptor, when available.
  public let mediaType: String?
  /// Platforms included in the image index, when available.
  public let platforms: [String]?

  public init(
    name: String,
    tag: String,
    storageUsage: UInt64,
    digest: String? = nil,
    mediaType: String? = nil,
    platforms: [String]? = nil
  ) {
    self.name = name
    self.tag = tag
    self.storageUsage = storageUsage
    self.digest = digest
    self.mediaType = mediaType
    self.platforms = platforms
  }

  /// The image reference formed from ``name`` and ``tag``.
  public var reference: String { "\(name):\(tag)" }
}

/// An optional container-runtime capability for managing locally stored images.
public protocol ManagedImageRuntime: Sendable {
  /// List all locally stored images.
  func listImages() async throws -> [ManagedImage]

  /// Inspect a locally stored image, returning `nil` when it does not exist.
  func inspectManagedImage(ref: String) async throws -> ManagedImage?

  /// Remove a locally stored image and reclaim content no longer in use.
  func removeManagedImage(ref: String) async throws
}
