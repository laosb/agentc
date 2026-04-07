import Foundation

/// Handles migration of Claude Code project data when workspace path format changes.
///
/// Claude Code stores per-project data in `~/.claude/projects/<encoded-path>/` where
/// the path is derived from the container workspace mount point. When claudec changes
/// its workspace naming scheme, this module detects legacy project folders and offers
/// the user a choice to migrate, remove, or abort.
enum WorkspaceMigration {

  /// Check for a legacy workspace project folder and prompt the user for migration.
  ///
  /// - Parameters:
  ///   - profileHomeDir: The host-side profile home directory (maps to /home/agent).
  ///   - legacyPath: The old container workspace path (e.g. `/workspace/<sha256>`).
  ///   - newPath: The new container workspace path (e.g. `/workspace/<name>-<hash10>`).
  /// - Throws: ``WorkspaceMigrationError/cancelled`` if the user chooses to quit.
  static func migrateIfNeeded(
    profileHomeDir: URL,
    legacyPath: String,
    newPath: String
  ) throws {
    let projectsDir =
      profileHomeDir
      .appendingPathComponent(".claude")
      .appendingPathComponent("projects")

    let legacyFolderName = encodeProjectFolderName(legacyPath)
    let legacyProjectDir = projectsDir.appendingPathComponent(legacyFolderName)

    guard FileManager.default.fileExists(atPath: legacyProjectDir.path) else {
      return
    }

    let newFolderName = encodeProjectFolderName(newPath)
    let newProjectDir = projectsDir.appendingPathComponent(newFolderName)

    // If new already exists too, nothing to do
    if FileManager.default.fileExists(atPath: newProjectDir.path) {
      return
    }

    // Prompt user
    FileHandle.standardError.write(
      Data(
        """
        claudec: Found Claude Code data using legacy workspace path.
          Old: \(legacyPath)
          New: \(newPath)

        Choose an action:
          [m] Migrate to new workspace path (recommended)
          [r] Remove old Claude Code data
          [q] Quit without changes

        Choice [m/r/q]: \n
        """.utf8))

    guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    else {
      throw WorkspaceMigrationError.cancelled
    }

    switch line {
    case "m", "migrate", "":
      try performMigration(
        from: legacyProjectDir, to: newProjectDir,
        oldPath: legacyPath, newPath: newPath
      )
      FileHandle.standardError.write(
        Data("claudec: Migrated workspace data to new path.\n".utf8))

    case "r", "remove":
      try FileManager.default.removeItem(at: legacyProjectDir)
      FileHandle.standardError.write(
        Data("claudec: Removed old workspace data.\n".utf8))

    case "q", "quit":
      throw WorkspaceMigrationError.cancelled

    default:
      throw WorkspaceMigrationError.cancelled
    }
  }

  // MARK: - Internal

  /// Encode a container path to Claude Code's project folder name.
  ///
  /// Claude Code stores per-project data in `~/.claude/projects/<encoded>/` where
  /// the encoding replaces `/` with `-` and `/.` sequences with `--`.
  /// Examples:
  ///   `/workspace/abc` → `-workspace-abc`
  ///   `/workspace/.hidden` → `-workspace--hidden`
  static func encodeProjectFolderName(_ containerPath: String) -> String {
    var result = ""
    for component in containerPath.split(separator: "/", omittingEmptySubsequences: true) {
      if component.hasPrefix(".") {
        result += "-" + String(component)
      } else {
        result += "-" + component
      }
    }
    return result
  }

  /// Migrate a Claude Code project folder from legacy to new workspace path.
  ///
  /// 1. Rename the project directory
  /// 2. Update `"cwd"` references in all `.jsonl` files (session history)
  private static func performMigration(
    from source: URL, to destination: URL, oldPath: String, newPath: String
  ) throws {
    try FileManager.default.moveItem(at: source, to: destination)

    let enumerator = FileManager.default.enumerator(
      at: destination,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )

    while let fileURL = enumerator?.nextObject() as? URL {
      guard fileURL.pathExtension == "jsonl" else { continue }

      guard var content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
      let original = content
      content = content.replacingOccurrences(of: oldPath, with: newPath)

      if content != original {
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
      }
    }
  }
}

enum WorkspaceMigrationError: LocalizedError {
  case cancelled

  var errorDescription: String? {
    switch self {
    case .cancelled:
      return "claudec: Operation cancelled by user."
    }
  }
}
