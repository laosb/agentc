/// The architecture label agentc uses in release asset names.
///
/// Containers run at the host's architecture, so the same label picks both the
/// bootstrap binary and the toolkit bundle.
enum HostArchitecture {
  static var label: String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x64"
    #else
      return "unknown"
    #endif
  }
}
