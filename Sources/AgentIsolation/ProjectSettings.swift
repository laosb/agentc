import Foundation

/// Project-level settings loaded from `.agentc/settings.json`.
///
/// Place this file in your project root (or any ancestor directory) to set defaults
/// for `agentc` invocations within the project tree.  All fields are optional;
/// only the values you specify take effect.
public struct ProjectSettings: Decodable, Sendable, Equatable {
  public var agent: AgentSettings?

  public struct AgentSettings: Decodable, Sendable, Equatable {
    public var image: String?
    public var profile: String?
    public var excludes: [String]?
    public var configurations: [String]?
    public var additionalMounts: [String]?
    public var defaultArguments: [String]?
    public var additionalArguments: [String]?
    public var cpus: Int?
    public var memoryMiB: Int?
    public var bootstrap: String?
    public var respectImageEntrypoint: Bool?
  }

  /// The folder names to probe at each directory level, in priority order.
  private static let folderNames = [".boite", ".agentc"]

  /// Searches upward from `startDir` for a settings file.
  ///
  /// At each directory level, checks for `settings.json` inside the candidate
  /// folders (in priority order).  Returns the first successfully decoded
  /// settings, or `nil` if the filesystem root is reached without a match.
  public static func find(from startDir: URL) -> ProjectSettings? {
    var dir = startDir.standardizedFileURL
    while true {
      for folderName in folderNames {
        let settingsURL = dir
          .appendingPathComponent(folderName)
          .appendingPathComponent("settings.json")
        if let settings = load(from: settingsURL) {
          return settings
        }
      }
      let parent = dir.deletingLastPathComponent()
      if parent.path == dir.path { break }
      dir = parent
    }
    return nil
  }

  /// Loads settings from a specific folder (e.g. the path given via `--agentc-folder`).
  public static func load(fromFolder folder: URL) -> ProjectSettings? {
    load(from: folder.appendingPathComponent("settings.json"))
  }

  /// Loads and decodes a settings file at the given URL.
  private static func load(from url: URL) -> ProjectSettings? {
    guard let data = try? Data(contentsOf: url),
      let settings = try? JSONDecoder().decode(ProjectSettings.self, from: data)
    else {
      return nil
    }
    return settings
  }
}
