#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

// MARK: - Protocol constants

/// Names shared verbatim between the host and the in-container bootstrap.
///
/// The bootstrap has no dependencies, so it cannot import this module; it repeats
/// these strings. `ProfileOwnershipProtocolTests` and the bootstrap's own tests
/// pin both sides to the same values.
public enum ProfileOwnershipProtocol {
  /// Bumped when the wire format or the handshake sequence changes. Host and
  /// bootstrap must agree exactly; a mismatch falls back to legacy behavior.
  public static let version = 1

  /// Where the per-session control directory is mounted in the container.
  public static let controlMountPath = "/agent-isolation/control"

  /// Written by the bootstrap once it knows the guest's real identity.
  public static let reportFileName = "ownership-report.json"

  /// Written by the host to release the bootstrap.
  public static let ackFileName = "ownership-ack.json"

  /// Reject anything larger; the guest is not trusted to bound its own message.
  public static let maximumReportBytes = 64 * 1024

  /// How long the host waits for the guest's report before giving up.
  public static let handshakeTimeout = Duration.seconds(120)

  public enum EnvironmentKey {
    public static let protocolVersion = "AGENTC_OWNERSHIP_PROTOCOL"
    public static let controlDirectory = "AGENTC_OWNERSHIP_CONTROL"
    public static let mode = "AGENTC_OWNERSHIP_MODE"
    public static let expectedUID = "AGENTC_OWNERSHIP_EXPECT_UID"
    public static let expectedGID = "AGENTC_OWNERSHIP_EXPECT_GID"
    /// Set to `1` when the runtime's share presents ownership per caller, so the
    /// bootstrap creates what is missing but never attempts a chown. Independent
    /// of the handshake: a bootstrap that does not know it simply repairs.
    public static let presentedByMount = "AGENTC_OWNERSHIP_PRESENTED_BY_MOUNT"
  }
}

/// What the bootstrap is being asked to do with the profile home.
public enum ProfileOwnershipMode: String, Sendable {
  /// A record exists and looks plausible: confirm identity and access without
  /// enumerating the tree.
  case verify
  /// No usable record, or repair was demanded: initialize or migrate.
  case repair
}

/// What the bootstrap did.
public enum ProfileOwnershipStatus: String, Sendable, Codable {
  /// Identity and access checks passed. Nothing was enumerated or changed.
  case verified
  /// A new, empty home was initialized. No tree walk was needed.
  case initialized
  /// An existing home was migrated by a full ownership walk.
  case repaired
  /// Shared-mode checks failed. Nothing was changed and nothing was run.
  case needsRepair = "needs-repair"
  /// Repair was attempted and failed. Nothing may be published.
  case failed
}

// MARK: - Records

/// Identity of a file as the host sees it. Renaming a profile keeps it; restoring
/// a backup in place does not.
public struct ProfileFileIdentity: Codable, Sendable, Equatable {
  public var device: UInt64
  public var inode: UInt64

  public init(device: UInt64, inode: UInt64) {
    self.device = device
    self.inode = inode
  }

  /// Read the identity of an existing directory, or `nil` when it does not exist.
  public static func read(at url: URL) -> ProfileFileIdentity? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return ProfileFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
  }
}

/// How a runtime maps host files into the container, as far as ownership is
/// concerned.
///
/// Two sessions may only share an ownership record when their mappings are
/// identical: the same host file can present completely different ownership
/// through Apple's virtiofs share and through a Docker bind with a user
/// namespace, and a record written under one says nothing about the other.
public struct ProfileOwnershipMapping: Sendable, Equatable {
  /// A stable description of the runtime and its ownership-relevant context —
  /// for Docker that includes the endpoint and user-namespace configuration.
  public var identity: String

  /// Whether this mapping's ownership and access behavior has actually been
  /// characterized on real hardware.
  ///
  /// The fast path stays off for an uncharacterized mapping: a runtime that
  /// silently ignores `chown`, or reports success without changing anything,
  /// would let a record claim a profile is fine when it is not.
  public var isCharacterized: Bool

