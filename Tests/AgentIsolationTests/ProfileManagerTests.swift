import AgentIsolation
import Foundation
import Testing

@Suite("ProfileManager")
struct ProfileManagerTests {

  // MARK: - Helpers

  private func makeTempStorage() -> URL {
    let dir = URL(fileURLWithPath: "/tmp/agentc-pm-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func createProfile(
    _ name: String,
    in storage: URL,
    files: [(String, String)] = [("home/.bashrc", "# hello\n")]
  ) throws {
    let profileDir = storage.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
    for (relPath, contents) in files {
      let fileURL = profileDir.appendingPathComponent(relPath)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
  }

  // MARK: - list

  @Test("list returns empty when storage dir does not exist")
  func listMissingStorage() throws {
    let base = URL(fileURLWithPath: "/tmp/agentc-pm-missing-\(UUID().uuidString)")
    let manager = ProfileManager(storageDirectory: base)
    let profiles = try manager.list()
    #expect(profiles.isEmpty)
  }

  @Test("list returns empty when storage dir is empty")
  func listEmptyStorage() throws {
    let storage = makeTempStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    let manager = ProfileManager(storageDirectory: storage)
    #expect(try manager.list().isEmpty)
  }

  @Test("list returns all profiles, sorted alphabetically")
  func listProfilesSorted() throws {
    let storage = makeTempStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    for name in ["charlie", "alice", "bob"] {
      try createProfile(name, in: storage)
    }

    let manager = ProfileManager(storageDirectory: storage)
    let profiles = try manager.list()
    #expect(profiles.map(\.name) == ["alice", "bob", "charlie"])
    #expect(profiles[0].path.lastPathComponent == "alice")
  }

  @Test("list ignores regular files and hidden dotfiles at top level")
  func listIgnoresFilesAndHidden() throws {
    let storage = makeTempStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    try createProfile("alice", in: storage)
    // Random file at the profiles storage root
    try "junk".write(
      to: storage.appendingPathComponent("not-a-profile.txt"), atomically: true, encoding: .utf8)
    // Hidden directory
    try FileManager.default.createDirectory(
      at: storage.appendingPathComponent(".cache"), withIntermediateDirectories: true)

    let manager = ProfileManager(storageDirectory: storage)
    let profiles = try manager.list()
    #expect(profiles.map(\.name) == ["alice"])
  }

  @Test("list throws when storage path points to a regular file")
  func listNonDirectoryStorage() throws {
    let base = URL(fileURLWithPath: "/tmp/agentc-pm-file-\(UUID().uuidString)")
    try "not a dir".write(to: base, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: base) }

    let manager = ProfileManager(storageDirectory: base)
    #expect(throws: ProfileManagerError.self) {
      _ = try manager.list()
    }
  }

  // MARK: - exists

  @Test("exists returns true for existing profile, false otherwise")
  func existsBehaviour() throws {
    let storage = makeTempStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    try createProfile("alice", in: storage)
    let manager = ProfileManager(storageDirectory: storage)
    #expect(manager.exists(name: "alice"))
    #expect(!manager.exists(name: "bob"))
    // Invalid names return false (do not throw)
    #expect(!manager.exists(name: ""))
    #expect(!manager.exists(name: "../etc"))
  }

  // MARK: - inspect

  @Test("inspect returns details including home path and size")
  func inspectReturnsDetails() throws {
    let storage = makeTempStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    try createProfile(
      "alice",
      in: storage,
      files: [
        ("home/.bashrc", "abc"),
        ("home/projects/a.txt", "12345"),
      ]
    )

    let manager = ProfileManager(storageDirectory: storage)
    let details = try manager.inspect(name: "alice")

    #expect(details.name == "alice")
    #expect(details.path == storage.appendingPathComponent("alice"))
    #expect(details.homeDirectory == storage.appendingPathComponent("alice/home"))
    #expect(details.homeDirectoryExists)
    // 3 + 5 bytes of file content (may be higher on some filesystems where
    // directory entries are counted, but sum of regular files should match)
    #expect(details.sizeBytes == 8)
    #expect(details.lastModified != nil)
  }

  @Test("inspect marks missing home directory")
  func inspectMissingHome() throws {
    let storage = makeTempStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    // Profile directory without home/
    let profileDir = storage.appendingPathComponent("bare")
    try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

    let manager = ProfileManager(storageDirectory: storage)
    let details = try manager.inspect(name: "bare")
    #expect(!details.homeDirectoryExists)
    #expect(details.sizeBytes == 0)
  }

  @Test("inspect throws profileNotFound for missing profile")
  func inspectMissing() throws {
    let storage = makeTempStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    let manager = ProfileManager(storageDirectory: storage)
    #expect(throws: ProfileManagerError.profileNotFound(name: "ghost")) {
      _ = try manager.inspect(name: "ghost")
    }
  }

  @Test("inspect rejects names with path separators")
  func inspectRejectsInvalidNames() throws {
    let storage = makeTempStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    let manager = ProfileManager(storageDirectory: storage)
    for bad in ["../outside", "foo/bar", "", "."] {
      #expect(throws: ProfileManagerError.self) {
        _ = try manager.inspect(name: bad)
      }
    }
  }

  // MARK: - delete

  @Test("delete removes the profile directory")
  func deleteRemovesDirectory() throws {
    let storage = makeTempStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    try createProfile("alice", in: storage)
    try createProfile("bob", in: storage)

    let manager = ProfileManager(storageDirectory: storage)
    try manager.delete(name: "alice")

    #expect(!manager.exists(name: "alice"))
    #expect(manager.exists(name: "bob"))
    #expect(try manager.list().map(\.name) == ["bob"])
  }

  @Test("delete throws profileNotFound for missing profile")
  func deleteMissing() throws {
    let storage = makeTempStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    let manager = ProfileManager(storageDirectory: storage)
    #expect(throws: ProfileManagerError.profileNotFound(name: "ghost")) {
      try manager.delete(name: "ghost")
    }
  }

  @Test("delete rejects names with path separators")
  func deleteRejectsInvalid() throws {
    let storage = makeTempStorage()
    defer { try? FileManager.default.removeItem(at: storage) }

    // Create a sibling directory that a naive implementation might wipe.
    let outside = storage.deletingLastPathComponent().appendingPathComponent(
      "agentc-pm-sibling-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }

    let manager = ProfileManager(storageDirectory: storage)
    #expect(throws: ProfileManagerError.self) {
      try manager.delete(name: "../\(outside.lastPathComponent)")
    }
    #expect(FileManager.default.fileExists(atPath: outside.path))
  }
}
