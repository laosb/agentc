import Foundation
import Testing

@testable import AgentIsolation

// MARK: - Fixtures

/// A throwaway profile directory laid out the way agentc does.
private final class TempProfile: Sendable {
  let root: URL
  var home: URL { root.appendingPathComponent("home") }

  init() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ownership-tests-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }
}

private func makeCoordinator(
  _ profile: TempProfile, mappingIdentity: String = "mock"
) -> ProfileOwnershipCoordinator {
  ProfileOwnershipCoordinator(
    profileDirectory: profile.root,
    homeDirectory: profile.home,
    mapping: ProfileOwnershipMapping(identity: mappingIdentity, isCharacterized: true))
}

private func makeRecord(
  _ profile: TempProfile,
  policyVersion: Int = ProfileOwnershipCoordinator.policyVersion,
  mappingIdentity: String = "mock",
  uid: UInt32 = 1000,
  gid: UInt32 = 1000
) -> ProfileOwnershipRecord {
  ProfileOwnershipRecord(
    policyVersion: policyVersion,
    homeIdentity: ProfileFileIdentity.read(at: profile.home)!,
    generation: 1,
    guestUID: uid,
    guestGID: gid,
    mappingIdentity: mappingIdentity)
}

// MARK: - Record

@Suite("Profile ownership record")
struct ProfileOwnershipRecordTests {

  @Test("A record round-trips through the state file")
  func roundTrip() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    let record = makeRecord(profile)
    try coordinator.publish(record)

    let loaded = coordinator.loadRecord()
    #expect(loaded?.guestUID == record.guestUID)
    #expect(loaded?.homeIdentity == record.homeIdentity)
    #expect(loaded?.mappingIdentity == "mock")
  }

  @Test("The record lives outside the mounted home")
  func recordIsOutsideHome() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    try coordinator.publish(makeRecord(profile))
    // The guest can write anywhere under `home`; the record and its lock must not
    // be reachable from there.
    #expect(!coordinator.recordURL.path.hasPrefix(profile.home.path + "/"))
    #expect(!coordinator.leaseURL.path.hasPrefix(profile.home.path + "/"))
    #expect(coordinator.recordURL.lastPathComponent == "ownership-v1.json")
  }

  @Test("Plausibility requires the policy version, mapping, and home identity to match")
  func plausibility() throws {
    let profile = try TempProfile()
    let identity = ProfileFileIdentity.read(at: profile.home)!
    let record = makeRecord(profile)

    #expect(
      record.isPlausible(
        policyVersion: ProfileOwnershipCoordinator.policyVersion,
        homeIdentity: identity, mappingIdentity: "mock"))
    #expect(
      !record.isPlausible(
        policyVersion: ProfileOwnershipCoordinator.policyVersion + 1,
        homeIdentity: identity, mappingIdentity: "mock"))
    #expect(
      !record.isPlausible(
        policyVersion: ProfileOwnershipCoordinator.policyVersion,
        homeIdentity: identity, mappingIdentity: "other"))
    #expect(
      !record.isPlausible(
        policyVersion: ProfileOwnershipCoordinator.policyVersion,
        homeIdentity: nil, mappingIdentity: "mock"))
    #expect(
      !record.isPlausible(
        policyVersion: ProfileOwnershipCoordinator.policyVersion,
        homeIdentity: ProfileFileIdentity(device: 1, inode: 2), mappingIdentity: "mock"))
  }

  @Test("Each published record advances the generation")
  func generationAdvances() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    let first = coordinator.makeRecord(
      from: ProfileOwnershipReport(status: .repaired, uid: 1000, gid: 1000))
    try coordinator.publish(#require(first))
    let second = coordinator.makeRecord(
      from: ProfileOwnershipReport(status: .repaired, uid: 1000, gid: 1000))
    #expect(first?.generation == 1)
    #expect(second?.generation == 2)
  }
}

// MARK: - Mode selection

@Suite("Profile ownership mode selection")
struct ProfileOwnershipModeTests {

  @Test("No record means migration")
  func noRecordMigrates() throws {
    let profile = try TempProfile()
    #expect(makeCoordinator(profile).plannedMode(forceRepair: false) == .repair)
  }