  /// Whether the share reports each caller as the owner of every file.
  ///
  /// Apple's virtiofs share does: the agent user sees its home as its own, while
  /// root sees a different owner and is refused any chown. There is nothing to
  /// repair and nothing a record could cache, so the session skips both and tells
  /// the bootstrap not to try.
  public var presentsOwnershipPerCaller: Bool

  public init(
    identity: String, isCharacterized: Bool, presentsOwnershipPerCaller: Bool = false
  ) {
    self.identity = identity
    self.isCharacterized = isCharacterized
    self.presentsOwnershipPerCaller = presentsOwnershipPerCaller
  }
}

/// The last known-good ownership state of a profile.
///
/// This is a **cache hint, not a security guarantee**. It records that a
/// successful initialization or migration happened under a given identity and
/// mapping; it cannot detect arbitrary external changes to every descendant.
/// Importing files, changing ownership by hand, or restoring a profile in place
/// still needs an explicit repair.
public struct ProfileOwnershipRecord: Codable, Sendable, Equatable {
  public var recordVersion: Int
  /// Bumped when the set of managed directories or the checks themselves change,
  /// so an old record stops satisfying a newer policy.
  public var policyVersion: Int
  /// Identity of the profile home directory the record was written for.
  public var homeIdentity: ProfileFileIdentity
  /// Incremented on every successful repair, so a record can be told apart from
  /// its predecessor even when nothing else changed.
  public var generation: Int
  public var guestUID: UInt32
  public var guestGID: UInt32
  public var mappingIdentity: String
  public var updatedAt: Date

  public init(
    recordVersion: Int = 1,
    policyVersion: Int,
    homeIdentity: ProfileFileIdentity,
    generation: Int,
    guestUID: UInt32,
    guestGID: UInt32,
    mappingIdentity: String,
    updatedAt: Date = Date()
  ) {
    self.recordVersion = recordVersion
    self.policyVersion = policyVersion
    self.homeIdentity = homeIdentity
    self.generation = generation
    self.guestUID = guestUID
    self.guestGID = guestGID
    self.mappingIdentity = mappingIdentity
    self.updatedAt = updatedAt
  }

  /// Whether this record could plausibly describe the profile in front of us.
  ///
  /// Deliberately weak: it decides only whether a *shared* verification attempt
  /// is worth making. The guest still has to confirm the identity it actually
  /// sees before anything runs.
  public func isPlausible(
    policyVersion: Int, homeIdentity: ProfileFileIdentity?, mappingIdentity: String
  ) -> Bool {
    recordVersion == 1
      && self.policyVersion == policyVersion
      && self.mappingIdentity == mappingIdentity
      && homeIdentity != nil
      && self.homeIdentity == homeIdentity
  }
}

/// What the bootstrap reports back over the control directory.
public struct ProfileOwnershipReport: Codable, Sendable, Equatable {
  public var version: Int
  public var status: ProfileOwnershipStatus
  public var uid: UInt32
  public var gid: UInt32
  /// Entries the bootstrap looked at. Zero on the fast path, by design.
  public var visited: Int
  /// Entries whose ownership it actually changed.
  public var changed: Int
  /// Free-form explanation, only used for diagnostics and error messages.
  public var detail: String?

  public init(
    version: Int = ProfileOwnershipProtocol.version,
    status: ProfileOwnershipStatus,
    uid: UInt32,
    gid: UInt32,
    visited: Int = 0,
    changed: Int = 0,
    detail: String? = nil
  ) {
    self.version = version
    self.status = status
    self.uid = uid
    self.gid = gid
    self.visited = visited
    self.changed = changed
    self.detail = detail
  }
}

/// The host's answer.
public struct ProfileOwnershipAcknowledgement: Codable, Sendable, Equatable {
  public enum Decision: String, Codable, Sendable {
    /// Preparation scripts and the workload may start.
    case `continue`
    /// Stop here; the host is taking over.
    case abort
  }

  public var version: Int
  public var decision: Decision

  public init(version: Int = ProfileOwnershipProtocol.version, decision: Decision) {
    self.version = version
    self.decision = decision
  }
}

// MARK: - Errors

