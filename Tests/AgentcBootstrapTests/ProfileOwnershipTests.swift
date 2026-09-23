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

    @Test("A home the host says the mount presents is prepared without any chown")
    func preparePresentedHome() throws {
      let fixture = try DirectoryFixture()
      let home = fixture.root.appendingPathComponent("home").path
      // A different agent identity: any chown attempted as this user would fail.
      let target = (uid: identity.uid + 1, gid: identity.gid + 1)
      var viewed: [String] = []

      let prepared = try ProfileOwnership.preparePresentedHome(
        home: home, identity: target,
        agentView: { path, _ in
          viewed.append(path)
          return true
        })

      #expect(prepared)
      #expect(viewed == [home])
      for path in [home] + ProfileOwnership.managedDirectories.map({ "\(home)/\($0)" }) {
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFDIR)
        #expect(info.st_uid == identity.uid && info.st_gid == identity.gid)
      }
    }

    @Test("A home the agent does not see as its own is handed back for repair")
    func preparePresentedHomeMismatch() throws {
      let fixture = try DirectoryFixture()

      let prepared = try ProfileOwnership.preparePresentedHome(
        home: fixture.root.path, identity: identity, agentView: { _, _ in false })

      #expect(!prepared)
      // Repair creates and assigns the managed directories itself.
      #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
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