  @Test("A plausible record allows shared verification")
  func plausibleRecordVerifies() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    try coordinator.publish(makeRecord(profile))
    #expect(coordinator.plannedMode(forceRepair: false) == .verify)
  }

  @Test("An explicit repair request always migrates")
  func forceRepairMigrates() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    try coordinator.publish(makeRecord(profile))
    #expect(coordinator.plannedMode(forceRepair: true) == .repair)
  }

  @Test("Switching runtimes migrates rather than reusing the record")
  func runtimeSwitchMigrates() throws {
    let profile = try TempProfile()
    try makeCoordinator(profile, mappingIdentity: "apple").publish(
      makeRecord(profile, mappingIdentity: "apple"))
    #expect(
      makeCoordinator(profile, mappingIdentity: "docker").plannedMode(forceRepair: false)
        == .repair)
  }

  @Test("A policy version bump migrates")
  func policyBumpMigrates() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    try coordinator.publish(
      makeRecord(profile, policyVersion: ProfileOwnershipCoordinator.policyVersion - 1))
    #expect(coordinator.plannedMode(forceRepair: false) == .repair)
  }

  @Test("Replacing the home directory in place migrates")
  func replacedHomeMigrates() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    try coordinator.publish(makeRecord(profile))

    // A restored backup: same path, different inode. The record can no longer
    // vouch for it.
    let replacement = profile.root.appendingPathComponent("restored")
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: profile.home)
    try FileManager.default.moveItem(at: replacement, to: profile.home)

    #expect(coordinator.plannedMode(forceRepair: false) == .repair)
  }

  @Test("A corrupt record migrates rather than throwing")
  func corruptRecordMigrates() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    try FileManager.default.createDirectory(
      at: coordinator.stateDirectory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: coordinator.recordURL)
    #expect(coordinator.loadRecord() == nil)
    #expect(coordinator.plannedMode(forceRepair: false) == .repair)
  }
}

// MARK: - Leases

@Suite("Profile ownership leases")
struct ProfileOwnershipLeaseTests {

  @Test("Two verifying sessions can hold the profile at once")
  func sharedLeasesCoexist() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    let first = try coordinator.acquireLease(for: .verify)
    let second = try coordinator.acquireLease(for: .verify)
    first.release()
    second.release()
  }

  @Test("Repair refuses while another session holds the profile")
  func repairRefusesWhileBusy() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    let live = try coordinator.acquireLease(for: .verify)
    defer { live.release() }

    #expect(throws: ProfileOwnershipError.self) {
      _ = try coordinator.acquireLease(for: .repair)
    }
  }

  @Test("Repair rides out a holder that is on its way out")
  func repairWaitsOutADepartingHolder() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    // Stands in for a child that inherited this session's shared lease and has not
    // reached its exec yet: the lease is genuinely held, but only for a moment, and
    // no user could act on being told to exit the session holding it.
    let departing = try coordinator.acquireLease(for: .verify)
    // A detached thread rather than a `Task`: the probe loop blocks its thread, so
    // a cooperative-pool release could be waiting behind the very loop it unblocks.
    Thread.detachNewThread {
      Thread.sleep(forTimeInterval: 0.1)
      departing.release()
    }

    let lease = try coordinator.acquireLease(for: .repair)
    lease.release()
  }

  @Test("The busy error names the profile and says what to do")
  func busyErrorIsActionable() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    let live = try coordinator.acquireLease(for: .verify)
    defer { live.release() }

    do {
      _ = try coordinator.acquireLease(for: .repair)
      Issue.record("expected the repair lease to be refused")
    } catch let error as ProfileOwnershipError {
      #expect(error.description.contains(profile.root.lastPathComponent))
      #expect(error.description.contains("Exit other sessions"))
    }
  }

  @Test("A repair lease excludes everything until it is released")
  func repairLeaseIsExclusive() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    let repair = try coordinator.acquireLease(for: .repair)
    #expect(try FileLock.tryAcquire(at: coordinator.leaseURL, mode: .shared) == nil)
    repair.release()
    let after = try FileLock.tryAcquire(at: coordinator.leaseURL, mode: .shared)
    #expect(after != nil)
    after?.release()
  }

  @Test("Converting a repair lease to shared admits other sessions")
  func conversionAdmitsOthers() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    let lease = try coordinator.acquireLease(for: .repair)
    defer { lease.release() }
    #expect(try FileLock.tryAcquire(at: coordinator.leaseURL, mode: .shared) == nil)

    try coordinator.convertToSharedLease(lease)
    let other = try FileLock.tryAcquire(at: coordinator.leaseURL, mode: .shared)
    #expect(other != nil)
    other?.release()
  }
}