public enum ProfileOwnershipError: Error, CustomStringConvertible, Equatable {
  /// Another session is using the profile and repair cannot proceed.
  case profileBusy(String)
  /// The guest never reported within the bounded wait.
  case handshakeTimedOut
  /// The guest's report was missing, oversized, or not decodable.
  case malformedReport(String)
  /// The guest attempted a repair and failed.
  case repairFailed(String)
  /// Verification failed twice; the profile still is not usable.
  case stillNeedsRepair

  public var description: String {
    switch self {
    case .profileBusy(let detail):
      return
        "the profile is in use by another agentc session, so its ownership cannot be "
        + "repaired right now (\(detail)). Exit other sessions using this profile and retry."
    case .handshakeTimedOut:
      return "timed out waiting for the container to report its profile ownership state"
    case .malformedReport(let detail):
      return "the container's profile ownership report was unusable: \(detail)"
    case .repairFailed(let detail):
      return "repairing profile ownership failed: \(detail)"
    case .stillNeedsRepair:
      return
        "profile ownership could not be established even after a repair pass; "
        + "run `agentc sh --repair-profile-ownership -- true` and check the reported detail"
    }
  }
}

// MARK: - Coordinator

/// Owns the host side of profile-ownership lifecycle rules, so library callers and
/// the CLI behave identically.
///
/// Ordinary sessions take a **shared** lease on the profile for their whole
/// container lifetime; repair needs an **exclusive** one. The lock lives beside
/// the record, outside the home the guest can write to, and is keyed to the
/// profile's canonical path.
///
/// The leases here cover participating agentc sessions only. A container started
/// by hand against the same profile directory, or by a build of agentc that
/// predates this protocol, takes no lease and is invisible to it.
public final class ProfileOwnershipCoordinator: Sendable {
  /// Bumped when the managed-directory set or the guest-side checks change.
  public static let policyVersion = 1

  private let profileDirectory: URL
  private let homeDirectory: URL
  private let mapping: ProfileOwnershipMapping

  public init(profileDirectory: URL, homeDirectory: URL, mapping: ProfileOwnershipMapping) {
    self.profileDirectory = profileDirectory
    self.homeDirectory = homeDirectory
    self.mapping = mapping
  }

  var stateDirectory: URL { profileDirectory.appendingPathComponent("state") }
  var recordURL: URL { stateDirectory.appendingPathComponent("ownership-v1.json") }
  var leaseURL: URL { stateDirectory.appendingPathComponent("ownership.lock") }
  /// A separate short-lived gate, so two sessions cannot convert their leases at
  /// the same moment and race each other into the shared state.
  var gateURL: URL { stateDirectory.appendingPathComponent("ownership-gate.lock") }

  // MARK: Record storage

  public func loadRecord() -> ProfileOwnershipRecord? {
    guard let data = try? Data(contentsOf: recordURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(ProfileOwnershipRecord.self, from: data)
  }

  /// Publish a record atomically. Only ever called after a successful
  /// initialization or repair — never after a failure.
  public func publish(_ record: ProfileOwnershipRecord) throws {
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: recordURL, options: .atomic)
  }

  /// Drop the record, forcing the next session through a migration.
  public func discardRecord() {
    try? FileManager.default.removeItem(at: recordURL)
  }

  // MARK: Lease

  /// Decide from host metadata alone whether a shared verification is worth
  /// attempting, or whether this session has to migrate.
  ///
  /// A missing or stale record, a changed guest identity, a changed mapping, or an
  /// explicit repair request all require exclusive access. Nothing here trusts the
  /// record's *contents* — only its plausibility.
  public func plannedMode(forceRepair: Bool) -> ProfileOwnershipMode {
    guard !forceRepair else { return .repair }
    guard let record = loadRecord() else { return .repair }
    let identity = ProfileFileIdentity.read(at: homeDirectory)
    return record.isPlausible(
      policyVersion: Self.policyVersion,
      homeIdentity: identity,
      mappingIdentity: mapping.identity)
      ? .verify : .repair
  }

