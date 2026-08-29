import Foundation
import Testing

/// Guards on `scripts/toolkit/manifest.sh`, the file CI publishes the toolkit from.
///
/// The manifest is shell, not Swift, so nothing else in the build would notice a
/// typo in it — or notice it drifting away from the version `agentc` asks the
/// release server for. These read both files as text, which is also the only way
/// to reach `ToolkitManager` from here: it lives in an executable target.
@Suite("Toolkit manifest")
struct ToolkitManifestTests {
  private static let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AgentIsolationTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repository root

  private static func read(_ relativePath: String) throws -> String {
    try String(contentsOf: repositoryRoot.appending(path: relativePath), encoding: .utf8)
  }

  /// The `dest|arch|url|sha256|member` rows, without the surrounding shell.
  private static func contentRows(of manifest: String) -> [[String]] {
    manifest
      .split(separator: "\n")
      .map(String.init)
      .filter { $0.contains("|") && !$0.hasPrefix("#") }
      .map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
  }

  @Test("agentc asks for the version the manifest publishes")
  func versionsAgree() throws {
    let manifest = try Self.read("scripts/toolkit/manifest.sh")
    let source = try Self.read("Sources/agentc/ToolkitManager.swift")

    let declared = try #require(
      manifest.firstMatch(of: /TOOLKIT_VERSION=([0-9]+)/)?.1,
      "manifest.sh should declare TOOLKIT_VERSION")
    let expected = try #require(
      source.firstMatch(of: /static let version = "([^"]+)"/)?.1,
      "ToolkitManager should declare a version")

    #expect(
      String(declared) == String(expected),
      """
      scripts/toolkit/manifest.sh publishes toolkit v\(declared) but agentc \
      downloads v\(expected). The declarations must stay synchronized.
      """)
  }

  @Test("Every entry is pinned to an https URL and a SHA-256")
  func entriesArePinned() throws {
    let rows = Self.contentRows(of: try Self.read("scripts/toolkit/manifest.sh"))
    #expect(!rows.isEmpty)

    for row in rows {
      #expect(row.count == 5, "expected dest|arch|url|sha256|member, got \(row)")
      let (dest, arch, url, digest) = (row[0], row[1], row[2], row[3])

      #expect(url.hasPrefix("https://"), "\(dest): \(url) is not https")
      #expect(["x64", "arm64", "any"].contains(arch), "\(dest): unknown architecture '\(arch)'")
      #expect(digest.count == 64, "\(dest): \(digest) is not a SHA-256")
      #expect(
        digest.allSatisfy { "0123456789abcdef".contains($0) },
        "\(dest): \(digest) is not lowercase hex")
      #expect(!dest.contains(".."), "\(dest): destinations stay inside the bundle")
    }
  }

  @Test("Every tool is available on both architectures")
  func everyToolCoversBothArchitectures() throws {
    let rows = Self.contentRows(of: try Self.read("scripts/toolkit/manifest.sh"))
    let architectures = Dictionary(grouping: rows, by: { $0[0] })
      .mapValues { Set($0.map { $0[1] }) }

    for (dest, archs) in architectures {
      // A container gets exactly one bundle, so anything missing for an
      // architecture is simply absent for every session running on it.
      #expect(
        archs == ["any"] || archs == ["x64", "arm64"],
        "\(dest) is built for \(archs.sorted()) — it needs both, or 'any'")
    }
  }
}
