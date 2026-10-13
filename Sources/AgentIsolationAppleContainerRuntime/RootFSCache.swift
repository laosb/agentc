import AgentIsolation
import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

// MARK: - Identity

/// Everything that determines whether one unpacked rootfs can stand in for another.
///
/// Deliberately absent: the profile, the workspace, configuration scripts, the
/// bootstrap version and the kernel version. A cache entry holds **only unpacked
/// image contents** — nothing that a session executed — so none of those can change
/// what is stored here.
public struct RootFSCacheIdentity: Codable, Sendable, Equatable {
  /// Layout version of the cache directory itself.
  public var cacheSchemaVersion: Int
  /// Bumped whenever the unpacker or the ext4 formatting it produces changes in a
  /// way that makes previously written entries unusable. Review this whenever
  /// Containerization is upgraded.
  public var unpackerCompatibilityVersion: Int
  /// The digest of the *platform manifest*, never a mutable tag: retagging an
  /// image must not silently reuse the old filesystem.
  public var platformManifestDigest: String
  public var os: String
  public var architecture: String
  public var variant: String?
  public var rootfsCapacityBytes: UInt64
  public var ext4FormattingOptions: String

  public init(
    cacheSchemaVersion: Int = RootFSCache.cacheSchemaVersion,
    unpackerCompatibilityVersion: Int = RootFSCache.unpackerCompatibilityVersion,
    platformManifestDigest: String,
    os: String,
    architecture: String,
    variant: String?,
    rootfsCapacityBytes: UInt64,
    ext4FormattingOptions: String
  ) {
    self.cacheSchemaVersion = cacheSchemaVersion
    self.unpackerCompatibilityVersion = unpackerCompatibilityVersion
    self.platformManifestDigest = platformManifestDigest
    self.os = os
    self.architecture = architecture
    self.variant = variant
    self.rootfsCapacityBytes = rootfsCapacityBytes
    self.ext4FormattingOptions = ext4FormattingOptions
  }

  /// A canonical, order-stable serialization of every identity field.
  ///
  /// Field names are included so that adding a field later cannot accidentally
  /// collide with an older key whose values happened to concatenate the same way.
  var canonicalDescription: String {
    [
      "cacheSchemaVersion=\(cacheSchemaVersion)",
      "unpackerCompatibilityVersion=\(unpackerCompatibilityVersion)",
      "platformManifestDigest=\(platformManifestDigest)",
      "os=\(os)",
      "architecture=\(architecture)",
      "variant=\(variant ?? "")",
      "rootfsCapacityBytes=\(rootfsCapacityBytes)",
      "ext4FormattingOptions=\(ext4FormattingOptions)",
    ].joined(separator: "\n")
  }

