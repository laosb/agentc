import Crypto
import Foundation

/// Resolve symlinks and handle macOS `/tmp`, `/var`, `/etc` → `/private/...` mapping.
func resolveSymlinksWithPrivate(_ url: URL) -> URL {
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
private func sha256Hex(_ string: String) -> String {
  let data = Data(string.utf8)
  let digest = SHA256.hash(data: data)
  return digest.map { String(format: "%02x", $0) }.joined()
}

/// Compute a path segment from a path string.
///
/// The segment format is `<lastComponent>-<last10sha>` where `lastComponent` is the
/// last path component and `last10sha` is the last 10 characters of the SHA-256 hex
/// digest of the full path.
public func pathSegment(for path: String) -> String {
  let name = URL(fileURLWithPath: path).lastPathComponent
  let hash = sha256Hex(path)
  return "\(name)-\(String(hash.suffix(10)))"
}

/// Compute the container workspace mount path for a given host workspace URL.
///
/// The path format is `/workspace/<folderName>-<last10sha>` where `folderName` is the
/// last path component of the canonical workspace path and `last10sha` is the last 10
/// characters of the SHA-256 hex digest of the full canonical path.
public func workspaceContainerPath(for workspace: URL) -> String {
  let canonical = resolveSymlinksWithPrivate(workspace)
  return "/workspace/\(pathSegment(for: canonical.path))"
}

/// Compute the legacy container workspace mount path for a given host workspace URL.
///
/// The legacy format is `/workspace/<sha256>` where the SHA-256 is the full hex digest
/// of the canonical workspace path.
public func legacyWorkspaceContainerPath(for workspace: URL) -> String {
  let canonical = resolveSymlinksWithPrivate(workspace)
  return "/workspace/\(sha256Hex(canonical.path))"
}
