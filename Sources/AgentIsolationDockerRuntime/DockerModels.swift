import Foundation

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
