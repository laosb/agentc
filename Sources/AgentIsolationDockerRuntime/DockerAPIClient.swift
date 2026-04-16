import AsyncHTTPClient
import NIOCore
import NIOFoundationCompat

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// HTTP client for Docker Engine API v1.44.
///
/// Supports Unix domain socket and TCP connections.
final class DockerAPIClient: Sendable {
  private let httpClient: HTTPClient
  /// Whether connected via Unix socket (requires explicit Host header).
  private let isUnixSocket: Bool
  /// Scheme + authority portion, e.g. `http+unix://%2Fvar%2Frun%2Fdocker.sock` or `http://localhost:2375`.
  private let baseAuthority: String
  let endpoint: String

  /// Base path prefix for all API calls.
  static let apiVersion = "/v1.44"

  init(endpoint: String) {
    self.endpoint = endpoint

    if endpoint.hasPrefix("/") || endpoint.hasPrefix("unix://") {
      let path = endpoint.hasPrefix("unix://") ? String(endpoint.dropFirst(7)) : endpoint
      let encoded =
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
        .replacingOccurrences(of: "/", with: "%2F") ?? path
      self.baseAuthority = "http+unix://\(encoded)"
      self.isUnixSocket = true
    } else {
      var base = endpoint
      // Ensure scheme is present
      if !base.contains("://") {
        base = "http://\(base)"
      }
      // Strip trailing slash
      if base.hasSuffix("/") { base = String(base.dropLast()) }
      self.baseAuthority = base
      self.isUnixSocket = false
    }

    self.httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
  }

  func shutdown() async throws {
    try await httpClient.shutdown()
  }

  // MARK: - Request Builder

  /// Build a full URL from a path and optional query items using URLComponents.
  func buildURL(path: String, queryItems: [URLQueryItem]? = nil) -> String {
    var components = URLComponents()
    components.path = Self.apiVersion + path
    if let items = queryItems, !items.isEmpty {
      components.queryItems = items
    }
    // URLComponents.string produces path?query (no scheme/host), which we prepend to baseAuthority.
    // percentEncodedQuery is used by URLComponents automatically.
    let pathAndQuery = components.string ?? (Self.apiVersion + path)
    return "\(baseAuthority)\(pathAndQuery)"
  }

  /// Create an HTTPClientRequest with the correct Host header for Unix sockets.
  private func makeRequest(url: String) -> HTTPClientRequest {
    var request = HTTPClientRequest(url: url)
    if isUnixSocket {
      // Docker Engine on Linux strictly requires Host header per HTTP/1.1.
      // AsyncHTTPClient derives Host from the URL authority, which for
      // http+unix:// is the percent-encoded socket path — not a valid hostname.
      request.headers.replaceOrAdd(name: "Host", value: "localhost")
    }
    return request
  }

  // MARK: - Ping

  func ping() async throws {
    var request = makeRequest(url: buildURL(path: "/_ping"))
    request.method = .GET
    let response = try await httpClient.execute(request, timeout: .seconds(10))
    guard response.status == .ok else {
      let body = try? await response.body.collect(upTo: 1024 * 1024)
      throw DockerRuntimeError.dockerNotAccessible(
        "Docker responded with status \(response.status.code): \(body.flatMap { String(buffer: $0) } ?? "unknown error")"
      )
    }
  }

  // MARK: - Image Operations

  func pullImage(ref: String, platform: String? = nil) async throws {
    let (image, tag) = Self.parseImageRef(ref)

    var queryItems = [
      URLQueryItem(name: "fromImage", value: image),
      URLQueryItem(name: "tag", value: tag),
    ]
    if let platform = platform {
      queryItems.append(URLQueryItem(name: "platform", value: platform))
    }

    var request = makeRequest(
      url: buildURL(path: "/images/create", queryItems: queryItems))
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
    let encodedRef = Self.pathEncodeComponent(ref)
    var request = makeRequest(
      url: buildURL(path: "/images/\(encodedRef)/json"))
    request.method = .GET

    let response = try await httpClient.execute(request, timeout: .seconds(30))
    if response.status == .notFound || response.status == .badRequest {
      // 404 = image not found; 400 = invalid reference format (e.g. uppercase chars).
      // Either way the image cannot exist locally, so return nil.
      for try await _ in response.body {}
      return nil
    }
    guard response.status == .ok else {
      let body = try? await response.body.collect(upTo: 1024 * 1024)
      let message = body.flatMap { String(buffer: $0) } ?? "unknown error"
      throw DockerRuntimeError.apiError(
        Int(response.status.code), "Failed to inspect image \(ref): \(message)")
    }

    let body = try await response.body.collect(upTo: 10 * 1024 * 1024)
    return try JSONDecoder().decode(DockerImageInspect.self, from: body)
  }

