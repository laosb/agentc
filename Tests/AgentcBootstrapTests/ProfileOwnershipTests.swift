#if os(Linux)
  import FoundationEssentials
  #if canImport(Musl)
    import Musl
  #else
    import Glibc
  #endif
  import Testing
  @testable import agentc_bootstrap

  @Suite("Bootstrap profile ownership")
  struct BootstrapProfileOwnershipTests {
    private let identity = (uid: getuid(), gid: getgid())

    @Test(
      "An already-owned shared mount works when a real chown returns EPERM",
      .enabled(if: Helpers.envVar("AGENTC_TEST_UNCHOWNABLE_DIRECTORY") != nil)
    )
    func realSharedMount() throws {
      let path = try #require(Helpers.envVar("AGENTC_TEST_UNCHOWNABLE_DIRECTORY"))
      var info = stat()
      try #require(lstat(path, &info) == 0)
      try #require(info.st_mode & S_IFMT == S_IFDIR)
      // Only attempt an idempotent chown on this opt-in fixture. It may be an
      // actual profile mount, so never change its owner, mode, or contents.
      try #require(info.st_uid == identity.uid && info.st_gid == identity.gid)
      let result = lchown(path, identity.uid, identity.gid)
      let errorCode = errno
      try #require(result == -1 && errorCode == EPERM)

      try ProfileOwnership.ensureOwnedDirectory(at: path, identity: identity)
    }

    @Test("An already-owned home needs no chown, even when the mount rejects it")
    func alreadyOwnedHome() throws {
      let fixture = try DirectoryFixture()
      let sentinel = fixture.root.appendingPathComponent("keep-me")
      try Data("profile contents".utf8).write(to: sentinel)
      #expect(chmod(fixture.root.path, 0o750) == 0)

      var calls = 0
      try ProfileOwnership.ensureOwnedDirectory(at: fixture.root.path, identity: identity) {
        _, _, _ in
        calls += 1
        errno = EPERM
        return -1
      }

      #expect(calls == 0)
      #expect(try Data(contentsOf: sentinel) == Data("profile contents".utf8))
      var info = stat()
      #expect(lstat(fixture.root.path, &info) == 0)
      #expect(info.st_mode & 0o777 == 0o750)
    }

    @Test("A new directory uses its actual owner instead of assuming root")
    func newlyCreatedDirectoryAlreadyOwned() throws {
      let fixture = try DirectoryFixture()
      let path = fixture.root.appendingPathComponent("new-home").path
      var calls = 0

      try ProfileOwnership.ensureOwnedDirectory(at: path, identity: identity) { _, _, _ in
        calls += 1
        errno = EPERM
        return -1
      }

      #expect(calls == 0)
      var info = stat()
      #expect(lstat(path, &info) == 0)
      #expect(info.st_mode & S_IFMT == S_IFDIR)
      #expect(info.st_mode & 0o777 == 0o700)
      #expect(info.st_uid == identity.uid)
      #expect(info.st_gid == identity.gid)
    }

    @Test("A mismatched UID or GID still requires repair", arguments: [true, false])
    func differentOwnerIsRepaired(changeUID: Bool) throws {
      let fixture = try DirectoryFixture()
      let target = (
        uid: identity.uid + (changeUID ? 1 : 0),
        gid: identity.gid + (changeUID ? 0 : 1)
      )
      var calls = 0

      try ProfileOwnership.ensureOwnedDirectory(at: fixture.root.path, identity: target) {
        path, uid, gid in
        #expect(path == fixture.root.path)
        #expect(uid == target.uid)
        #expect(gid == target.gid)
        calls += 1
        return 0
      }

      #expect(calls == 1)
    }

    @Test("A required chown failure is still reported")
    func requiredRepairFailure() throws {
      let fixture = try DirectoryFixture()
      #expect(throws: BootstrapError.self) {
        try ProfileOwnership.ensureOwnedDirectory(
          at: fixture.root.path, identity: (identity.uid + 1, identity.gid)
        ) { _, _, _ in
          errno = EPERM
          return -1
        }
      }
    }

    @Test("A new directory with a different owner is assigned to the agent")
    func newDirectoryNeedsRepair() throws {
      let fixture = try DirectoryFixture()
      let path = fixture.root.appendingPathComponent("new-home").path
      let target = (uid: identity.uid + 1, gid: identity.gid + 1)
      var calls = 0

      try ProfileOwnership.ensureOwnedDirectory(at: path, identity: target) {
        actualPath, uid, gid in
        #expect(actualPath == path)
        #expect(uid == target.uid)
        #expect(gid == target.gid)
        calls += 1
        return 0
      }

      #expect(calls == 1)
    }

    @Test("Home initialization rejects a symlink or regular file", arguments: [true, false])
    func rejectsNonDirectory(isSymlink: Bool) throws {
      let fixture = try DirectoryFixture()
      let path = fixture.root.appendingPathComponent("invalid-home").path
      if isSymlink {
        #expect(symlink(fixture.root.path, path) == 0)
      } else {
        try Data().write(to: URL(fileURLWithPath: path))
      }
      var calls = 0

      #expect(throws: BootstrapError.self) {
        try ProfileOwnership.ensureOwnedDirectory(at: path, identity: identity) { _, _, _ in
          calls += 1
          return 0
        }
      }
      #expect(calls == 0)
    }

    @Test("Failure to create the home is reported without attempting chown")
    func creationFailure() throws {
      let fixture = try DirectoryFixture()
      let path = fixture.root.appendingPathComponent("missing-parent/home").path
      var calls = 0

      #expect(throws: BootstrapError.self) {
        try ProfileOwnership.ensureOwnedDirectory(at: path, identity: identity) { _, _, _ in
          calls += 1
          return 0
        }
      }
      #expect(calls == 0)
    }
  }

  private final class DirectoryFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bootstrap-ownership-\(UUID().uuidString)")

    init() throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    deinit {
      try? FileManager.default.removeItem(at: root)
    }
  }
#endif