// MARK: - Handshake

@Suite("Profile ownership handshake")
struct ProfileOwnershipHandshakeTests {

  private func controlDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ownership-control-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("Verify mode passes the recorded identity, and repair mode does not")
  func guestEnvironment() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    try coordinator.publish(makeRecord(profile, uid: 501, gid: 20))

    let verify = coordinator.guestEnvironment(mode: .verify)
    #expect(verify[ProfileOwnershipProtocol.EnvironmentKey.mode] == "verify")
    #expect(verify[ProfileOwnershipProtocol.EnvironmentKey.expectedUID] == "501")
    #expect(verify[ProfileOwnershipProtocol.EnvironmentKey.expectedGID] == "20")
    #expect(
      verify[ProfileOwnershipProtocol.EnvironmentKey.controlDirectory]
        == ProfileOwnershipProtocol.controlMountPath)

    // Nothing to verify against during a migration, and nothing to leak.
    let repair = coordinator.guestEnvironment(mode: .repair)
    #expect(repair[ProfileOwnershipProtocol.EnvironmentKey.expectedUID] == nil)
    #expect(repair[ProfileOwnershipProtocol.EnvironmentKey.expectedGID] == nil)
  }

  @Test("The guest environment never carries the host state directory")
  func environmentLeaksNothing() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    try coordinator.publish(makeRecord(profile))
    for value in coordinator.guestEnvironment(mode: .verify).values {
      #expect(!value.contains(coordinator.stateDirectory.path))
      #expect(!value.contains(profile.root.path))
    }
  }

  @Test("A well-formed report is read back")
  func readsReport() async throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    let control = try controlDirectory()
    defer { try? FileManager.default.removeItem(at: control) }

    let report = ProfileOwnershipReport(
      status: .repaired, uid: 1000, gid: 1000, visited: 12, changed: 3)
    let encoder = JSONEncoder()
    try encoder.encode(report).write(
      to: control.appendingPathComponent(ProfileOwnershipProtocol.reportFileName))

    let read = try await coordinator.awaitReport(controlDirectory: control)
    #expect(read == report)
  }

  @Test("Waiting for a report is bounded")
  func waitIsBounded() async throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    let control = try controlDirectory()
    defer { try? FileManager.default.removeItem(at: control) }

    await #expect(throws: ProfileOwnershipError.handshakeTimedOut) {
      _ = try await coordinator.awaitReport(
        controlDirectory: control, timeout: .milliseconds(80))
    }
  }

  @Test("An oversized report is rejected without being parsed")
  func rejectsOversizedReport() throws {
    let control = try controlDirectory()
    defer { try? FileManager.default.removeItem(at: control) }
    let url = control.appendingPathComponent(ProfileOwnershipProtocol.reportFileName)
    try Data(
      repeating: 0x20, count: ProfileOwnershipProtocol.maximumReportBytes + 1
    ).write(to: url)

    #expect(throws: ProfileOwnershipError.self) {
      _ = try ProfileOwnershipCoordinator.decodeReport(at: url)
    }
  }

  @Test("A malformed report is rejected")
  func rejectsMalformedReport() throws {
    let control = try controlDirectory()
    defer { try? FileManager.default.removeItem(at: control) }
    let url = control.appendingPathComponent(ProfileOwnershipProtocol.reportFileName)
    try Data("{ not json".utf8).write(to: url)

    #expect(throws: ProfileOwnershipError.self) {
      _ = try ProfileOwnershipCoordinator.decodeReport(at: url)
    }
  }

  @Test("A report from a different protocol version is rejected")
  func rejectsWrongProtocolVersion() throws {
    let control = try controlDirectory()
    defer { try? FileManager.default.removeItem(at: control) }
    let url = control.appendingPathComponent(ProfileOwnershipProtocol.reportFileName)
    var report = ProfileOwnershipReport(status: .verified, uid: 0, gid: 0)
    report.version = ProfileOwnershipProtocol.version + 1
    try JSONEncoder().encode(report).write(to: url)

    #expect(throws: ProfileOwnershipError.self) {
      _ = try ProfileOwnershipCoordinator.decodeReport(at: url)
    }
  }

  @Test("A symlinked report is rejected rather than followed")
  func rejectsSymlinkedReport() throws {
    let control = try controlDirectory()
    defer { try? FileManager.default.removeItem(at: control) }
    let elsewhere = control.appendingPathComponent("elsewhere.json")
    try JSONEncoder().encode(ProfileOwnershipReport(status: .verified, uid: 0, gid: 0))
      .write(to: elsewhere)
    let url = control.appendingPathComponent(ProfileOwnershipProtocol.reportFileName)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: elsewhere)

    #expect(throws: ProfileOwnershipError.self) {
      _ = try ProfileOwnershipCoordinator.decodeReport(at: url)
    }
  }

  @Test("Acknowledgements are written where the guest looks for them")
  func writesAcknowledgement() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    let control = try controlDirectory()
    defer { try? FileManager.default.removeItem(at: control) }

    try coordinator.acknowledge(controlDirectory: control, decision: .continue)
    let data = try Data(
      contentsOf: control.appendingPathComponent(ProfileOwnershipProtocol.ackFileName))
    let ack = try JSONDecoder().decode(ProfileOwnershipAcknowledgement.self, from: data)
    #expect(ack.decision == .continue)
    #expect(ack.version == ProfileOwnershipProtocol.version)
  }
}