  func removeImage(nameOrDigest: String, force: Bool = false) async throws {
    let encoded = Self.pathEncodeComponent(nameOrDigest)
    let queryItems = [URLQueryItem(name: "force", value: String(force))]
    var request = makeRequest(
      url: buildURL(path: "/images/\(encoded)", queryItems: queryItems))
    request.method = .DELETE

    let response = try await httpClient.execute(request, timeout: .seconds(30))
    for try await _ in response.body {}
    guard response.status == .ok else {
      if response.status == .notFound { return }
      throw DockerRuntimeError.apiError(
        Int(response.status.code), "Failed to remove image \(nameOrDigest)")
    }
  }

  // MARK: - Container Operations

  func createContainer(config: DockerCreateContainerRequest) async throws -> String {
    var request = makeRequest(
      url: buildURL(path: "/containers/create"))
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
    var request = makeRequest(
      url: buildURL(path: "/containers/\(id)/start"))
    request.method = .POST

    let response = try await httpClient.execute(request, timeout: .seconds(30))
    for try await _ in response.body {}
    guard response.status == .noContent || response.status == .notModified else {
      throw DockerRuntimeError.apiError(
        Int(response.status.code), "Failed to start container \(id)")
    }
  }

  func waitContainer(id: String) async throws -> Int64 {
    var request = makeRequest(
      url: buildURL(path: "/containers/\(id)/wait"))
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
    let queryItems = [URLQueryItem(name: "t", value: String(timeout))]
    var request = makeRequest(
      url: buildURL(path: "/containers/\(id)/stop", queryItems: queryItems))
    request.method = .POST

    let response = try await httpClient.execute(request, timeout: .seconds(Int64(timeout + 30)))
    for try await _ in response.body {}
    // 204 = stopped, 304 = already stopped, 404 = not found — all acceptable
    guard
      response.status == .noContent || response.status == .notModified
        || response.status == .notFound
    else {
      throw DockerRuntimeError.apiError(
        Int(response.status.code), "Failed to stop container \(id)")
    }
  }

  func removeContainer(id: String, force: Bool = true) async throws {
    let queryItems = [
      URLQueryItem(name: "force", value: String(force)),
      URLQueryItem(name: "v", value: "true"),
    ]
    var request = makeRequest(
      url: buildURL(path: "/containers/\(id)", queryItems: queryItems))
    request.method = .DELETE

    let response = try await httpClient.execute(request, timeout: .seconds(30))
    for try await _ in response.body {}
    guard response.status == .noContent || response.status == .notFound else {
      throw DockerRuntimeError.apiError(
        Int(response.status.code), "Failed to remove container \(id)")
    }
  }

  func resizeContainerTTY(id: String, width: Int, height: Int) async throws {
    let queryItems = [
      URLQueryItem(name: "w", value: String(width)),
      URLQueryItem(name: "h", value: String(height)),
    ]
    var request = makeRequest(
      url: buildURL(path: "/containers/\(id)/resize", queryItems: queryItems))
    request.method = .POST

    let response = try await httpClient.execute(request, timeout: .seconds(10))
    for try await _ in response.body {}
  }

  // MARK: - Helpers

  /// Parse a Docker image reference into (image, tag).
  ///
  /// Handles refs like `ghcr.io/user/repo:tag`, `ubuntu:22.04`, or `ubuntu` (defaults to `latest`).
  static func parseImageRef(_ ref: String) -> (image: String, tag: String) {
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

  /// Percent-encode a string for use as a URL path component.
  ///
  /// Allows unreserved characters (RFC 3986 §2.3) plus the sub-delimiter and
  /// pchar extras that are legal in path segments — but NOT `/`, which must be
  /// encoded when it appears inside a Docker image reference.
  static func pathEncodeComponent(_ value: String) -> String {
    // Characters allowed in a URL path segment (RFC 3986) minus '/'.
    let allowed: Set<Character> = Set(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:@!$&'()*+,;="
    )
    var result = ""
    result.reserveCapacity(value.count)
    for char in value {
      if allowed.contains(char) {
        result.append(char)
      } else {
        for byte in String(char).utf8 {
          result += String(format: "%%%02X", byte)
        }
      }
    }
    return result
  }
}

// MARK: - TimeAmount Extension

extension TimeAmount {
  static func hours(_ hours: Int64) -> TimeAmount {
    .seconds(hours * 3600)
  }
}
