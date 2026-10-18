import AgentIsolation
import Foundation

extension BootstrapManager {
  static let mcpRelayArgument = "--agentc-mcp-stdio-relay-v1"

  /// The relay is the bootstrap itself, not a separately distributed executable.
  /// An explicit --bootstrap remains usable with --respect-image-entrypoint:
  /// only its relay mode is used in that case.
  static func resolveMCPRelay(options: SharedOptions, settings: ProjectSettings?) async throws
    -> URL
  {
    let binary: URL
    if let path = options.bootstrapScript ?? settings?.agent?.bootstrap {
      binary = URL(fileURLWithPath: path)
    } else {
      binary = try await resolveBootstrapBinary(verbose: options.verbose)
    }
    try validateMCPRelay(at: binary)
    return binary
  }

  static func validateMCPRelay(at binary: URL) throws {
    let bytes = try Data(contentsOf: binary, options: .mappedIfSafe)
    func integer(_ offset: Int, _ count: Int) -> UInt64 {
      (0..<count).reduce(0) { $0 | (UInt64(bytes[offset + $1]) << ($1 * 8)) }
    }
    let invalid = ACPError(
      "Host MCP bridging requires an updated, statically linked Linux agentc-bootstrap. "
        + "Install the matching bootstrap release or pass --bootstrap <static-binary>.")
    // Check the target architecture and absence of an ELF interpreter. A shell
    // script or dynamically linked binary cannot fulfill the minimal-image rule.
    guard bytes.count >= 64, bytes.prefix(6) == Data([0x7f, 0x45, 0x4c, 0x46, 2, 1]),
      integer(18, 2) == (HostArchitecture.label == "arm64" ? 183 : 62),
      bytes.range(of: Data(mcpRelayArgument.utf8)) != nil
    else { throw invalid }
    let offset = integer(32, 8)
    let size = integer(54, 2)
    let count = integer(56, 2)
    guard size >= 56, count > 0, offset <= UInt64(bytes.count),
      count * size <= UInt64(bytes.count) - offset
    else { throw invalid }
    for index in 0..<count {
      if integer(Int(offset + index * size), 4) == 3 { throw invalid }  // PT_INTERP
    }
  }
}
