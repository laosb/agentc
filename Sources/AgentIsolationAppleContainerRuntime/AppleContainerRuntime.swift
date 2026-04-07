#if canImport(Containerization)
  import AgentIsolation
  import Containerization
  import ContainerizationArchive
  import ContainerizationOCI
  import ContainerizationOS
  import Foundation
  import Logging

  // MARK: - AppleContainerRuntime

  /// Container runtime that runs containers directly using Apple's Virtualization.framework
  /// via the `containerization` package — no XPC daemon required.
  public final class AppleContainerRuntime: ContainerRuntime, @unchecked Sendable {
    public typealias Image = AppleContainerImage
    public typealias Container = AppleContainerContainer

    private let storagePath: URL
    private var manager: ContainerManager?
    private var imageStore: ImageStore?

    private static var containerAppDataRoot: URL {
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("com.apple.container")
    }

    public required init(config: ContainerRuntimeConfiguration) {
      self.storagePath = URL(fileURLWithPath: config.storagePath)
    }

    // MARK: - ContainerRuntime

    public func prepare() async throws {
      try FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: true)

      let kernel = try await getOrDownloadKernel()

      let imageStoreRoot = storagePath.appendingPathComponent("imagestore")
      let store = try ImageStore(path: imageStoreRoot)
      self.imageStore = store

      let network: ContainerManager.Network?
      if #available(macOS 26.0, *) {
        network = try ContainerManager.VmnetNetwork()
      } else {
        network = nil
      }

      self.manager = try await ContainerManager(
        kernel: kernel,
        initfsReference: "ghcr.io/apple/containerization/vminit:0.29.0",
        imageStore: store,
        network: network
      )
    }

    public func pullImage(ref: String) async throws -> AppleContainerImage? {
      guard let store = imageStore else {
        throw AppleContainerRuntimeError.notPrepared
      }
      do {
        let image = try await store.pull(reference: ref, platform: .current)
        return AppleContainerImage(ref: ref, digest: image.digest)
      } catch {
        // Pull failure — image may not exist or network error
        return nil
      }
    }

    public func inspectImage(ref: String) async throws -> AppleContainerImage? {
      guard let store = imageStore else {
        throw AppleContainerRuntimeError.notPrepared
      }
      do {
        let image = try await store.get(reference: ref)
        return AppleContainerImage(ref: ref, digest: image.digest)
      } catch {
        return nil
      }
    }

    public func removeImage(ref: String) async throws {
      guard let store = imageStore else {
        throw AppleContainerRuntimeError.notPrepared
      }
      try await store.delete(reference: ref, performCleanup: true)
    }

    public func removeImage(digest: String) async throws {
      guard let store = imageStore else {
        throw AppleContainerRuntimeError.notPrepared
      }
      try await store.delete(reference: digest, performCleanup: true)
    }

    public func runContainer(
      imageRef: String,
      configuration: ContainerConfiguration
    ) async throws -> AppleContainerContainer {
      guard var manager else {
        throw AppleContainerRuntimeError.notPrepared
      }

      // Set up terminal before creating the container
      var terminal: Terminal? = nil
      switch configuration.io {
      case .currentTerminal:
        terminal = try? Terminal.current
        try terminal?.setraw()
      default:
        break
      }

      let containerID = UUID().uuidString.lowercased()

      let container = try await manager.create(
        containerID,
        reference: imageRef,
        rootfsSizeInBytes: UInt64(8).gib()
      ) { containerConfig in
        containerConfig.cpus = 4
        containerConfig.memoryInBytes = UInt64(1536).mib()

        // Entrypoint
        if !configuration.entrypoint.isEmpty {
          containerConfig.process.arguments = configuration.entrypoint
        }

        // Working directory
        if let workDir = configuration.workingDirectory {
          containerConfig.process.workingDirectory = workDir
        }

        // Environment
        for (key, value) in configuration.environment {
          containerConfig.process.environmentVariables.append("\(key)=\(value)")
        }

        // Mounts
        for mount in configuration.mounts {
          containerConfig.mounts.append(
            .share(
              source: mount.hostPath,
              destination: mount.containerPath
            ))
        }

        // I/O
        switch configuration.io {
        case .currentTerminal:
          if let t = terminal {
            containerConfig.process.setTerminalIO(terminal: t)
          }
        case .standardIO:
          containerConfig.process.stdin = FileHandleReader(.standardInput)
          containerConfig.process.stdout = FileHandleWriter(.standardOutput)
          containerConfig.process.stderr = FileHandleWriter(.standardError)
        case .custom:
          // Custom IO not yet bridged to Containerization types
          containerConfig.process.stdin = FileHandleReader(.standardInput)
          containerConfig.process.stdout = FileHandleWriter(.standardOutput)
          containerConfig.process.stderr = FileHandleWriter(.standardError)
        }
      }

      try await container.create()
      try await container.start()

      if let t = terminal {
        try? await container.resize(to: try t.size)
      }

      return AppleContainerContainer(
        id: containerID,
        container: container,
        manager: manager,
        terminal: terminal
      )
    }

    public func shutdown() async throws {
      manager = nil
      imageStore = nil
    }

    public func removeContainer(_ container: AppleContainerContainer) async throws {
      container.terminal?.tryReset()
      try await container.underlyingContainer.stop()
      try container.manager.delete(container.id)
    }

    // MARK: - Kernel

    private func getOrDownloadKernel() async throws -> Kernel {
      // 1. Try the container app's installed kernel
      let appKernelLink =
        Self.containerAppDataRoot
        .appendingPathComponent("kernels")
        .appendingPathComponent("default.kernel-arm64")
      let appKernelResolved = appKernelLink.resolvingSymlinksInPath()
      if FileManager.default.fileExists(atPath: appKernelResolved.path) {
        return Kernel(path: appKernelResolved, platform: .linuxArm)
      }

      // 2. Try our own cached kernel
      let ourKernelDir = storagePath.appendingPathComponent("kernels")
      let ourKernelLink = ourKernelDir.appendingPathComponent("default.kernel-arm64")
      let ourKernelResolved = ourKernelLink.resolvingSymlinksInPath()
      if FileManager.default.fileExists(atPath: ourKernelResolved.path) {
        return Kernel(path: ourKernelResolved, platform: .linuxArm)
      }

      // 3. Download kernel from kata-containers
      fputs("claudec: downloading kernel (one-time setup)...\n", stderr)
      let tarURL = URL(
        string:
          "https://github.com/kata-containers/kata-containers/releases/download/3.26.0/kata-static-3.26.0-arm64.tar.zst"
      )!
      let kernelPathInArchive = "opt/kata/share/kata-containers/vmlinux-6.18.5-177"

      let (tempFile, _) = try await URLSession.shared.download(from: tarURL)
      defer { try? FileManager.default.removeItem(at: tempFile) }

      let archiveReader = try ArchiveReader(file: tempFile)
      let (_, kernelData) = try archiveReader.extractFile(path: kernelPathInArchive)

      try FileManager.default.createDirectory(at: ourKernelDir, withIntermediateDirectories: true)
      let kernelBinary = ourKernelDir.appendingPathComponent("vmlinux-6.18.5-177")
      try kernelData.write(to: kernelBinary, options: .atomic)

      try? FileManager.default.removeItem(at: ourKernelLink)
      try FileManager.default.createSymbolicLink(
        at: ourKernelLink, withDestinationURL: kernelBinary)

      return Kernel(path: kernelBinary, platform: .linuxArm)
    }
  }

  // MARK: - Associated Types

  public struct AppleContainerImage: ContainerRuntimeImage {
    public var ref: String
    public var digest: String

    public init(ref: String, digest: String) {
      self.ref = ref
      self.digest = digest
    }
  }

  public final class AppleContainerContainer: ContainerRuntimeContainer, @unchecked Sendable {
    public let id: String
    let underlyingContainer: LinuxContainer
    var manager: ContainerManager
    var terminal: Terminal?

    init(
      id: String,
      container: LinuxContainer,
      manager: ContainerManager,
      terminal: Terminal?
    ) {
      self.id = id
      self.underlyingContainer = container
      self.manager = manager
      self.terminal = terminal
    }

    public func wait(timeoutInSeconds: Int64?) async throws -> Int32 {
      let exitStatus: ExitStatus
      if let t = terminal {
        let sigwinchStream = AsyncSignalHandler.create(notify: [SIGWINCH])
        exitStatus = try await withThrowingTaskGroup(of: ExitStatus?.self) { group in
          group.addTask {
            for await _ in sigwinchStream.signals {
              try await self.underlyingContainer.resize(to: try t.size)
            }
            return nil
          }
          group.addTask { try await self.underlyingContainer.wait() }
          var result: ExitStatus? = nil
          for try await value in group {
            if let value {
              result = value
              group.cancelAll()
              break
            }
          }
          return result ?? ExitStatus(exitCode: 0)
        }
      } else {
        exitStatus = try await underlyingContainer.wait()
      }
      return exitStatus.exitCode
    }

    public func stop() async throws {
      terminal?.tryReset()
      try await underlyingContainer.stop()
    }
  }

  // MARK: - Errors

  public enum AppleContainerRuntimeError: LocalizedError {
    case notPrepared

    public var errorDescription: String? {
      switch self {
      case .notPrepared:
        return "Container runtime has not been prepared. Call prepare() first."
      }
    }
  }
#endif