// MARK: - Session integration

@Suite("AgentSession profile ownership")
struct AgentSessionProfileOwnershipTests {

  private func makeConfig(
    _ profile: TempProfile,
    capabilities: BootstrapCapabilities = [.profileOwnershipHandshake],
    repair: Bool = false,
    optIn: Bool = false
  ) -> IsolationConfig {
    IsolationConfig(
      image: "test:latest",
      profileHomeDir: profile.home,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      arguments: ["true"],
      bootstrapCapabilities: capabilities,
      repairProfileOwnership: repair,
      profileOwnershipFastPathOptIn: optIn)
  }

  @Test("An initialized profile publishes a record and releases the guest")
  func initializePublishesRecord() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.scriptedReports = [
      ProfileOwnershipReport(status: .initialized, uid: 1000, gid: 1000, visited: 4, changed: 4)
    ]

    let session = AgentSession(config: makeConfig(profile), runtime: runtime)
    try await session.start()

    let coordinator = makeCoordinator(profile)
    let record = coordinator.loadRecord()
    #expect(record?.guestUID == 1000)
    #expect(record?.generation == 1)

    // The guest was told it may proceed.
    let control = try #require(runtime.controlDirectories.first)
    let ack = try JSONDecoder().decode(
      ProfileOwnershipAcknowledgement.self,
      from: Data(
        contentsOf: control.appendingPathComponent(ProfileOwnershipProtocol.ackFileName)))
    #expect(ack.decision == .continue)

