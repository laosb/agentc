#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The subset of an agent configuration's `settings.json` that the host needs.
///
/// The container-side bootstrap reads the same file for `entrypoint` and
/// `additionalBinPaths`; those only matter inside the container.
struct AgentConfigurationSettings: Decodable, Sendable {
  var dependsOn: [String]?
  var additionalMounts: [String]?

  /// Load a configuration's settings, or `nil` when it is absent or unreadable.
  static func load(name: String, in directory: URL) -> AgentConfigurationSettings? {
    let url =
      directory
      .appendingPathComponent(name)
      .appendingPathComponent("settings.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(AgentConfigurationSettings.self, from: data)
  }
}

/// Errors surfaced while expanding agent configuration dependencies.
public enum AgentConfigurationError: Error, Sendable, Equatable {
  /// A `dependsOn` chain loops back on itself. The payload is the cycle path.
  case dependencyCycle([String])
}

/// Expands the `dependsOn` field of agent configurations into a flat, ordered list.
public enum AgentConfigurationResolver {
  /// Resolve the configurations to activate, in activation order.
  ///
  /// Each requested configuration is visited depth-first: its dependencies are
  /// emitted before it, so a configuration always follows everything it depends
  /// on and a requested configuration stays after its own dependencies. A name
  /// that appears more than once keeps its earliest position.
  ///
  /// Because the requested names are visited in order, the last requested
  /// configuration ends up last in the result — it is the one whose entrypoint
  /// the bootstrap execs — unless a later configuration depends on it.
  ///
  /// Configurations whose `settings.json` is missing or unreadable are passed
  /// through as-is; the container-side bootstrap reports them, since it sees the
  /// authoritative mounted copy.
  ///
  /// - Throws: ``AgentConfigurationError/dependencyCycle(_:)`` if `dependsOn` loops.
  public static func resolve(
    configurations requested: [String],
    in directory: URL
  ) throws -> [String] {
    var ordered: [String] = []
    var emitted: Set<String> = []
    var visiting: [String] = []

    func visit(_ name: String) throws {
      guard !emitted.contains(name) else { return }
      if let start = visiting.firstIndex(of: name) {
        throw AgentConfigurationError.dependencyCycle(Array(visiting[start...]) + [name])
      }

      visiting.append(name)
      let settings = AgentConfigurationSettings.load(name: name, in: directory)
      for dependency in settings?.dependsOn ?? [] {
        let dependency = dependency.trimmingWhitespace()
        guard !dependency.isEmpty else { continue }
        try visit(dependency)
      }
      visiting.removeLast()

      emitted.insert(name)
      ordered.append(name)
    }

    for name in requested {
      let name = name.trimmingWhitespace()
      guard !name.isEmpty else { continue }
      try visit(name)
    }
    return ordered
  }
}

extension String {
  /// Trim leading and trailing whitespace.
  ///
  /// Hand-rolled because `CharacterSet` is unavailable in `FoundationEssentials`.
  func trimmingWhitespace() -> String {
    var slice = self[...]
    while slice.first?.isWhitespace == true { slice = slice.dropFirst() }
    while slice.last?.isWhitespace == true { slice = slice.dropLast() }
    return String(slice)
  }
}
