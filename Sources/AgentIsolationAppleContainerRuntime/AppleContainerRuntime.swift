import AgentIsolation
import Containerization
import ContainerizationArchive
import ContainerizationOS
import CryptoKit
import Foundation
import Logging

/// Container runtime that runs containers directly using Apple's Virtualization.framework
/// via the `containerization` package — no XPC daemon required.
public struct AppleContainerRuntime: ContainerRuntimeProtocol {
    public init() {}

    // MARK: - Data directories

    private static var dataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("com.apple.claudec")
    }

    private static var containerAppDataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("com.apple.container")
    }

    // MARK: - Run

    public func run(config: IsolationConfig) async throws -> Int32 {
        let dataRoot = Self.dataRoot
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

        // Resolve canonical workspace (follows symlinks, handles /tmp → /private/tmp on macOS)
        let canonicalWorkspace = config.workspace.resolvingSymlinksInPathWithPrivate()
        let workspaceHash = sha256Hex(canonicalWorkspace.path)
        let workspaceContainerPath = "/workspace/\(workspaceHash)"

        try FileManager.default.createDirectory(
            at: config.profileHomeDir,
            withIntermediateDirectories: true
        )

        let kernel = try await getOrDownloadKernel(dataRoot: dataRoot)

        let imageStoreRoot = dataRoot.appendingPathComponent("imagestore")
        let imageStore = try ImageStore(path: imageStoreRoot)

        let network: ContainerManager.Network?
        if #available(macOS 26.0, *) {
            network = try ContainerManager.VmnetNetwork()
        } else {
            network = nil
        }

        // ContainerManager handles initfs caching: downloads vminit:0.29.0 once,
        // creates initfs.ext4, and reuses it on subsequent runs.
        var manager = try await ContainerManager(
            kernel: kernel,
            initfsReference: "ghcr.io/apple/containerization/vminit:0.29.0",
            imageStore: imageStore,
            network: network
        )

        // Set up terminal before creating the container
        var terminal: Terminal? = nil
        if config.allocateTTY {
            terminal = try? Terminal.current
            try terminal?.setraw()
        }
        defer { terminal?.tryReset() }

        // virtiofs requires directory mounts; copy the bootstrap script into a
        // temp dir so it can be shared as a read-only virtiofs volume.
        var bootstrapTempDir: URL? = nil
        var bootstrapContainerPath: String? = nil
        defer { if let d = bootstrapTempDir { try? FileManager.default.removeItem(at: d) } }

        if let bootstrapScript = config.bootstrapScript {
            let tempDir = try makeTempDir()
            bootstrapTempDir = tempDir
            let destScript = tempDir.appendingPathComponent("entrypoint.sh")
            try FileManager.default.copyItem(at: bootstrapScript, to: destScript)
            // Preserve or grant execute permission
            let srcPerms = (try? FileManager.default.attributesOfItem(atPath: bootstrapScript.path)[.posixPermissions] as? Int) ?? 0o644
            try FileManager.default.setAttributes(
                [.posixPermissions: srcPerms | 0o111],
                ofItemAtPath: destScript.path
            )
            bootstrapContainerPath = "/entrypoint-bootstrap/entrypoint.sh"
        }

        // Empty temp dirs mounted over excluded workspace subdirectories
        var excludeDirs: [(host: URL, container: String)] = []
        defer { for e in excludeDirs { try? FileManager.default.removeItem(at: e.host) } }

        for rawFolder in config.excludeFolders {
            let folder = rawFolder.trimmingCharacters(in: .init(charactersIn: "/"))
            guard !folder.isEmpty else { continue }
            let tempDir = try makeTempDir()
            excludeDirs.append((host: tempDir, container: "\(workspaceContainerPath)/\(folder)"))
        }

        let containerID = UUID().uuidString.lowercased()

        let container = try await manager.create(
            containerID,
            reference: config.image,
            rootfsSizeInBytes: UInt64(8).gib()
        ) { containerConfig in
            containerConfig.cpus = 4
            containerConfig.memoryInBytes = UInt64(1536).mib()

            // Override entrypoint: use custom bootstrap script or image default
            if let bootstrapPath = bootstrapContainerPath {
                containerConfig.process.arguments = [bootstrapPath] + config.arguments
            } else {
                // init(from: imageConfig) already set entrypoint; append user args
                containerConfig.process.arguments += config.arguments
            }
            containerConfig.process.workingDirectory = workspaceContainerPath

            // Profile home and workspace
            containerConfig.mounts.append(.share(
                source: config.profileHomeDir.path,
                destination: "/home/claude"
            ))
            containerConfig.mounts.append(.share(
                source: canonicalWorkspace.path,
                destination: workspaceContainerPath
            ))

            // Excluded folders (each an empty read-only overlay)
            for exclude in excludeDirs {
                containerConfig.mounts.append(.share(
                    source: exclude.host.resolvingSymlinksInPathWithPrivate().path,
                    destination: exclude.container
                ))
            }

            // Bootstrap script directory (if present)
            if let bootstrapDir = bootstrapTempDir {
                containerConfig.mounts.append(.share(
                    source: bootstrapDir.resolvingSymlinksInPathWithPrivate().path,
                    destination: "/entrypoint-bootstrap"
                ))
            }

            // I/O
            if let t = terminal {
                containerConfig.process.setTerminalIO(terminal: t)
            } else {
                containerConfig.process.stdin = FileHandleReader(.standardInput)
                containerConfig.process.stdout = FileHandleWriter(.standardOutput)
                containerConfig.process.stderr = FileHandleWriter(.standardError)
            }
        }

        defer { try? manager.delete(containerID) }

        try await container.create()
        try await container.start()

        if let t = terminal {
            try? await container.resize(to: try t.size)
        }

        let exitStatus: ExitStatus
        if let t = terminal {
            let sigwinchStream = AsyncSignalHandler.create(notify: [SIGWINCH])
            exitStatus = try await withThrowingTaskGroup(of: ExitStatus?.self) { group in
                group.addTask {
                    for await _ in sigwinchStream.signals {
                        try await container.resize(to: try t.size)
                    }
                    return nil
                }
                group.addTask { try await container.wait() }
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
            exitStatus = try await container.wait()
        }

        try await container.stop()
        return exitStatus.exitCode
    }

    // MARK: - Kernel

    private func getOrDownloadKernel(dataRoot: URL) async throws -> Kernel {
        // 1. Try the container app's installed kernel
        let appKernelLink = Self.containerAppDataRoot
            .appendingPathComponent("kernels")
            .appendingPathComponent("default.kernel-arm64")
        let appKernelResolved = appKernelLink.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: appKernelResolved.path) {
            return Kernel(path: appKernelResolved, platform: .linuxArm)
        }

        // 2. Try our own cached kernel
        let ourKernelDir = dataRoot.appendingPathComponent("kernels")
        let ourKernelLink = ourKernelDir.appendingPathComponent("default.kernel-arm64")
        let ourKernelResolved = ourKernelLink.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: ourKernelResolved.path) {
            return Kernel(path: ourKernelResolved, platform: .linuxArm)
        }

        // 3. Download kernel from kata-containers
        fputs("claudec: downloading kernel (one-time setup)...\n", stderr)
        let tarURL = URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.26.0/kata-static-3.26.0-arm64.tar.zst")!
        let kernelPathInArchive = "opt/kata/share/kata-containers/vmlinux-6.18.5-177"

        let (tempFile, _) = try await URLSession.shared.download(from: tarURL)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        var archiveReader = try ArchiveReader(file: tempFile)
        let (_, kernelData) = try archiveReader.extractFile(path: kernelPathInArchive)

        try FileManager.default.createDirectory(at: ourKernelDir, withIntermediateDirectories: true)
        let kernelBinary = ourKernelDir.appendingPathComponent("vmlinux-6.18.5-177")
        try kernelData.write(to: kernelBinary, options: .atomic)

        try? FileManager.default.removeItem(at: ourKernelLink)
        try FileManager.default.createSymbolicLink(at: ourKernelLink, withDestinationURL: kernelBinary)

        return Kernel(path: kernelBinary, platform: .linuxArm)
    }

    // MARK: - Helpers

    private func sha256Hex(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/claudec-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