    _ = try await session.wait()
  }

  @Test("A verified profile does not rewrite the record and visits nothing")
  func verifyKeepsRecord() async throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    try coordinator.publish(makeRecord(profile))

    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.scriptedReports = [
      ProfileOwnershipReport(status: .verified, uid: 1000, gid: 1000, visited: 0, changed: 0)
    ]

    let session = AgentSession(config: makeConfig(profile), runtime: runtime)
    try await session.start()

    #expect(runtime.launches == 1)
    #expect(coordinator.loadRecord()?.generation == 1)
    #expect(
      runtime.environments[0][ProfileOwnershipProtocol.EnvironmentKey.mode] == "verify")
    _ = try await session.wait()
  }

  @Test("A needs-repair report restarts once under an exclusive lease")
  func needsRepairRestartsOnce() async throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    try coordinator.publish(makeRecord(profile))

    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.scriptedReports = [
      ProfileOwnershipReport(
        status: .needsRepair, uid: 501, gid: 20, detail: "guest identity is 501:20"),
      ProfileOwnershipReport(status: .repaired, uid: 501, gid: 20, visited: 30, changed: 12),
    ]

    let session = AgentSession(config: makeConfig(profile), runtime: runtime)
    try await session.start()

    #expect(runtime.launches == 2)
    #expect(runtime.environments[0][ProfileOwnershipProtocol.EnvironmentKey.mode] == "verify")
    #expect(runtime.environments[1][ProfileOwnershipProtocol.EnvironmentKey.mode] == "repair")
    // The first container was torn down rather than left running.
    #expect(runtime.removedContainers == ["mock-container-0"])
    // The record now reflects the identity the guest actually reported.
    #expect(coordinator.loadRecord()?.guestUID == 501)
    _ = try await session.wait()
  }

  @Test("A profile that still needs repair after a repair pass fails")
  func repeatedNeedsRepairFails() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.scriptedReports = [
      ProfileOwnershipReport(status: .needsRepair, uid: 0, gid: 0),
      ProfileOwnershipReport(status: .needsRepair, uid: 0, gid: 0),
    ]

    let session = AgentSession(config: makeConfig(profile), runtime: runtime)
    await #expect(throws: ProfileOwnershipError.stillNeedsRepair) {
      try await session.start()
    }
    #expect(runtime.removedContainers.count == runtime.launches)
  }

  @Test("A failed repair surfaces the guest's detail and publishes nothing")
  func failedRepairPublishesNothing() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.scriptedReports = [
      ProfileOwnershipReport(
        status: .failed, uid: 1000, gid: 1000,
        detail: "chown /home/agent/x: Operation not permitted")
    ]

    let session = AgentSession(config: makeConfig(profile), runtime: runtime)
    await #expect(throws: ProfileOwnershipError.self) {
      try await session.start()
    }
    #expect(makeCoordinator(profile).loadRecord() == nil)
  }

  @Test("An explicit repair request migrates even with a valid record")
  func explicitRepairMigrates() async throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    try coordinator.publish(makeRecord(profile))

    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.scriptedReports = [
      ProfileOwnershipReport(status: .repaired, uid: 1000, gid: 1000, visited: 9, changed: 2)
    ]

    let session = AgentSession(
      config: makeConfig(profile, repair: true), runtime: runtime)
    try await session.start()
    #expect(runtime.environments[0][ProfileOwnershipProtocol.EnvironmentKey.mode] == "repair")
    #expect(coordinator.loadRecord()?.generation == 2)
    _ = try await session.wait()
  }

  @Test("A repair cannot start while another session holds the profile")
  func repairBlockedByLiveSession() async throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    let live = try coordinator.acquireLease(for: .verify)
    defer { live.release() }

    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    let session = AgentSession(
      config: makeConfig(profile, repair: true), runtime: runtime)
    await #expect(throws: ProfileOwnershipError.self) {
      try await session.start()
    }
    // Nothing was launched: the profile was never touched.
    #expect(runtime.launches == 0)
  }

  @Test("The session's lease is released only after teardown")
  func leaseHeldForContainerLifetime() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.scriptedReports = [
      ProfileOwnershipReport(status: .initialized, uid: 1000, gid: 1000)
    ]

    let session = AgentSession(config: makeConfig(profile), runtime: runtime)
    try await session.start()

    let coordinator = makeCoordinator(profile)
    #expect(try FileLock.tryAcquire(at: coordinator.leaseURL, mode: .exclusive) == nil)

    _ = try await session.wait()
    // Retried rather than sampled once. Teardown has closed this process's copy of
    // the lease, but the `flock` lives on the open file description, and any child
    // another test in this process spawned moments ago holds inherited copies of
    // every descriptor until it execs. What is being asserted is that teardown
    // releases the lease, not that no unrelated process is mid-spawn.
    var after: FileLock?
    for _ in 0..<50 {
      after = try FileLock.tryAcquire(at: coordinator.leaseURL, mode: .exclusive)
      if after != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(after != nil)
    after?.release()
  }

  @Test("A bootstrap that does not declare the handshake is never made to wait")
  func noCapabilityMeansNoHandshake() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    // No scripted report: if the session waited for one, it would time out.
    let session = AgentSession(
      config: makeConfig(profile, capabilities: []), runtime: runtime)
    try await session.start()

    #expect(runtime.launches == 1)
    #expect(runtime.controlDirectories.isEmpty)
    #expect(
      runtime.environments[0][ProfileOwnershipProtocol.EnvironmentKey.protocolVersion] == nil)
    _ = try await session.wait()
  }

  @Test("An uncharacterized runtime mapping keeps the legacy path")
  func uncharacterizedMappingMeansNoHandshake() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.mapping = ProfileOwnershipMapping(identity: "mock", isCharacterized: false)

    let session = AgentSession(config: makeConfig(profile), runtime: runtime)
    try await session.start()

    #expect(runtime.controlDirectories.isEmpty)
    #expect(makeCoordinator(profile).loadRecord() == nil)
    _ = try await session.wait()
  }

  @Test("Opting in enables the handshake on an uncharacterized mapping")
  func optInEnablesHandshake() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.mapping = ProfileOwnershipMapping(identity: "mock", isCharacterized: false)
    runtime.scriptedReports = [
      ProfileOwnershipReport(status: .initialized, uid: 1000, gid: 1000)
    ]

    let session = AgentSession(
      config: makeConfig(profile, optIn: true), runtime: runtime)
    try await session.start()

    #expect(runtime.controlDirectories.count == 1)
    _ = try await session.wait()
  }

  @Test("A runtime with no mapping at all keeps the legacy path")
  func noMappingMeansNoHandshake() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.mapping = nil

    let session = AgentSession(config: makeConfig(profile, optIn: true), runtime: runtime)
    try await session.start()
    #expect(runtime.controlDirectories.isEmpty)
    _ = try await session.wait()
  }

  @Test("A mapping that presents ownership per caller tells the bootstrap not to repair")
  func presentedByMountSkipsRepair() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.mapping = ProfileOwnershipMapping(
      identity: "mock", isCharacterized: true, presentsOwnershipPerCaller: true)

    // Even with the handshake available and opted into: there is nothing to verify.
    let session = AgentSession(config: makeConfig(profile, optIn: true), runtime: runtime)
    try await session.start()

    #expect(runtime.launches == 1)
    #expect(runtime.controlDirectories.isEmpty)
    #expect(makeCoordinator(profile).loadRecord() == nil)
    let environment = try #require(runtime.environments.first)
    #expect(environment[ProfileOwnershipProtocol.EnvironmentKey.presentedByMount] == "1")
    #expect(environment[ProfileOwnershipProtocol.EnvironmentKey.protocolVersion] == nil)
    _ = try await session.wait()
  }

  @Test("An explicit repair request overrides a mount that presents ownership")
  func explicitRepairIgnoresPresentedByMount() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.mapping = ProfileOwnershipMapping(
      identity: "mock", isCharacterized: true, presentsOwnershipPerCaller: true)
    runtime.scriptedReports = [
      ProfileOwnershipReport(status: .repaired, uid: 1000, gid: 1000)
    ]

    let session = AgentSession(config: makeConfig(profile, repair: true), runtime: runtime)
    try await session.start()

    let environment = try #require(runtime.environments.first)
    #expect(environment[ProfileOwnershipProtocol.EnvironmentKey.presentedByMount] == nil)
    #expect(environment[ProfileOwnershipProtocol.EnvironmentKey.mode] == "repair")
    _ = try await session.wait()
  }

  @Test("Other mappings never send the presented-by-mount hint")
  func noHintByDefault() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.mapping = ProfileOwnershipMapping(identity: "mock", isCharacterized: false)

    let session = AgentSession(config: makeConfig(profile), runtime: runtime)
    try await session.start()

    let environment = try #require(runtime.environments.first)
    #expect(environment[ProfileOwnershipProtocol.EnvironmentKey.presentedByMount] == nil)
    _ = try await session.wait()
  }

  @Test("A caller cannot forge the presented-by-mount hint")
  func hintCannotBeForged() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.mapping = ProfileOwnershipMapping(identity: "mock", isCharacterized: false)

    var config = makeConfig(profile)
    config.environment[ProfileOwnershipProtocol.EnvironmentKey.presentedByMount] = "1"
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()

    let environment = try #require(runtime.environments.first)
    #expect(environment[ProfileOwnershipProtocol.EnvironmentKey.presentedByMount] == nil)
    _ = try await session.wait()
  }

  @Test("The control directory is mounted read-write at the reserved destination")
  func controlMountDestination() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.scriptedReports = [
      ProfileOwnershipReport(status: .initialized, uid: 1000, gid: 1000)
    ]

    let session = AgentSession(config: makeConfig(profile), runtime: runtime)
    try await session.start()
    _ = try await session.wait()

    #expect(
      AgentIsolationPathUtils.isReservedHostMountDestination(
        ProfileOwnershipProtocol.controlMountPath))
  }

  @Test("The control directory is removed with the rest of the session")
  func controlDirectoryIsCleanedUp() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.scriptedReports = [
      ProfileOwnershipReport(status: .initialized, uid: 1000, gid: 1000)
    ]

    let session = AgentSession(config: makeConfig(profile), runtime: runtime)
    try await session.start()
    let control = try #require(runtime.controlDirectories.first)
    _ = try await session.wait()

    #expect(!FileManager.default.fileExists(atPath: control.path))
  }
}

