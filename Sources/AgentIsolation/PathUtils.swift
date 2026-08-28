import Crypto

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public enum AgentIsolationPathUtils {
  /// Agent-owned mount destinations that host-path-preserving mounts must not replace.
  public static let reservedContainerMountPaths: Set<String> = [
    "/home/agent",
    "/agent-isolation/agents",
    "/agent-isolation/toolkit",
    "/entrypoint-bootstrap",
  ]

  /// Resolve symlinks with platform consideration.
  ///
  /// On macOS, `/tmp`, `/var`, `/etc` → `/private/...` mapping is applied.
  static func resolveSymlinksWithPlatformConsiderations(_ url: URL) -> URL {
    let resolved = url.resolvingSymlinksInPath()
    #if os(macOS)
      let parts = resolved.pathComponents
      if parts.count > 1, parts.first == "/",
        ["tmp", "var", "etc"].contains(parts[1])
      {
        if let withPrivate = NSURL.fileURL(
          withPathComponents: ["/", "private"] + parts[1...]
        ) {
          return withPrivate
        }
      }
    #endif
    return resolved
  }

  /// SHA-256 hex digest of a string.
  private static func sha256Hex(_ string: String) -> String {
    let data = Data(string.utf8)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Compute a path identifier from a path string.
  ///
  /// The identifier format is `<lastComponent>-<last10sha>` where `lastComponent` is the
  /// last path component and `last10sha` is the last 10 characters of the SHA-256 hex
  /// digest of the full path.
  public static func pathIdentifier(for path: String) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent
    let hash = sha256Hex(path)
    return "\(name)-\(String(hash.suffix(10)))"
  }

  /// Compute the container destination for a host-backed mount.
  ///
  /// The workspace scheme uses the canonical host path for its stable identifier.
  /// The host scheme standardizes the caller-visible absolute path without resolving
  /// symlinks, allowing the bind source and destination to intentionally differ.
  public static func containerMountPath(
    for hostPath: URL,
    scheme: MountPathScheme
  ) -> String {
    switch scheme {
    case .workspace:
      let canonical = resolveSymlinksWithPlatformConsiderations(hostPath)
      return "/workspace/\(pathIdentifier(for: canonical.path))"
    case .host:
      return lexicallyStandardizedAbsolutePath(hostPath.path)
    }
  }

  /// Standardize `.` and `..` path components without consulting the filesystem.
  ///
  /// `URL.standardizedFileURL` may resolve symlinks as part of standardization,
  /// which would change the caller-visible destination required by the host scheme.
  private static func lexicallyStandardizedAbsolutePath(_ path: String) -> String {
    var components: [Substring] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".":
        continue
      case "..":
        if !components.isEmpty { components.removeLast() }
      default:
        components.append(component)
      }
    }
    return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
  }

  /// Whether a host-preserving destination conflicts with agentc-owned container paths.
  public static func isReservedHostMountDestination(_ path: String) -> Bool {
    path == "/" || reservedContainerMountPaths.contains(path)
  }

  /// Compute the container workspace mount path for a given host workspace URL.
  ///
  /// The path format is `/workspace/<folderName>-<last10sha>` where `folderName` is the
  /// last path component of the canonical workspace path and `last10sha` is the last 10
  /// characters of the SHA-256 hex digest of the full canonical path.
  public static func workspaceContainerPath(for workspace: URL) -> String {
    containerMountPath(for: workspace, scheme: .workspace)
  }

  /// Compute the legacy container workspace mount path for a given host workspace URL.
  ///
  /// The legacy format is `/workspace/<sha256>` where the SHA-256 is the full hex digest
  /// of the canonical workspace path.
  public static func legacyWorkspaceContainerPath(for workspace: URL) -> String {
    let canonical = resolveSymlinksWithPlatformConsiderations(workspace)
    return "/workspace/\(sha256Hex(canonical.path))"
  }
}
