#if canImport(FoundationEssentials) && canImport(Musl)
  import FoundationEssentials
  @preconcurrency import Musl

  /// Guest side of the profile-ownership protocol.
  ///
  /// The host mounts the profile home at `/home/agent` and needs it owned by
  /// whichever account this image calls `agent`. Doing that with a recursive
  /// `chown` on every start costs a full tree walk each time, which dominates
  /// startup once a profile has a real dependency cache in it.
  ///
  /// When the host declares the protocol, the bootstrap instead **verifies** the
  /// state a previous run established — a fixed set of checks that touches no more
  /// than a handful of paths — and only walks the tree when the host asked it to
  /// initialize or migrate. It then reports the identity it actually resolved and
  /// waits for the host to acknowledge before anything else runs.
  ///
  /// The image's own `agent` account is used as-is. No UID is forced, no image
  /// account is renumbered, and the workspace is never touched.
  enum ProfileOwnership {
    static let homePath = "/home/agent"

    /// Directories the bootstrap is responsible for.
    ///
    /// Created and given to the agent user when missing. Existing ones are checked
    /// but never created again, so an established profile keeps its contents.
    static let managedDirectories = [".local", ".local/bin", ".cache", ".config"]

    /// Repeated from `AgentIsolation.ProfileOwnershipProtocol`; the bootstrap has
    /// no dependencies and cannot import it. Both sides are pinned by tests.
    enum Wire {
      static let version = 1
      static let reportFileName = "ownership-report.json"
      static let ackFileName = "ownership-ack.json"
      static let protocolVersionKey = "AGENTC_OWNERSHIP_PROTOCOL"
      static let controlDirectoryKey = "AGENTC_OWNERSHIP_CONTROL"
      static let modeKey = "AGENTC_OWNERSHIP_MODE"
      static let expectedUIDKey = "AGENTC_OWNERSHIP_EXPECT_UID"
      static let expectedGIDKey = "AGENTC_OWNERSHIP_EXPECT_GID"
      /// How long the guest waits to be released before giving up.
      static let acknowledgementTimeoutSeconds = 120.0
    }

    struct Report: Encodable {
      var version = Wire.version
      var status: String
      var uid: UInt32
      var gid: UInt32
      var visited: Int
      var changed: Int
      var detail: String?
    }

    struct Acknowledgement: Decodable {
      var version: Int
      var decision: String
    }

    enum Status {
      static let verified = "verified"
      static let initialized = "initialized"
      static let repaired = "repaired"
      static let needsRepair = "needs-repair"
      static let failed = "failed"
    }

    /// Bring the profile home to a usable state before anything else runs.
    ///
    /// Must be called as root, after the agent user exists and before privileges
    /// are dropped. Returns normally only when preparation scripts and the
    /// workload may proceed.
    static func settle() throws {
      guard let identity = resolveAgentIdentity() else {
        throw BootstrapError.setupFailed("agent user missing after creation")
      }

      guard Helpers.envVar(Wire.protocolVersionKey) == String(Wire.version),
        let controlDirectory = Helpers.envVar(Wire.controlDirectoryKey),
        !controlDirectory.isEmpty
      else {
        // The host does not speak this protocol — an older agentc, a custom
        // bootstrap contract, or a runtime whose mapping has not been
        // characterized. Fall back to repairing on every start, exactly as
        // before, and never wait for a message that is not coming.
        try legacyRepair(identity: identity)
        return
      }

      let mode = Helpers.envVar(Wire.modeKey) ?? "repair"
      let report = makeReport(mode: mode, identity: identity)

      try write(report: report, to: controlDirectory)
      let decision = try awaitAcknowledgement(in: controlDirectory)
      guard decision == "continue" else {
        // The host is taking over: it will stop this container, so nothing here
        // may run. Report why, then stop.
        bootstrapLogger.warning(
          "Profile ownership not settled (\(report.status)); the host is handling it")
        exit(75)
      }
    }

    // MARK: - Deciding what to do

    private static func makeReport(mode: String, identity: (uid: uid_t, gid: gid_t)) -> Report {
      let start = Diagnostics.now()
      let report = buildReport(mode: mode, identity: identity)
      Diagnostics.record(
        phase: "bootstrap.profile_ownership",
        startedAt: start,
        outcome: report.status == Status.failed ? "failure" : "success",
        attributes: [
          ("mode", mode),
          ("action", report.status),
          ("visited", String(report.visited)),
          ("changed", String(report.changed)),
        ])
      return report
    }

    private static func buildReport(mode: String, identity: (uid: uid_t, gid: gid_t)) -> Report {
      guard mode == "verify" else { return repairReport(identity: identity) }

      let uid = UInt32(identity.uid)
      let gid = UInt32(identity.gid)
      let expectedUID = Helpers.envVar(Wire.expectedUIDKey).flatMap { UInt32($0) }
      let expectedGID = Helpers.envVar(Wire.expectedGIDKey).flatMap { UInt32($0) }

      func needsRepair(_ detail: String) -> Report {
        // Nothing has been touched, and nothing will run: the host restarts us
        // under an exclusive lease to repair.
        Report(
          status: Status.needsRepair, uid: uid, gid: gid, visited: 0, changed: 0, detail: detail)
      }

      if let detail = identityMismatch(
        identity: identity, expectedUID: expectedUID, expectedGID: expectedGID)
      {
        return needsRepair(detail)
      }

      // A managed directory that is merely missing is ours to create — that is
      // cheap and bounded. One that exists with the wrong owner is not ours to
      // paper over: it means the record no longer describes this profile.
      let created: Int
      do {
        created = try createMissingManagedDirectories(identity: identity)
      } catch {
        return needsRepair("\(error)")
      }

      if let detail = accessFailure(identity: identity) {
        return needsRepair(detail)
      }

      // `visited` counts what was touched, which on the fast path is only ever
      // newly created managed directories — never a descendant of the profile.
      return Report(
        status: Status.verified, uid: uid, gid: gid, visited: created, changed: created,
        detail: nil)
    }

    /// Whether the guest is who the record says it is.
    static func identityMismatch(
      identity: (uid: uid_t, gid: gid_t), expectedUID: UInt32?, expectedGID: UInt32?
    ) -> String? {
      guard let expectedUID, let expectedGID else {
        return "the host sent no expected identity"
      }
      // The image's agent account may have been renumbered, or this may be a
      // different image altogether. Either way the record does not describe us.
      guard UInt32(identity.uid) == expectedUID, UInt32(identity.gid) == expectedGID else {
        return
          "guest identity is \(identity.uid):\(identity.gid), record expects "
          + "\(expectedUID):\(expectedGID)"
      }
      return nil
    }

    /// The fixed set of checks that stands in for a tree walk.
    ///
    /// Returns a description of the first failure, or `nil` when the profile looks
    /// usable. Note what this deliberately does *not* claim: that every descendant
    /// is correctly owned. No cheap check can establish that, which is why an
    /// import or a manual ownership change still needs an explicit repair.
    static func accessFailure(identity: (uid: uid_t, gid: gid_t)) -> String? {
      var homeInfo = stat()
      guard lstat(homePath, &homeInfo) == 0 else {
        return "\(homePath) is missing"
      }
      guard (homeInfo.st_mode & S_IFMT) == S_IFDIR else {
        return "\(homePath) is not a directory"
      }
      guard homeInfo.st_uid == identity.uid, homeInfo.st_gid == identity.gid else {
        return "\(homePath) is owned by \(homeInfo.st_uid):\(homeInfo.st_gid)"
      }

      for directory in managedDirectories {
        let path = "\(homePath)/\(directory)"
        var info = stat()
        guard lstat(path, &info) == 0 else {
          return "\(path) is missing"
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
          return "\(path) is not a directory"
        }
        guard info.st_uid == identity.uid, info.st_gid == identity.gid else {
          return "\(path) is owned by \(info.st_uid):\(info.st_gid)"
        }
      }

      // Ownership metadata is not the whole story: a runtime's mapping decides
      // whether the agent user can actually write. Prove it rather than assume it.
      if let failure = writeProbeFailure(identity: identity) {
        return failure
      }
      return nil
    }

    /// Create a file as the agent user, write to it, and delete it again.
    ///
    /// Runs in a forked child so the bootstrap itself keeps its privileges.
    static func writeProbeFailure(identity: (uid: uid_t, gid: gid_t)) -> String? {
      let path = "\(homePath)/.agentc-write-probe"
      unlink(path)

      let child = fork()
      if child == 0 {
        // Child: drop to the agent user and try to use the home directory.
        if setgid(identity.gid) != 0 { _exit(11) }
        if setuid(identity.uid) != 0 { _exit(12) }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if descriptor < 0 { _exit(13) }
        let byte: [UInt8] = [0x61]
        let written = byte.withUnsafeBytes { Musl.write(descriptor, $0.baseAddress, 1) }
        close(descriptor)
        if written != 1 { _exit(14) }
        if unlink(path) != 0 { _exit(15) }
        _exit(0)
      }
      guard child > 0 else {
        return "cannot fork to probe \(homePath): \(String(cString: strerror(errno)))"
      }

      var status: Int32 = 0
      waitpid(child, &status, 0)
      let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
      guard code != 0 else { return nil }

      // Leave nothing behind if the child died between create and unlink.
      unlink(path)
      switch code {
      case 11, 12: return "cannot become the agent user in this container"
      case 13: return "the agent user cannot create files in \(homePath)"
      case 14: return "the agent user cannot write in \(homePath)"
      case 15: return "the agent user cannot delete files in \(homePath)"
      default: return "the write probe in \(homePath) failed (exit \(code))"
      }
    }

    // MARK: - Repair

    private static func repairReport(identity: (uid: uid_t, gid: gid_t)) -> Report {
      let uid = UInt32(identity.uid)
      let gid = UInt32(identity.gid)

      // The home has to exist and be ours before anything else can look at it.
      do {
        try ensureHomeDirectory(identity: identity)
      } catch {
        return Report(
          status: Status.failed, uid: uid, gid: gid, visited: 0, changed: 0,
          detail: "\(error)")
      }

      // A brand new profile needs initialization, not a migration: there is
      // nothing to walk.
      if isEmptyHome() {
        do {
          let created = try createMissingManagedDirectories(identity: identity)
          return Report(
            status: Status.initialized, uid: uid, gid: gid, visited: created, changed: created,
            detail: nil)
        } catch {
          return Report(
            status: Status.failed, uid: uid, gid: gid, visited: 0, changed: 0,
            detail: "\(error)")
        }
      }

      do {
        let stats = try OwnershipWalker.repair(
          root: homePath, uid: identity.uid, gid: identity.gid)
        // Managed directories may still be missing from a legacy profile.
        let created = try createMissingManagedDirectories(identity: identity)
        if let failure = writeProbeFailure(identity: identity) {
          return Report(
            status: Status.failed, uid: uid, gid: gid, visited: stats.visited,
            changed: stats.changed, detail: failure)
        }
        return Report(
          status: Status.repaired, uid: uid, gid: gid,
          visited: stats.visited + created, changed: stats.changed + created, detail: nil)
      } catch {
        // A partial repair is a failure. Nothing gets published, and no broad
        // permission relaxation is attempted as a consolation prize.
        return Report(
          status: Status.failed, uid: uid, gid: gid, visited: 0, changed: 0,
          detail: "\(error)")
      }
    }

    /// Whether the home directory has no entries beyond `.` and `..`.
    static func isEmptyHome() -> Bool {
      guard let handle = opendir(homePath) else { return false }
      defer { closedir(handle) }
      while let entry = readdir(handle) {
        var nameBuffer = entry.pointee.d_name
        let name = withUnsafePointer(to: &nameBuffer) {
          String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        if name == "." || name == ".." { continue }
        return false
      }
      return true
    }

    /// Create the home directory if it is missing and give it to the agent user.
    ///
    /// Only called while repairing. Verification deliberately does *not* do this:
    /// a home with the wrong owner means the record no longer describes this
    /// profile, and quietly fixing it would hide that from the host.
    static func ensureHomeDirectory(identity: (uid: uid_t, gid: gid_t)) throws {
      var info = stat()
      if lstat(homePath, &info) != 0 {
        guard mkdir(homePath, 0o700) == 0 else {
          throw BootstrapError.setupFailed(
            "cannot create \(homePath): \(String(cString: strerror(errno)))")
        }
      }
      guard chown(homePath, identity.uid, identity.gid) == 0 else {
        throw BootstrapError.setupFailed(
          "cannot chown \(homePath): \(String(cString: strerror(errno)))")
      }
    }

    /// Create any missing managed directories and give them to the agent user.
    ///
    /// Existing directories are left exactly as they are — only what this call
    /// creates gets its ownership assigned here. Returns how many were created,
    /// which is the only thing the fast path ever touches.
    @discardableResult
    static func createMissingManagedDirectories(identity: (uid: uid_t, gid: gid_t)) throws -> Int {
      var created = 0
      for directory in managedDirectories {
        let path = "\(homePath)/\(directory)"
        var existing = stat()
        if lstat(path, &existing) == 0 { continue }
        guard mkdir(path, 0o700) == 0 else {
          throw BootstrapError.setupFailed(
            "cannot create \(path): \(String(cString: strerror(errno)))")
        }
        guard chown(path, identity.uid, identity.gid) == 0 else {
          throw BootstrapError.setupFailed(
            "cannot chown \(path): \(String(cString: strerror(errno)))")
        }
        created += 1
      }
      return created
    }

    /// Initialize the home directory and everything the bootstrap manages in it.
    @discardableResult
    static func initializeHome(identity: (uid: uid_t, gid: gid_t)) throws -> Int {
      try ensureHomeDirectory(identity: identity)
      return try createMissingManagedDirectories(identity: identity)
    }

    /// What the bootstrap does when the host does not speak the protocol.
    ///
    /// Identical in effect to the behavior that predates it: repair every start.
    private static func legacyRepair(identity: (uid: uid_t, gid: gid_t)) throws {
      let start = Diagnostics.now()
      var visited = 0
      var changed = 0
      var outcome = "success"
      do {
        // The home first, so a profile whose directory does not exist yet gets
        // created rather than failing the walk.
        try initializeHome(identity: identity)
        let stats = try OwnershipWalker.repair(
          root: homePath, uid: identity.uid, gid: identity.gid)
        visited = stats.visited
        changed = stats.changed
      } catch {
        // Best-effort, as before: a profile that cannot be fully repaired should
        // not stop the session outright, but it must be visible.
        outcome = "failure"
        bootstrapLogger.error("Profile ownership repair incomplete: \(error)")
      }
      Diagnostics.record(
        phase: "bootstrap.profile_ownership", startedAt: start, outcome: outcome,
        attributes: [
          ("mode", "legacy"), ("visited", String(visited)), ("changed", String(changed)),
        ])
    }

    // MARK: - Handshake

    static func resolveAgentIdentity() -> (uid: uid_t, gid: gid_t)? {
      guard let pw = getpwnam("agent") else { return nil }
      return (pw.pointee.pw_uid, pw.pointee.pw_gid)
    }

    /// Publish the report, replacing it atomically so the host never reads a
    /// partially written file.
    private static func write(report: Report, to controlDirectory: String) throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(report)
      let finalPath = "\(controlDirectory)/\(Wire.reportFileName)"
      let temporaryPath = "\(finalPath).partial"
      try data.write(to: URL(fileURLWithPath: temporaryPath))
      guard rename(temporaryPath, finalPath) == 0 else {
        throw BootstrapError.setupFailed(
          "cannot publish ownership report: \(String(cString: strerror(errno)))")
      }
    }

    /// Wait, bounded, for the host to release us.
    private static func awaitAcknowledgement(in controlDirectory: String) throws -> String {
      let path = "\(controlDirectory)/\(Wire.ackFileName)"
      let deadline = Diagnostics.now() + Wire.acknowledgementTimeoutSeconds
      while Diagnostics.now() < deadline {
        if access(path, R_OK) == 0,
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let ack = try? JSONDecoder().decode(Acknowledgement.self, from: data)
        {
          guard ack.version == Wire.version else {
            throw BootstrapError.setupFailed(
              "host acknowledgement used protocol version \(ack.version)")
          }
          return ack.decision
        }
        usleep(20_000)
      }
      throw BootstrapError.setupFailed(
        "timed out waiting for the host to acknowledge profile ownership")
    }
  }
#endif
