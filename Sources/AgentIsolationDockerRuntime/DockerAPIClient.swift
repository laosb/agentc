import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat

/// HTTP client for Docker Engine API v1.44.
///
/// Supports Unix domain socket and TCP connections.
final class DockerAPIClient: Sendable {
  private let httpClient: HTTPClient
  let apiBase: String
  let endpoint: String

  init(endpoint: String) {
    self.endpoint = endpoint

    if endpoint.hasPrefix("/") || endpoint.hasPrefix("unix://") {
      let path = endpoint.hasPrefix("unix://") ? String(endpoint.dropFirst(7)) : endpoint
      let encoded =
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
        .replacingOccurrences(of: "/", with: "%2F") ?? path
      self.apiBase = "http+unix://\(encoded)/v1.44"
    } else {
      let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
      self.apiBase = "\(base)/v1.44"
    }

    self.httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
  }

  func shutdown() async throws {
    try await httpClient.shutdown()
  }

  // MARK: - Ping

  func ping() async throws {
    var request = HTTPClientRequest(url: "\(apiBase)/_ping")
    request.method = .GET
    let response = try await httpClient.execute(request, timeout: .seconds(10))
    guard response.status == .ok else {
      throw DockerRuntimeError.dockerNotAccessible(
        "Docker responded with status \(response.status.code)")
    }
  }

  // MARK: - Image Operations

  func pullImage(ref: String) async throws {
    let (image, tag) = parseImageRef(ref)
    let encodedImage = image.urlQueryEncoded
    let encodedTag = tag.urlQueryEncoded

    var request = HTTPClientRequest(
      url: "\(apiBase)/images/create?fromImage=\(encodedImage)&tag=\(encodedTag)")
    request.method = .POST

    let response = try await httpClient.execute(request, timeout: .seconds(600))
    guard response.status == .ok else {
      let body = try? await response.body.collect(upTo: 1024 * 1024)
      let message = body.flatMap { String(buffer: $0) } ?? "unknown error"
      throw DockerRuntimeError.pullFailed("\(response.status.code): \(message)")
    }

    // Consume the streaming response (progress updates) and check for errors
    for try await chunk in response.body {
      let bytes = String(buffer: chunk)
      for line in bytes.split(separator: "\n") where !line.isEmpty {
        if let data = line.data(using: .utf8),
          let progress = try? JSONDecoder().decode(DockerPullProgress.self, from: data),
          let error = progress.error, !error.isEmpty
        {
          throw DockerRuntimeError.pullFailed(error)
        }
      }
    }
  }

  func inspectImage(ref: String) async throws -> DockerImageInspect? {
    let encodedRef = ref.urlPathEncoded
    var request = HTTPClientRequest(url: "\(apiBase)/images/\(encodedRef)/json")
    request.method = .GET

    let response = try await httpClient.execute(request, timeout: .seconds(30))
    if response.status == .notFound {
      // Consume body to avoid connection leak
      for try await _ in response.body {}
      return nil
    }
    guard response.status == .ok else {
      for try await _ in response.body {}
      throw DockerRuntimeError.apiError(
        Int(response.status.code), "Failed to inspect image \(ref)")
    }

    let body = try await response.body.collect(upTo: 10 * 1024 * 1024)
    return try JSONDecoder().decode(DockerImageInspect.self, from: body)
  }

  func removeImage(nameOrDigest: String, force: Bool = false) async throws {
    let encoded = nameOrDigest.urlPathEncoded
    var request = HTTPClientRequest(
      url: "\(apiBase)/images/\(encoded)?force=\(force)")
    request.method = .DELETE

    let response = try await httpClient.execute(request, timeout: .seconds(30))
    // Consume body
    for try await _ in response.body {}
    guard response.status == .ok else {
      if response.status == .notFound { return }
      throw DockerRuntimeError.apiError(
        Int(response.status.code), "Failed to remove image \(nameOrDigest)")
    }
  }

  // MARK: - Container Operations

