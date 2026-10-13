#if ContainerRuntimeAppleContainer
  import AgentIsolation
  import Foundation
  import Synchronization
  import Testing

  @testable import AgentIsolationAppleContainerRuntime

  @Suite("Versioned initfs cache")
  struct InitFSCacheTests {
    private final class Store: Sendable {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("initfs-cache-tests-\(UUID().uuidString)")

      init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      }

      deinit { try? FileManager.default.removeItem(at: url) }
    }

    private static func filesystemData() -> Data {
      var data = Data(repeating: 0, count: 4096)
      data[1024 + 0x38] = 0x53
      data[1024 + 0x39] = 0xEF
      return data
    }

    @Test func keyIncludesReleaseAndPlatform() throws {
      let store = try Store()
      let current = InitFSCache(imageStorePath: store.url)
      let same = InitFSCache(imageStorePath: store.url)
      let old = InitFSCache(
        imageStorePath: store.url, reference: "ghcr.io/apple/containerization/vminit:0.41.0")
      let otherPlatform = InitFSCache(imageStorePath: store.url, platform: "linux/amd64")
      #expect(current.reference == "ghcr.io/apple/containerization/vminit:0.50.0")
      #expect(current.key == same.key)
      #expect(current.key != old.key)
      #expect(current.key != otherPlatform.key)
      #expect(current.key.count == 64)
      #expect(current.key.allSatisfy { $0.isHexDigit })
    }

    @Test func upgradeAndReusePreserveExistingStoreAndDisks() async throws {
      let store = try Store()
      let legacy = store.url.appendingPathComponent("initfs.ext4")
      let images = store.url.appendingPathComponent("images")
      let sessions = store.url.appendingPathComponent("containers/live/rootfs.ext4")
      try FileManager.default.createDirectory(
        at: sessions.deletingLastPathComponent(), withIntermediateDirectories: true)
      for url in [legacy, images, sessions] { try Data("untouched".utf8).write(to: url) }
      let old = InitFSCache(
        imageStorePath: store.url, reference: "ghcr.io/apple/containerization/vminit:0.41.0")
      let oldPath = try await old.prepare { try Self.filesystemData().write(to: $0) }
      let cache = InitFSCache(imageStorePath: store.url)
      let path = try await cache.prepare { try Self.filesystemData().write(to: $0) }
      let hit = try await cache.prepare { _ in Issue.record("cache hit must not unpack") }
      #expect(path == hit)
      #expect(path != oldPath)
      #expect(try Data(contentsOf: oldPath) == Self.filesystemData())
      for url in [legacy, images, sessions] {
        #expect(try Data(contentsOf: url) == Data("untouched".utf8))
      }
    }

    @Test func failedExtractionIsNotPublishedAndCanRetry() async throws {
      struct Failed: Error {}
      let store = try Store()
      let cache = InitFSCache(imageStorePath: store.url)
      await #expect(throws: Failed.self) {
        try await cache.prepare {
          // Even a plausible header must not turn a failed extraction into a hit.
          try Self.filesystemData().write(to: $0)
          throw Failed()
        }
      }
      #expect(!FileManager.default.fileExists(atPath: cache.filesystem.path))
      #expect(!FileManager.default.fileExists(atPath: cache.stagingDirectory.path))
      let path = try await cache.prepare { try Self.filesystemData().write(to: $0) }
      #expect(try Data(contentsOf: path) == Self.filesystemData())
    }

    @Test func abandonedStagingIsNeverReused() async throws {
      let store = try Store()
      let cache = InitFSCache(imageStorePath: store.url)
      try FileManager.default.createDirectory(
        at: cache.stagingDirectory, withIntermediateDirectories: true)
      let abandoned = cache.stagingDirectory.appendingPathComponent("initfs.ext4")
      try Data("partial".utf8).write(to: abandoned)
      let path = try await cache.prepare {
        #expect(!FileManager.default.fileExists(atPath: $0.path))
        try Self.filesystemData().write(to: $0)
      }
      #expect(try Data(contentsOf: path) == Self.filesystemData())
    }

    @Test func invalidExtractionIsRejected() async throws {
      let store = try Store()
      let cache = InitFSCache(imageStorePath: store.url)
      await #expect(throws: InitFSCache.Error.self) {
        try await cache.prepare { try Data("partial".utf8).write(to: $0) }
      }
      #expect(!FileManager.default.fileExists(atPath: cache.filesystem.path))
    }

    @Test func invalidPublishedEntryFailsWithoutReplacingDisk() async throws {
      let store = try Store()
      let cache = InitFSCache(imageStorePath: store.url)
      try FileManager.default.createDirectory(at: cache.root, withIntermediateDirectories: true)
      let bytes = Data("damaged published disk".utf8)
      try bytes.write(to: cache.filesystem)
      await #expect(throws: InitFSCache.Error.self) {
        try await cache.prepare { _ in Issue.record("published disks must not be replaced") }
      }
      #expect(try Data(contentsOf: cache.filesystem) == bytes)
    }

    @Test func concurrentLaunchesOnlyReceiveCompletedFilesystem() async throws {
      let store = try Store()
      let cache = InitFSCache(imageStorePath: store.url)
      let unpacks = Mutex(0)
      try await withThrowingTaskGroup(of: URL.self) { group in
        for _ in 0..<12 {
          group.addTask {
            try await cache.prepare { destination in
              unpacks.withLock { $0 += 1 }
              try Data("partial".utf8).write(to: destination)
              #expect(!FileManager.default.fileExists(atPath: cache.filesystem.path))
              try await Task.sleep(for: .milliseconds(50))
              try Self.filesystemData().write(to: destination)
            }
          }
        }
        for try await path in group {
          #expect(path == cache.filesystem)
          #expect(try Data(contentsOf: path) == Self.filesystemData())
        }
      }
      #expect(unpacks.withLock { $0 } == 1)
    }

    @Test func waitingForLockIsCancellable() async throws {
      let store = try Store()
      let cache = InitFSCache(imageStorePath: store.url)
      try FileManager.default.createDirectory(at: cache.root, withIntermediateDirectories: true)
      let lock = try FileLock.acquire(at: cache.lockFile, mode: .exclusive)
      defer { lock.release() }
      let waiter = Task {
        try await cache.prepare { _ in Issue.record("cancelled waiter must not unpack") }
      }
      waiter.cancel()
      await #expect(throws: CancellationError.self) { try await waiter.value }
      #expect(!FileManager.default.fileExists(atPath: cache.filesystem.path))
    }
  }
#endif