// MARK: - Wire format

/// The bootstrap is a dependency-free executable and cannot import `AgentIsolation`,
/// so it repeats these values as literals in
/// `Sources/agentc-bootstrap/ProfileOwnership.swift`. Pinning them here means a
/// rename on this side fails a test rather than silently breaking the handshake in
/// a container nobody is watching.
@Suite("Profile ownership wire format")
struct ProfileOwnershipWireFormatTests {

  @Test("Protocol constants match what the bootstrap hard-codes")
  func constantsArePinned() {
    #expect(ProfileOwnershipProtocol.version == 1)
    #expect(ProfileOwnershipProtocol.controlMountPath == "/agent-isolation/control")
    #expect(ProfileOwnershipProtocol.reportFileName == "ownership-report.json")
    #expect(ProfileOwnershipProtocol.ackFileName == "ownership-ack.json")
    #expect(ProfileOwnershipProtocol.EnvironmentKey.protocolVersion == "AGENTC_OWNERSHIP_PROTOCOL")
    #expect(ProfileOwnershipProtocol.EnvironmentKey.controlDirectory == "AGENTC_OWNERSHIP_CONTROL")
    #expect(ProfileOwnershipProtocol.EnvironmentKey.mode == "AGENTC_OWNERSHIP_MODE")
    #expect(ProfileOwnershipProtocol.EnvironmentKey.expectedUID == "AGENTC_OWNERSHIP_EXPECT_UID")
    #expect(ProfileOwnershipProtocol.EnvironmentKey.expectedGID == "AGENTC_OWNERSHIP_EXPECT_GID")
    #expect(
      ProfileOwnershipProtocol.EnvironmentKey.presentedByMount
        == "AGENTC_OWNERSHIP_PRESENTED_BY_MOUNT")
  }

  @Test("Every control key sits in the reserved AGENTC_ namespace")
  func controlsAreReserved() {
    let keys = [
      ProfileOwnershipProtocol.EnvironmentKey.protocolVersion,
      ProfileOwnershipProtocol.EnvironmentKey.controlDirectory,
      ProfileOwnershipProtocol.EnvironmentKey.mode,
      ProfileOwnershipProtocol.EnvironmentKey.expectedUID,
      ProfileOwnershipProtocol.EnvironmentKey.expectedGID,
      ProfileOwnershipProtocol.EnvironmentKey.presentedByMount,
    ]
    // The session strips user-supplied `AGENTC_*` values, so a caller cannot
    // forge any of these.
    #expect(keys.allSatisfy { $0.hasPrefix("AGENTC_") })
  }

  @Test("Status values round-trip through the wire format")
  func statusValues() {
    #expect(ProfileOwnershipStatus.verified.rawValue == "verified")
    #expect(ProfileOwnershipStatus.initialized.rawValue == "initialized")
    #expect(ProfileOwnershipStatus.repaired.rawValue == "repaired")
    #expect(ProfileOwnershipStatus.needsRepair.rawValue == "needs-repair")
    #expect(ProfileOwnershipStatus.failed.rawValue == "failed")
  }

  @Test("Modes round-trip through the wire format")
  func modeValues() {
    #expect(ProfileOwnershipMode.verify.rawValue == "verify")
    #expect(ProfileOwnershipMode.repair.rawValue == "repair")
  }

  @Test("Decisions round-trip through the wire format")
  func decisionValues() {
    #expect(ProfileOwnershipAcknowledgement.Decision.continue.rawValue == "continue")
    #expect(ProfileOwnershipAcknowledgement.Decision.abort.rawValue == "abort")
  }
}

