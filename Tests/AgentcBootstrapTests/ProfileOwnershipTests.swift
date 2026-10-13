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

    @Test("Shared homes preserve private contents and initialize managed directories")
    func accessibleSharedHome() throws {
      let fixture = try DirectoryFixture()
      let sentinel = fixture.root.appendingPathComponent(".agentc-write-probe")
      try Data("keep me".utf8).write(to: sentinel)
      #expect(chmod(fixture.root.path, 0o700) == 0)
      #expect(chmod(sentinel.path, 0o600) == 0)

      // Repeated starts must leave contents and permissions intact.
      try ProfileOwnership.initializeAccessibleHome(at: fixture.root.path)
      try ProfileOwnership.initializeAccessibleHome(at: fixture.root.path)
      #expect(try Data(contentsOf: sentinel) == Data("keep me".utf8))
      for directory in [""] + ProfileOwnership.managedDirectories {
        let path = directory.isEmpty ? fixture.root.path : "\(fixture.root.path)/\(directory)"
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(
          try FileManager.default.contentsOfDirectory(atPath: path)
            .filter { $0.hasPrefix(".agentc-write-probe-") }.isEmpty)
      }
    }

    @Test("Shared home initialization rejects symlinked managed directories")
    func sharedHomeRejectsSymlink() throws {
      let fixture = try DirectoryFixture()
      let outside = try DirectoryFixture()
      #expect(symlink(outside.root.path, "\(fixture.root.path)/.local") == 0)
      #expect(throws: BootstrapError.self) {
        try ProfileOwnership.initializeAccessibleHome(at: fixture.root.path)
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: outside.root.path).isEmpty)
    }

    @Test("Shared profile access is checked as the non-root agent", .enabled(if: getuid() == 0))
    func sharedHomeDropsPrivileges() throws {
      let fixture = try DirectoryFixture()
      #expect(chmod(fixture.root.path, 0o700) == 0)
      #expect(throws: BootstrapError.self) {
        try ProfileOwnership.prepareSharedHome(
          at: fixture.root.path, identity: (uid: 12345, gid: 12345))
      }
      #expect(chown(fixture.root.path, 12345, 12345) == 0)
      try ProfileOwnership.prepareSharedHome(
        at: fixture.root.path, identity: (uid: 12345, gid: 12345))
      #expect(getuid() == 0)
      // A managed directory that is inaccessible must fail too.
      #expect(chown("\(fixture.root.path)/.cache", 0, 0) == 0)
      #expect(throws: BootstrapError.self) {
        try ProfileOwnership.prepareSharedHome(
          at: fixture.root.path, identity: (uid: 12345, gid: 12345))
      }
    }

    @Test("Shared access honors the agent's supplementary groups", .enabled(if: getuid() == 0))
    func sharedHomeSupplementaryGroups() throws {
      let fixture = try DirectoryFixture()
      #expect(chmod(fixture.root.path, 0o770) == 0)
      // Only supplementary group 0 grants UID/GID 12345 access to this fixture.
      try ProfileOwnership.prepareSharedHome(
        at: fixture.root.path, identity: (uid: 12345, gid: 12345),
        initializeGroups: { _ in
          var group: gid_t = 0
          return setgroups(1, &group)
        })
    }

    @Test(
      "An Apple share with synthetic root ownership is usable as the agent",
      .enabled(if: Helpers.envVar("AGENTC_TEST_APPLE_SHARED_HOME") != nil)
    )
    func appleSharedHome() throws {
      // Opt-in writable, disposable fixture: unlike realSharedMount this creates
      // managed directories. Run as guest root with an actual Apple virtiofs share.
      let path = try #require(Helpers.envVar("AGENTC_TEST_APPLE_SHARED_HOME"))
      try #require(getuid() == 0)
      var info = stat()
      try #require(lstat(path, &info) == 0)
      try #require(info.st_uid == 0)
      try #require(lchown(path, 12345, 12345) == -1 && errno == EPERM)
      try ProfileOwnership.prepareSharedHome(
        at: path, identity: (uid: 12345, gid: 12345))
      try ProfileOwnership.prepareSharedHome(
        at: path, identity: (uid: 12345, gid: 12345))
    }

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
      let error = #expect(throws: BootstrapError.self) {
        try ProfileOwnership.ensureOwnedDirectory(
          at: fixture.root.path, identity: (identity.uid + 1, identity.gid),
          changeOwner: { _, _, _ in
            errno = EPERM
            return -1
          },
          agentView: { _, _ in
            // Checking the agent's view must not clobber the chown's reason.
            errno = ENOENT
            return false
          })
      }
      #expect(error.map { "\($0)".contains(String(cString: strerror(EPERM))) } == true)
    }

    // Apple's virtiofs share reports every caller as the owner of every file:
    // root sees a mismatch it may not chown, while the agent user already sees
    // its own home. This used to log "cannot chown /home/agent" on every start.
    @Test("A mount that refuses chown but presents the directory to the agent is accepted")
    func presentedByMount() throws {
      let fixture = try DirectoryFixture()
      let target = (uid: identity.uid + 1, gid: identity.gid + 1)
      var viewed: [String] = []

      let ownership = try ProfileOwnership.ensureOwnedDirectory(
        at: fixture.root.path, identity: target,
        changeOwner: { _, _, _ in
          errno = EPERM
          return -1
        },
        agentView: { path, agent in
          #expect(agent.uid == target.uid && agent.gid == target.gid)
          viewed.append(path)
          return true
        })

      #expect(ownership == .presentedByMount)
      #expect(viewed == [fixture.root.path])
    }

    @Test("The agent's view of ownership is checked as the agent user")
    func agentView() throws {
      let fixture = try DirectoryFixture()
      let file = fixture.root.appendingPathComponent("file")
      try Data().write(to: file)

      #expect(ProfileOwnership.agentSeesOwnership(of: fixture.root.path, identity: identity))
      #expect(!ProfileOwnership.agentSeesOwnership(of: file.path, identity: identity))
      #expect(
        !ProfileOwnership.agentSeesOwnership(
          of: fixture.root.path, identity: (identity.uid + 1, identity.gid)))
      #expect(
        !ProfileOwnership.agentSeesOwnership(
          of: fixture.root.appendingPathComponent("missing").path, identity: identity))
    }

    @Test("A legacy pass does not walk a home the mount already presents to the agent")
    func legacyPassPresentedByMount() throws {
      let fixture = try DirectoryFixture()
      let nested = fixture.root.appendingPathComponent("project/file")
      try FileManager.default.createDirectory(
        at: nested.deletingLastPathComponent(), withIntermediateDirectories: false)
      try Data("profile contents".utf8).write(to: nested)
      let target = (uid: identity.uid + 1, gid: identity.gid + 1)
      var probed = 0

      let pass = try ProfileOwnership.legacyPass(
        home: fixture.root.path, identity: target,
        changeOwner: { _, _, _ in
          errno = EPERM
          return -1
        },
        agentView: { _, _ in true },
        writeProbe: { home, _ in
          #expect(home == fixture.root.path)
          probed += 1
          return nil
        })

      #expect(pass.home == .presentedByMount)
      #expect(probed == 1)
      // Only the managed directories it had to create; nothing was walked.
      #expect(pass.stats.visited == ProfileOwnership.managedDirectories.count)
      #expect(pass.stats.errors.isEmpty)
      for directory in ProfileOwnership.managedDirectories {
        var info = stat()
        #expect(lstat(fixture.root.appendingPathComponent(directory).path, &info) == 0)
      }
      var info = stat()
      #expect(lstat(nested.path, &info) == 0)
      #expect(info.st_uid == identity.uid && info.st_gid == identity.gid)
      #expect(try Data(contentsOf: nested) == Data("profile contents".utf8))
    }

    @Test("A legacy pass still fails when the agent cannot use a mount-presented home")
    func legacyPassPresentedButUnusable() throws {
      let fixture = try DirectoryFixture()
      let error = #expect(throws: BootstrapError.self) {
        try ProfileOwnership.legacyPass(
          home: fixture.root.path, identity: (identity.uid + 1, identity.gid + 1),
          changeOwner: { _, _, _ in
            errno = EPERM
            return -1
          },
          agentView: { _, _ in true },
          writeProbe: { home, _ in "the agent user cannot create files in \(home)" })
      }
      #expect(error.map { "\($0)".contains("cannot create files") } == true)
    }

    // Several sessions commonly share one profile, so their bootstraps probe the
    // same home at the same time. One must never trip over another's probe file.
    @Test("Concurrent write probes on one home do not interfere")
    func concurrentWriteProbes() async throws {
      let fixture = try DirectoryFixture()
      let home = fixture.root.path
      let identity = identity

      let failures = await withTaskGroup(of: String?.self) { group in
        for _ in 0..<64 {
          group.addTask {
            ProfileOwnership.writeProbeFailure(identity: identity, home: home)
          }
        }
        return await group.compactMap { $0 }.reduce(into: [String]()) { $0.append($1) }
      }

      #expect(failures.isEmpty)
      #expect(try FileManager.default.contentsOfDirectory(atPath: home).isEmpty)
    }

    @Test("Concurrent sessions can create the same directory")
    func concurrentDirectoryCreation() async throws {
      let fixture = try DirectoryFixture()
      let identity = identity

      for round in 0..<16 {
        let path = fixture.root.appendingPathComponent("dir-\(round)").path
        let failures = await withTaskGroup(of: String?.self) { group in
          for _ in 0..<16 {
            group.addTask {
              do {
                try ProfileOwnership.ensureOwnedDirectory(at: path, identity: identity)
                return nil
              } catch {
                return "\(error)"
              }
            }
          }
          return await group.compactMap { $0 }.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(failures.isEmpty)
      }
    }

    @Test("Wire constants match what the host sends")
    func wireConstants() {
      // Pinned from the host side in AgentIsolationTests as well.
      #expect(ProfileOwnership.Wire.protocolVersionKey == "AGENTC_OWNERSHIP_PROTOCOL")
      #expect(ProfileOwnership.Wire.controlDirectoryKey == "AGENTC_OWNERSHIP_CONTROL")
      #expect(ProfileOwnership.Wire.modeKey == "AGENTC_OWNERSHIP_MODE")
      #expect(ProfileOwnership.Wire.expectedUIDKey == "AGENTC_OWNERSHIP_EXPECT_UID")
      #expect(ProfileOwnership.Wire.expectedGIDKey == "AGENTC_OWNERSHIP_EXPECT_GID")
      #expect(
        ProfileOwnership.Wire.presentedByMountKey == "AGENTC_OWNERSHIP_PRESENTED_BY_MOUNT")
    }

    @Test("A legacy pass walks a home root already owns for the agent")
    func legacyPassWalksOwnedHome() throws {
      let fixture = try DirectoryFixture()
      try Data().write(to: fixture.root.appendingPathComponent("file"))

      let pass = try ProfileOwnership.legacyPass(
        home: fixture.root.path, identity: identity,
        agentView: { _, _ in
          Issue.record("an owned home needs no second opinion")
          return false
        },
        writeProbe: { _, _ in
          Issue.record("the walk establishes ownership; no probe needed")
          return nil
        })

      #expect(pass.home == .unchanged)
      // The home, its file, and the managed directories (two levels for .local/bin).
      #expect(pass.stats.visited == 2 + ProfileOwnership.managedDirectories.count)
      #expect(pass.stats.changed == 0)
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