  /// The cache key: a hex SHA-256 over ``canonicalDescription``.
  public var key: String {
    let digest = SHA256.hash(data: Data(canonicalDescription.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

/// What a published cache entry records about itself.
struct RootFSCacheManifest: Codable, Equatable {
  /// Version of this manifest's own layout.
  var manifestVersion: Int
  var identity: RootFSCacheIdentity
  /// Recorded for diagnostics and for invalidating entries when an image is removed.
  var imageReference: String
  var imageDigest: String
  /// Logical size of `rootfs.ext4`, checked on every hit.
  var rootfsLogicalSizeBytes: UInt64
  var createdAt: Date
}

// MARK: - Results and errors

/// How a session's rootfs was produced.
public struct RootFSMaterialization: Sendable, Equatable {
  public enum Source: String, Sendable {
    /// Reused an already-unpacked cache entry.
    case cacheHit
    /// Unpacked the image and published it to the cache.
    case cacheMiss
    /// Unpacked straight into the session, bypassing the cache.
    case uncached
  }

  public var source: Source
  /// `nil` when nothing was cloned or copied, i.e. the uncached path.
  public var method: RootFSMaterializationMethod?
  /// Why the cache was bypassed, when it was.
  public var bypassReason: String?
}

public enum RootFSCacheError: Error, CustomStringConvertible {
  case unpackProducedNothing(URL)
  case sessionRootfsExists(URL)

  public var description: String {
    switch self {
    case .unpackProducedNothing(let url):
      return "the unpacker did not produce a rootfs at \(url.path)"
    case .sessionRootfsExists(let url):
      return "a session rootfs already exists at \(url.path)"
    }
  }
}

// MARK: - Cache

/// An immutable cache of unpacked image root filesystems.
///
/// Each entry is written once and then never modified. A session never attaches a
/// cached file to a VM — not even read-only — so nothing a workload does can leak
/// into it. Sessions get an independent clone or copy, which is deleted with the
/// rest of the session, keeping every launch disposable.
public struct RootFSCache: Sendable {
  /// Layout version of the on-disk cache. Bump when the directory shape changes.
  public static let cacheSchemaVersion = 1

  /// Bump when Containerization's unpacker or ext4 formatting changes in a way
  /// that invalidates previously written entries.
  public static let unpackerCompatibilityVersion = 1

  /// Default number of complete entries to keep.
  public static let defaultMaxEntries = 4

  /// The cache root, e.g. `<imagestore>/rootfs-cache/v1`.
  public let root: URL
  let fileOperations: any RootFSFileOperations
  let maxEntries: Int
  let diagnostics: StartupDiagnostics?

  public init(
    imageStorePath: URL,
    fileOperations: any RootFSFileOperations = SystemRootFSFileOperations(),
    maxEntries: Int = RootFSCache.defaultMaxEntries,
    diagnostics: StartupDiagnostics? = nil
  ) {
    self.root =
      imageStorePath
      .appendingPathComponent("rootfs-cache")
      .appendingPathComponent("v\(Self.cacheSchemaVersion)")
    self.fileOperations = fileOperations
    self.maxEntries = maxEntries
    self.diagnostics = diagnostics
  }

  var locksDirectory: URL { root.appendingPathComponent("locks") }
  var entriesDirectory: URL { root.appendingPathComponent("entries") }
  var stagingDirectory: URL { root.appendingPathComponent("staging") }

  func entryDirectory(for key: String) -> URL {
    entriesDirectory.appendingPathComponent(key)
  }
  func lockFile(for key: String) -> URL {
    locksDirectory.appendingPathComponent("\(key).lock")
  }

  // MARK: Materialization

  /// Produce an independent writable rootfs for a session, reusing unpacked image
  /// data when a valid entry exists.
  ///
  /// - Parameters:
  ///   - identity: Everything that makes one unpacked rootfs interchangeable with
  ///     another. Derived from an already-resolved image, so a concurrent tag
  ///     update cannot mix one image's filesystem with another's configuration.
  ///   - sessionRootfs: Where the session's writable disk should end up. Its
  ///     parent directory is created if missing; the file itself must not exist.
  ///   - unpack: Unpacks the resolved image to the given destination path.
  ///
  /// The cache lock is held for the whole of validation, unpacking, publication
  /// and cloning, and released before the caller starts the container: from that
  /// point the session no longer depends on the cache entry.
  public func materialize(
    identity: RootFSCacheIdentity,
    imageReference: String,
    imageDigest: String,
    sessionRootfs: URL,
    unpack: (URL) async throws -> Void
  ) async throws -> RootFSMaterialization {
    guard !FileManager.default.fileExists(atPath: sessionRootfs.path) else {
      throw RootFSCacheError.sessionRootfsExists(sessionRootfs)
    }
    try FileManager.default.createDirectory(
      at: sessionRootfs.deletingLastPathComponent(), withIntermediateDirectories: true)

    let key = identity.key

    // Anything that stops us using the shared cache — an unwritable cache
    // directory, a lock we cannot take, a publication that fails — must not stop
    // the session. It falls back to unpacking straight into the session file,
    // which is exactly what agentc did before this cache existed.
    let lock: FileLock
    do {
      try prepareDirectories()
      lock = try await acquireLock(for: key)
    } catch let error as CancellationError {
      throw error
    } catch {
      return try await unpackUncached(
        into: sessionRootfs, reason: "cache-unavailable: \(error)", unpack: unpack)
    }
    defer { lock.release() }

    // Abandoned staging directories for this key are ours to clean now that we
    // hold its lock; no one else can be writing them.
    cleanStaging(for: key)

    let entryRootfs = entryDirectory(for: key).appendingPathComponent("rootfs.ext4")
    var source: RootFSMaterialization.Source

    if validateEntry(key: key, identity: identity) {
      source = .cacheHit
    } else {
      do {
        try await buildEntry(
          key: key, identity: identity, imageReference: imageReference,
          imageDigest: imageDigest, unpack: unpack)
        source = .cacheMiss
      } catch let error as CancellationError {
        throw error
      } catch {
        // Publication failed but the image is still perfectly unpackable, so the
        // session proceeds uncached rather than failing.
        return try await unpackUncached(
          into: sessionRootfs, reason: "publish-failed: \(error)", unpack: unpack)
      }
    }

    let method: RootFSMaterializationMethod
    do {
      // Host-read-only, so nothing on the host casually writes into the template.
      // This is a host file mode: it says nothing about permissions inside the ext4.
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o444], ofItemAtPath: entryRootfs.path)
      method = try fileOperations.materialize(from: entryRootfs, to: sessionRootfs)
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: sessionRootfs.path)
    } catch {
      // Never leave a half-written session disk behind for a retry to inherit.
      try? FileManager.default.removeItem(at: sessionRootfs)
      throw error
    }

    touch(entryDirectory(for: key))
    return RootFSMaterialization(source: source, method: method)
  }

  /// Unpack directly into the session, with no cache involvement.
  private func unpackUncached(
    into sessionRootfs: URL,
    reason: String,
    unpack: (URL) async throws -> Void
  ) async throws -> RootFSMaterialization {
    try? FileManager.default.removeItem(at: sessionRootfs)
    do {
      try await unpack(sessionRootfs)
    } catch {
      try? FileManager.default.removeItem(at: sessionRootfs)
      throw error
    }
    guard FileManager.default.fileExists(atPath: sessionRootfs.path) else {
      throw RootFSCacheError.unpackProducedNothing(sessionRootfs)
    }
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: sessionRootfs.path)
    return RootFSMaterialization(source: .uncached, method: nil, bypassReason: reason)
  }

