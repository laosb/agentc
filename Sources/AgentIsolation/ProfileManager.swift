import Foundation

/// Basic information about a profile, as surfaced by ``ProfileManager/list()``.
public struct ProfileInfo: Sendable, Equatable {
  /// The profile name (the directory's last path component).
  public let name: String
  /// Absolute path to the profile's directory, e.g. `~/.agentc/profiles/<name>`.
  public let path: URL

  public init(name: String, path: URL) {
    self.name = name
    self.path = path
  }
}

/// Detailed information about a profile, as surfaced by ``ProfileManager/inspect(name:)``.
public struct ProfileDetails: Sendable, Equatable {
  /// The profile name.
  public let name: String
  /// Absolute path to the profile's directory.
  public let path: URL
  /// Absolute path to the profile's `home` subdirectory (mounted as `/home/agent`).
  public let homeDirectory: URL
  /// Whether the `home` subdirectory exists on disk.
  public let homeDirectoryExists: Bool
  /// Total on-disk byte size of the profile directory (sum of regular file sizes).
  public let sizeBytes: Int64
  /// The most recent modification date across any file in the profile directory.
  public let lastModified: Date?

  public init(
    name: String,
    path: URL,
    homeDirectory: URL,
    homeDirectoryExists: Bool,
    sizeBytes: Int64,
    lastModified: Date?
  ) {
    self.name = name
    self.path = path
    self.homeDirectory = homeDirectory
    self.homeDirectoryExists = homeDirectoryExists
    self.sizeBytes = sizeBytes
    self.lastModified = lastModified
  }
}

/// Errors thrown by ``ProfileManager``.
public enum ProfileManagerError: Error, Equatable, Sendable {
  /// The profile storage directory exists but is not a directory.
  case storageNotADirectory(URL)
  /// A profile with the given name does not exist.
  case profileNotFound(name: String)
  /// The supplied name contains path separators or other invalid characters.
  case invalidProfileName(String)
}

/// Manages the on-disk profile storage directory for agentc (e.g. `~/.agentc/profiles`).
///
/// A `ProfileManager` can enumerate, inspect, and delete profiles. Each profile is a
/// subdirectory under the storage directory; a profile's `home` subdirectory is what
/// gets mounted into the container as `/home/agent`.
public struct ProfileManager: Sendable {
  /// The profile storage directory (e.g. `~/.agentc/profiles`).
  public let storageDirectory: URL

  public init(storageDirectory: URL) {
    self.storageDirectory = storageDirectory
  }

  /// List every profile present in the storage directory.
  ///
  /// Returns an empty array when the storage directory does not yet exist.
  /// Results are sorted alphabetically by name and exclude any entry whose name
  /// begins with a dot.
  public func list() throws -> [ProfileInfo] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: storageDirectory.path, isDirectory: &isDir) else {
      return []
    }
    guard isDir.boolValue else {
      throw ProfileManagerError.storageNotADirectory(storageDirectory)
    }

    let entries = try fm.contentsOfDirectory(
      at: storageDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )

    var infos: [ProfileInfo] = []
    for entry in entries {
      let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
      guard values?.isDirectory == true else { continue }
      infos.append(ProfileInfo(name: entry.lastPathComponent, path: entry))
    }
    infos.sort { $0.name < $1.name }
    return infos
  }

  /// Whether a profile with the given name exists on disk.
  public func exists(name: String) -> Bool {
    guard let dir = try? profileDirectory(for: name) else { return false }
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
  }

  /// Inspect a profile, returning details such as its home directory path and total size.
  public func inspect(name: String) throws -> ProfileDetails {
    let dir = try profileDirectory(for: name)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
      isDir.boolValue
    else {
      throw ProfileManagerError.profileNotFound(name: name)
    }

    let home = dir.appendingPathComponent("home")
    var homeIsDir: ObjCBool = false
    let homeExists = FileManager.default.fileExists(atPath: home.path, isDirectory: &homeIsDir)
    let (size, modified) = try Self.directoryStats(at: dir)

    return ProfileDetails(
      name: name,
      path: dir,
      homeDirectory: home,
      homeDirectoryExists: homeExists && homeIsDir.boolValue,
      sizeBytes: size,
      lastModified: modified
    )
  }

  /// Delete a profile. Throws ``ProfileManagerError/profileNotFound(name:)`` when
  /// no profile with the given name exists.
  public func delete(name: String) throws {
    let dir = try profileDirectory(for: name)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
      isDir.boolValue
    else {
      throw ProfileManagerError.profileNotFound(name: name)
    }
    try FileManager.default.removeItem(at: dir)
  }

  // MARK: - Helpers

  /// Resolve and validate a profile name to its on-disk directory.
  private func profileDirectory(for name: String) throws -> URL {
    try Self.validate(name: name)
    return storageDirectory.appendingPathComponent(name, isDirectory: true)
  }

  /// Reject names that contain path separators, are empty, or refer to the current or
  /// parent directory.
  private static func validate(name: String) throws {
    if name.isEmpty || name == "." || name == ".."
      || name.contains("/") || name.contains("\\")
      || name.contains("\0")
    {
      throw ProfileManagerError.invalidProfileName(name)
    }
  }

  /// Recursively walk a directory, summing regular-file sizes and tracking the most
  /// recent modification date.
  private static func directoryStats(at url: URL) throws -> (Int64, Date?) {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [
      .isRegularFileKey,
      .fileSizeKey,
      .totalFileAllocatedSizeKey,
      .fileAllocatedSizeKey,
      .contentModificationDateKey,
    ]
    guard
      let enumerator = fm.enumerator(
        at: url,
        includingPropertiesForKeys: keys,
        options: []
      )
    else {
      return (0, nil)
    }

    var total: Int64 = 0
    var mostRecent: Date? = nil
    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: Set(keys))
      if values.isRegularFile == true {
        let size = values.fileSize ?? values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
        total += Int64(size)
      }
      if let modified = values.contentModificationDate {
        if let current = mostRecent {
          if modified > current { mostRecent = modified }
        } else {
          mostRecent = modified
        }
      }
    }
    return (total, mostRecent)
  }
}
