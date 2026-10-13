import AgentIsolation
import Crypto
import Foundation

/// Immutable init filesystems, separate from the image store's legacy
/// `initfs.ext4`. References must be release-pinned (or digest-pinned), not
/// mutable tags such as `latest`. Upgrading vminit selects a new entry without
/// replacing a disk that a running VM may still have open.
struct InitFSCache: Sendable {
  static let imageReference = "ghcr.io/apple/containerization/vminit:0.50.0"

  let root: URL
  let reference: String
  let platform: String

  init(
    imageStorePath: URL, reference: String = Self.imageReference, platform: String = "linux/arm64"
  ) {
    root = imageStorePath.appendingPathComponent("initfs-cache")
    self.reference = reference
    self.platform = platform
  }

  /// v1 describes initBlock's 512 MiB ext4 and our atomic publication protocol.
  /// Bump it if the extraction format changes incompatibly.
  var key: String {
    let identity = "v1\u{0}\(reference)\u{0}\(platform)"
    return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  var filesystem: URL { root.appendingPathComponent("\(key).ext4") }
  var lockFile: URL { root.appendingPathComponent("\(key).lock") }
  var stagingDirectory: URL { root.appendingPathComponent("\(key).staging") }

  enum Error: Swift.Error {
    case invalidFilesystem(URL)
  }

  /// Holds a cross-process lock through download, extraction and publication.
  /// Only a completed extraction is renamed into the final location; `.exists`
  /// from the unpacker is never treated as success. Entries are not pruned:
  /// unlike session rootfs clones, live VMs mount these files directly.
  func prepare(unpack: (URL) async throws -> Void) async throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let lock = try await FileLock.acquireAsync(at: lockFile, mode: .exclusive)
    defer { lock.release() }

    // A previous process may have died while unpacking. Holding this key's
    // lock proves there is no writer left in its staging directory.
    if fm.fileExists(atPath: stagingDirectory.path) {
      try fm.removeItem(at: stagingDirectory)
    }
    if fm.fileExists(atPath: filesystem.path) {
      try validate(filesystem)
      return filesystem
    }

    try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: stagingDirectory) }
    let staged = stagingDirectory.appendingPathComponent("initfs.ext4")
    try await unpack(staged)
    try Task.checkCancellation()
    try validate(staged)
    try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: staged.path)
    // Both paths are on the same filesystem; moveItem publishes by rename.
    try fm.moveItem(at: staged, to: filesystem)
    return filesystem
  }

  private func validate(_ url: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      RootFSCache.hasEXT4Superblock(at: url)
    else {
      // Fail closed rather than changing a published disk beneath a live VM.
      throw Error.invalidFilesystem(url)
    }
  }
}