  /// Unpack into a unique staging directory, then publish it atomically.
  ///
  /// A failed or interrupted build only ever leaves a staging directory behind,
  /// which the next holder of this key's lock deletes. It can never become a hit.
  private func buildEntry(
    key: String,
    identity: RootFSCacheIdentity,
    imageReference: String,
    imageDigest: String,
    unpack: (URL) async throws -> Void
  ) async throws {
    let staging = stagingDirectory.appendingPathComponent(
      "\(key)-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    var published = false
    defer {
      if !published { try? FileManager.default.removeItem(at: staging) }
    }

    let stagedRootfs = staging.appendingPathComponent("rootfs.ext4")
    try await unpack(stagedRootfs)

    var info = stat()
    guard lstat(stagedRootfs.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      throw RootFSCacheError.unpackProducedNothing(stagedRootfs)
    }

    let manifest = RootFSCacheManifest(
      manifestVersion: 1,
      identity: identity,
      imageReference: imageReference,
      imageDigest: imageDigest,
      rootfsLogicalSizeBytes: UInt64(info.st_size),
      createdAt: Date()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(
      to: staging.appendingPathComponent("manifest.json"), options: .atomic)

    // Publish by rename, which is atomic. Any entry already in place is first
    // retired into staging; every reader takes this key's lock, so none of them
    // can observe the moment in between.
    let destination = entryDirectory(for: key)
    var retired: URL?
    if FileManager.default.fileExists(atPath: destination.path) {
      let target = stagingDirectory.appendingPathComponent(
        "\(key)-retired-\(UUID().uuidString.lowercased())")
      try FileManager.default.moveItem(at: destination, to: target)
      retired = target
    }
    do {
      try FileManager.default.moveItem(at: staging, to: destination)
    } catch {
      // Put the previous entry back rather than leaving the key with nothing.
      if let retired { try? FileManager.default.moveItem(at: retired, to: destination) }
      throw error
    }
    if let retired { try? FileManager.default.removeItem(at: retired) }
    published = true
  }

  // MARK: Validation

  /// Whether the entry for `key` is complete and usable.
  ///
  /// Checks the manifest, the file type, and the recorded size, plus a bounded
  /// filesystem-header probe. The disk itself is never hashed or traversed: that
  /// would cost more than the unpack this cache exists to avoid.
  func validateEntry(key: String, identity: RootFSCacheIdentity) -> Bool {
    let directory = entryDirectory(for: key)
    let manifestURL = directory.appendingPathComponent("manifest.json")
    let rootfsURL = directory.appendingPathComponent("rootfs.ext4")

    guard let data = try? Data(contentsOf: manifestURL) else { return false }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let manifest = try? decoder.decode(RootFSCacheManifest.self, from: data) else {
      return false
    }
    guard manifest.manifestVersion == 1, manifest.identity == identity else { return false }

    // `lstat`, so a symlink pointing at someone else's file is rejected rather
    // than followed.
    var info = stat()
    guard lstat(rootfsURL.path, &info) == 0 else { return false }
    guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
    guard UInt64(info.st_size) == manifest.rootfsLogicalSizeBytes else { return false }

    return Self.hasEXT4Superblock(at: rootfsURL)
  }

  /// Read just enough of the file to confirm it looks like an ext4 filesystem.
  ///
  /// The superblock lives at byte 1024 and its magic is a little-endian `0xEF53`
  /// at offset 0x38 within it.
  static func hasEXT4Superblock(at url: URL) -> Bool {
    let superblockOffset = 1024
    let magicOffset = superblockOffset + 0x38
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }

    var magic: [UInt8] = [0, 0]
    let read = magic.withUnsafeMutableBytes { buffer in
      pread(descriptor, buffer.baseAddress, 2, off_t(magicOffset))
    }
    guard read == 2 else { return false }
    return UInt16(magic[0]) | (UInt16(magic[1]) << 8) == 0xEF53
  }

  // MARK: Maintenance

  /// Wait for this key's exclusive lock without blocking a cooperative thread.
  ///
  /// A blocking `flock` would park an executor thread for however long another
  /// process's unpack takes, which can be minutes. Polling with backoff keeps the
  /// wait cancellable and leaves the pool free.
  private func acquireLock(for key: String) async throws -> FileLock {
    try await FileLock.acquireAsync(at: lockFile(for: key), mode: .exclusive)
  }

  private func prepareDirectories() throws {
    for directory in [locksDirectory, entriesDirectory, stagingDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  /// Remove staging directories belonging to `key`. Only safe while holding its lock.
  private func cleanStaging(for key: String) {
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: stagingDirectory, includingPropertiesForKeys: nil)) ?? []
    for entry in entries where entry.lastPathComponent.hasPrefix("\(key)-") {
      try? FileManager.default.removeItem(at: entry)
    }
  }

  /// Record that an entry was used, for least-recently-used eviction.
  private func touch(_ directory: URL) {
    try? FileManager.default.setAttributes(
      [.modificationDate: Date()], ofItemAtPath: directory.path)
  }

  /// Drop least-recently-used entries beyond ``maxEntries``.
  ///
  /// Only host metadata is inspected — no entry is opened, hashed, or traversed.
  /// Entries whose locks are held are skipped rather than waited for: this runs
  /// after a session has already been handed its rootfs, and must never delay one.
  /// An in-flight session is unaffected either way, because its disk is already an
  /// independent file.
  public func prune() {
    let candidates =
      (try? FileManager.default.contentsOfDirectory(
        at: entriesDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []

    let entries: [(url: URL, modified: Date)] = candidates.compactMap { url in
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
      guard values?.isDirectory == true else { return nil }
      return (url, values?.contentModificationDate ?? .distantPast)
    }
    guard entries.count > maxEntries else { return }

    let doomed = entries.sorted { $0.modified > $1.modified }.dropFirst(maxEntries)
    for entry in doomed {
      let key = entry.url.lastPathComponent
      guard let lock = try? FileLock.tryAcquire(at: lockFile(for: key), mode: .exclusive)
      else { continue }
      defer { lock.release() }
      try? FileManager.default.removeItem(at: entry.url)
      cleanStaging(for: key)
    }
  }

  /// Drop every entry unpacked from `imageDigest`.
  ///
  /// Called when an image is removed. Sessions that already cloned an affected
  /// entry keep running: their disks are independent files that no longer refer
  /// to the cache at all.
  public func invalidate(imageDigest: String) {
    let candidates =
      (try? FileManager.default.contentsOfDirectory(
        at: entriesDirectory, includingPropertiesForKeys: nil)) ?? []
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    for entry in candidates {
      guard let data = try? Data(contentsOf: entry.appendingPathComponent("manifest.json")),
        let manifest = try? decoder.decode(RootFSCacheManifest.self, from: data),
        manifest.imageDigest == imageDigest
      else { continue }
      let key = entry.lastPathComponent
      guard let lock = try? FileLock.tryAcquire(at: lockFile(for: key), mode: .exclusive)
      else { continue }
      defer { lock.release() }
      try? FileManager.default.removeItem(at: entry)
      cleanStaging(for: key)
    }
  }
}