// MARK: - Surviving sessions

@Suite("Profile ownership surviving sessions")
struct ProfileOwnershipSurvivorTests {

  @Test("With no registered sessions, repair proceeds")
  func noSessionsIsFine() throws {
    let profile = try TempProfile()
    try makeCoordinator(profile).assertNoSurvivingSessions(liveContainerIDs: [])
  }

  @Test("A registered container the runtime still knows about blocks repair")
  func liveContainerBlocksRepair() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    coordinator.registerSession(containerID: "abc123")

    do {
      try coordinator.assertNoSurvivingSessions(liveContainerIDs: ["abc123", "other"])
      Issue.record("expected the surviving container to block repair")
    } catch let error as ProfileOwnershipError {
      #expect(error.description.contains("abc123"))
    }
  }

  @Test("A registration the runtime no longer knows about is pruned")
  func staleRegistrationIsPruned() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    coordinator.registerSession(containerID: "gone")
    #expect(coordinator.registeredSessionIDs() == ["gone"])

    try coordinator.assertNoSurvivingSessions(liveContainerIDs: ["something-else"])
    #expect(coordinator.registeredSessionIDs().isEmpty)
  }

  @Test("A runtime that cannot enumerate does not get the benefit of the doubt")
  func unknownLivenessBlocksRepair() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    coordinator.registerSession(containerID: "abc123")

    do {
      // A released process lock is not proof the profile is idle.
      try coordinator.assertNoSurvivingSessions(liveContainerIDs: nil)
      Issue.record("expected an unknown liveness to block repair")
    } catch let error as ProfileOwnershipError {
      #expect(error.description.contains(coordinator.sessionsDirectory.path))
    }
  }

  @Test("Unregistering removes the record")
  func unregisterRemoves() throws {
    let profile = try TempProfile()
    let coordinator = makeCoordinator(profile)
    coordinator.registerSession(containerID: "abc123")
    coordinator.unregisterSession(containerID: "abc123")
    #expect(coordinator.registeredSessionIDs().isEmpty)
  }

  @Test("Container IDs that could escape the sessions directory are rejected")
  func rejectsPathTraversal() {
    #expect(ProfileOwnershipCoordinator.sessionFileName(for: "abc-123_XYZ") == "abc-123_XYZ.id")
    #expect(ProfileOwnershipCoordinator.sessionFileName(for: "../../etc/passwd") == nil)
    #expect(ProfileOwnershipCoordinator.sessionFileName(for: "a/b") == nil)
    #expect(ProfileOwnershipCoordinator.sessionFileName(for: "") == nil)
    #expect(
      ProfileOwnershipCoordinator.sessionFileName(for: String(repeating: "a", count: 200)) == nil)
  }

  @Test("A registration is withdrawn when the session tears down")
  func sessionUnregistersOnTeardown() async throws {
    let profile = try TempProfile()
    let runtime = OwnershipMockRuntime(config: .init(storagePath: "/tmp"))
    runtime.scriptedReports = [
      ProfileOwnershipReport(status: .initialized, uid: 1000, gid: 1000)
    ]

    let config = IsolationConfig(
      image: "test:latest",
      profileHomeDir: profile.home,
      workspace: URL(fileURLWithPath: "/tmp"),
      configurationsDir: URL(fileURLWithPath: "/tmp"),
      arguments: ["true"],
      bootstrapCapabilities: [.profileOwnershipHandshake])
    let session = AgentSession(config: config, runtime: runtime)
    try await session.start()

    let coordinator = makeCoordinator(profile)
    #expect(coordinator.registeredSessionIDs() == ["mock-container-0"])

    _ = try await session.wait()
    #expect(coordinator.registeredSessionIDs().isEmpty)
  }
}
