#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Project-level settings loaded from `.agentc/settings.json`.
///
/// Place this file in your project root (or any ancestor directory) to set defaults
/// for `agentc` invocations within the project tree.  All fields are optional;
/// only the values you specify take effect.
public struct ProjectSettings: Codable, Sendable, Equatable {
  public var agent: AgentSettings?

  public init(agent: AgentSettings? = nil) {
    self.agent = agent
  }

  public struct AgentSettings: Codable, Sendable, Equatable {
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

    public init(
      image: String? = nil,
      profile: String? = nil,
      excludes: [String]? = nil,
      configurations: [String]? = nil,
      additionalMounts: [String]? = nil,
      defaultArguments: [String]? = nil,
      additionalArguments: [String]? = nil,
      cpus: Int? = nil,
      memoryMiB: Int? = nil,
      bootstrap: String? = nil,
      respectImageEntrypoint: Bool? = nil
    ) {
      self.image = image
      self.profile = profile
      self.excludes = excludes
      self.configurations = configurations
      self.additionalMounts = additionalMounts
      self.defaultArguments = defaultArguments
      self.additionalArguments = additionalArguments
      self.cpus = cpus
      self.memoryMiB = memoryMiB
      self.bootstrap = bootstrap
      self.respectImageEntrypoint = respectImageEntrypoint
    }
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
        let settingsURL =
          dir
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