  func createContainer(config: DockerCreateContainerRequest) async throws -> String {
    var request = HTTPClientRequest(url: "\(apiBase)/containers/create")
    request.method = .POST
    request.headers.add(name: "Content-Type", value: "application/json")

    let body = try JSONEncoder().encode(config)
    request.body = .bytes(body)

    let response = try await httpClient.execute(request, timeout: .seconds(60))
    let responseBody = try await response.body.collect(upTo: 1024 * 1024)
    guard response.status == .created else {
      let message = String(buffer: responseBody)
      throw DockerRuntimeError.apiError(
        Int(response.status.code), "Failed to create container: \(message)")
    }

    let createResp = try JSONDecoder().decode(
      DockerCreateContainerResponse.self, from: responseBody)
    return createResp.Id
  }

  func startContainer(id: String) async throws {
    var request = HTTPClientRequest(url: "\(apiBase)/containers/\(id)/start")
    request.method = .POST

    let response = try await httpClient.execute(request, timeout: .seconds(30))
    for try await _ in response.body {}
    guard response.status == .noContent || response.status == .notModified else {
      throw DockerRuntimeError.apiError(
        Int(response.status.code), "Failed to start container \(id)")
    }
  }

  func waitContainer(id: String) async throws -> Int64 {
    var request = HTTPClientRequest(url: "\(apiBase)/containers/\(id)/wait")
    request.method = .POST

    let response = try await httpClient.execute(request, timeout: .hours(24))
    let body = try await response.body.collect(upTo: 1024 * 1024)
    guard response.status == .ok else {
      let message = String(buffer: body)
      throw DockerRuntimeError.apiError(
        Int(response.status.code), "Failed to wait for container \(id): \(message)")
    }

    let waitResp = try JSONDecoder().decode(
      DockerContainerWaitResponse.self, from: body)
    return waitResp.StatusCode
  }

  func stopContainer(id: String, timeout: Int = 10) async throws {
    var request = HTTPClientRequest(
      url: "\(apiBase)/containers/\(id)/stop?t=\(timeout)")
    request.method = .POST

    let response = try await httpClient.execute(request, timeout: .seconds(Int64(timeout + 30)))
    for try await _ in response.body {}
    // 204 = stopped, 304 = already stopped, 404 = not found — all acceptable
    guard response.status == .noContent || response.status == .notModified
      || response.status == .notFound
    else {
      throw DockerRuntimeError.apiError(
        Int(response.status.code), "Failed to stop container \(id)")
    }
  }

  func removeContainer(id: String, force: Bool = true) async throws {
    var request = HTTPClientRequest(
      url: "\(apiBase)/containers/\(id)?force=\(force)&v=true")
    request.method = .DELETE

    let response = try await httpClient.execute(request, timeout: .seconds(30))
    for try await _ in response.body {}
    guard response.status == .noContent || response.status == .notFound else {
      throw DockerRuntimeError.apiError(
        Int(response.status.code), "Failed to remove container \(id)")
    }
  }

  func resizeContainerTTY(id: String, width: Int, height: Int) async throws {
    var request = HTTPClientRequest(
      url: "\(apiBase)/containers/\(id)/resize?w=\(width)&h=\(height)")
    request.method = .POST

    let response = try await httpClient.execute(request, timeout: .seconds(10))
    for try await _ in response.body {}
  }

  // MARK: - Helpers

  private func parseImageRef(_ ref: String) -> (image: String, tag: String) {
    // Handle refs like "ghcr.io/user/repo:tag" or "ubuntu:22.04" or "ubuntu"
    // The tag separator is the last `:` that isn't part of a port number
    if let lastColon = ref.lastIndex(of: ":") {
      let afterColon = ref[ref.index(after: lastColon)...]
      // If after colon contains '/', it's a port not a tag (e.g., "host:5000/image")
      if !afterColon.contains("/") {
        return (String(ref[..<lastColon]), String(afterColon))
      }
    }
    return (ref, "latest")
  }
}

// MARK: - URL Encoding Helpers

extension String {
  /// Percent-encode for use in URL query parameter values.
  var urlQueryEncoded: String {
    addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
  }

  /// Percent-encode for use in URL path segments (encodes `/`).
  var urlPathEncoded: String {
    addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
      .replacingOccurrences(of: "/", with: "%2F") ?? self
  }
}

// MARK: - TimeAmount Extension

extension TimeAmount {
  static func hours(_ hours: Int64) -> TimeAmount {
    .seconds(hours * 3600)
  }
}
