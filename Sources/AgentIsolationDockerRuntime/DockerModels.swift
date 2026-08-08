#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// MARK: - Daemon Info

/// The subset of `GET /info` we use to discover which runtimes the daemon can invoke.
///
/// Docker reports every runtime registered in `daemon.json` (plus the built-in `runc`).
/// It can additionally invoke fully-qualified containerd shims found on its `PATH` without
/// registering them, so absence from `Runtimes` does not mean a runtime is unusable —
/// hence ``DockerRuntimeSelection/Source/configured``.
struct DockerInfo: Codable, Sendable {
  let Runtimes: [String: RuntimeEntry]?
  let DefaultRuntime: String?

  /// A registered runtime. `path` is set for OCI runtime binaries, `runtimeType` for
  /// containerd shims — either one can identify a runtime hiding behind an opaque alias.
  struct RuntimeEntry: Codable, Sendable {
    var path: String?
    var runtimeType: String?

    init(path: String? = nil, runtimeType: String? = nil) {
      self.path = path
      self.runtimeType = runtimeType
    }
  }
}

// MARK: - Image Types

struct DockerImageInspect: Codable, Sendable {
  let Id: String
  let RepoTags: [String]?
  let RepoDigests: [String]?
}

struct DockerPullProgress: Codable, Sendable {
  let status: String?
  let id: String?
  let progressDetail: ProgressDetail?
  let progress: String?
  let error: String?

  struct ProgressDetail: Codable, Sendable {
    let current: Int64?
    let total: Int64?
  }
}

// MARK: - Container Types

struct DockerCreateContainerRequest: Codable, Sendable {
  var Image: String
  var Entrypoint: [String]?
  var Cmd: [String]?
  var Env: [String]?
  var WorkingDir: String?
  var Tty: Bool?
  var OpenStdin: Bool?
  var AttachStdin: Bool?
  var AttachStdout: Bool?
  var AttachStderr: Bool?
  var HostConfig: DockerHostConfig?
}

struct DockerHostConfig: Codable, Sendable {
  var Binds: [String]?
  var Memory: Int64?
  var NanoCpus: Int64?
  var CpusetCpus: String?
  var Init: Bool?
  /// The runtime to run this container with. Left `nil` to use the daemon's default.
  var Runtime: String?
}

struct DockerCreateContainerResponse: Codable, Sendable {
  let Id: String
  let Warnings: [String]?
}

struct DockerContainerWaitResponse: Codable, Sendable {
  let StatusCode: Int64
  let Error: WaitError?

  struct WaitError: Codable, Sendable {
    let Message: String?
  }
}