  /// How long a repair lease keeps probing before it declares the profile busy.
  ///
  /// `flock` belongs to the open file description rather than the process, so a
  /// child this session spawned holds an inherited copy of every descriptor — the
  /// shared lease among them — until it execs. Probing once turns that
  /// sub-millisecond window into "the profile is in use by another agentc
  /// session", advice the user cannot act on because the session it names is their
  /// own. A window this short rides it out and still fails fast on a profile
  /// somebody else really is holding.
  static let repairLeaseWindow: TimeInterval = 1
  static let repairLeaseInterval: useconds_t = 20_000

  /// Take the lease for `mode`.
  ///
  /// Repair takes the lock exclusively and refuses rather than waiting: holding a
  /// live session's profile hostage, or changing ownership underneath it, are both
  /// worse than telling the user which sessions to close.
  public func acquireLease(for mode: ProfileOwnershipMode) throws -> FileLock {
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true)
    switch mode {
    case .verify:
      return try FileLock.acquire(at: leaseURL, mode: .shared)
    case .repair:
      let deadline = Date().addingTimeInterval(Self.repairLeaseWindow)
      while true {
        if let lock = try FileLock.tryAcquire(at: leaseURL, mode: .exclusive) { return lock }
        guard Date() < deadline else {
          throw ProfileOwnershipError.profileBusy(profileDirectory.lastPathComponent)
        }
        usleep(Self.repairLeaseInterval)
      }
    }
  }

  /// Downgrade a repair lease to the shared lease held for the rest of the
  /// session, serialized against other conversions.
  public func convertToSharedLease(_ lease: FileLock) throws {
    let gate = try FileLock.acquire(at: gateURL, mode: .exclusive)
    defer { gate.release() }
    try lease.convert(to: .shared)
  }

  // MARK: Surviving sessions

  /// Where running sessions leave a note naming their container.
  var sessionsDirectory: URL { stateDirectory.appendingPathComponent("sessions") }

  /// Record that `containerID` is using this profile.
  ///
  /// The lease alone is not enough: it lives in a process, and a crashed agentc
  /// releases it while its container may still be running with the profile
  /// mounted. These notes outlive the process.
  public func registerSession(containerID: String) {
    guard let name = Self.sessionFileName(for: containerID) else { return }
    try? FileManager.default.createDirectory(
      at: sessionsDirectory, withIntermediateDirectories: true)
    try? Data(containerID.utf8).write(
      to: sessionsDirectory.appendingPathComponent(name), options: .atomic)
  }

  public func unregisterSession(containerID: String) {
    guard let name = Self.sessionFileName(for: containerID) else { return }
    try? FileManager.default.removeItem(at: sessionsDirectory.appendingPathComponent(name))
  }

  /// Container IDs recorded as using this profile, whether or not they still exist.
  public func registeredSessionIDs() -> [String] {
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: sessionsDirectory, includingPropertiesForKeys: nil)) ?? []
    return entries.compactMap { url in
      guard let data = try? Data(contentsOf: url), data.count <= 4096 else { return nil }
      let id = String(decoding: data, as: UTF8.self)
      return id.isEmpty ? nil : id
    }
  }

  /// Refuse to repair while a container recorded against this profile is still
  /// registered with the runtime.
  ///
  /// `liveContainerIDs` is `nil` when the runtime cannot enumerate. In that case a
  /// leftover note is not dismissed as stale — it is reported, with the file to
  /// delete — because a released process lock is not proof the profile is idle.
  public func assertNoSurvivingSessions(liveContainerIDs: Set<String>?) throws {
    let registered = registeredSessionIDs()
    guard !registered.isEmpty else { return }

    guard let liveContainerIDs else {
      throw ProfileOwnershipError.profileBusy(
        "cannot tell whether \(registered.count) recorded session(s) are still running; "
          + "if none are, delete \(sessionsDirectory.path)")
    }

    var surviving: [String] = []
    for id in registered {
      if liveContainerIDs.contains(id) {
        surviving.append(id)
      } else {
        // The runtime says it is gone, so the note is genuinely stale.
        unregisterSession(containerID: id)
      }
    }
    guard surviving.isEmpty else {
      throw ProfileOwnershipError.profileBusy(
        "container(s) \(surviving.joined(separator: ", ")) are still using it")
    }
  }

  /// Reject anything that could escape the sessions directory. Container IDs come
  /// from a runtime, not from us.
  static func sessionFileName(for containerID: String) -> String? {
    guard !containerID.isEmpty, containerID.count <= 128 else { return nil }
    let allowed = containerID.allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
    }
    return allowed ? "\(containerID).id" : nil
  }

  // MARK: Guest environment

  /// Controls passed into the container for this session.
  ///
  /// Only this session's expected ownership data crosses the boundary — never the
  /// host state directory, and never its lock.
  public func guestEnvironment(mode: ProfileOwnershipMode) -> [String: String] {
    var environment: [String: String] = [
      ProfileOwnershipProtocol.EnvironmentKey.protocolVersion:
        String(ProfileOwnershipProtocol.version),
      ProfileOwnershipProtocol.EnvironmentKey.controlDirectory:
        ProfileOwnershipProtocol.controlMountPath,
      ProfileOwnershipProtocol.EnvironmentKey.mode: mode.rawValue,
    ]
    if mode == .verify, let record = loadRecord() {
      environment[ProfileOwnershipProtocol.EnvironmentKey.expectedUID] = String(record.guestUID)
      environment[ProfileOwnershipProtocol.EnvironmentKey.expectedGID] = String(record.guestGID)
    }
    return environment
  }

  // MARK: Handshake

  /// Wait for the guest's report, bounded and cancellable.
  public func awaitReport(
    controlDirectory: URL,
    timeout: Duration = ProfileOwnershipProtocol.handshakeTimeout,
    isContainerAlive: () async -> Bool = { true }
  ) async throws -> ProfileOwnershipReport {
    let reportURL = controlDirectory.appendingPathComponent(
      ProfileOwnershipProtocol.reportFileName)
    let deadline = ContinuousClock.now.advanced(by: timeout)

    while ContinuousClock.now < deadline {
      if FileManager.default.fileExists(atPath: reportURL.path) {
        return try Self.decodeReport(at: reportURL)
      }
      if await !isContainerAlive() {
        throw ProfileOwnershipError.malformedReport("the container exited before reporting")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw ProfileOwnershipError.handshakeTimedOut
  }

  /// Decode a report, refusing anything oversized or malformed.
  ///
  /// The report comes from inside the container, so its size and shape are
  /// checked before it is parsed.
  static func decodeReport(at url: URL) throws -> ProfileOwnershipReport {
    var info = stat()
    guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      throw ProfileOwnershipError.malformedReport("not a regular file")
    }
    guard info.st_size <= ProfileOwnershipProtocol.maximumReportBytes else {
      throw ProfileOwnershipError.malformedReport("report is \(info.st_size) bytes")
    }
    guard let data = try? Data(contentsOf: url) else {
      throw ProfileOwnershipError.malformedReport("unreadable")
    }
    guard let report = try? JSONDecoder().decode(ProfileOwnershipReport.self, from: data) else {
      throw ProfileOwnershipError.malformedReport("undecodable")
    }
    guard report.version == ProfileOwnershipProtocol.version else {
      throw ProfileOwnershipError.malformedReport("protocol version \(report.version)")
    }
    return report
  }

  /// Release the guest so it can run preparation scripts and the workload.
  public func acknowledge(
    controlDirectory: URL, decision: ProfileOwnershipAcknowledgement.Decision
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(ProfileOwnershipAcknowledgement(decision: decision))
    try data.write(
      to: controlDirectory.appendingPathComponent(ProfileOwnershipProtocol.ackFileName),
      options: .atomic)
  }

  /// Build the record for a successful initialization or repair.
  public func makeRecord(from report: ProfileOwnershipReport) -> ProfileOwnershipRecord? {
    guard let identity = ProfileFileIdentity.read(at: homeDirectory) else { return nil }
    let generation = (loadRecord()?.generation ?? 0) + 1
    return ProfileOwnershipRecord(
      policyVersion: Self.policyVersion,
      homeIdentity: identity,
      generation: generation,
      guestUID: report.uid,
      guestGID: report.gid,
      mappingIdentity: mapping.identity)
  }
}
