/// Build-time metadata injected by the build script / CI.
///
/// Default values are used for local development builds. The build script
/// overwrites this file with actual values when `BUILD_VERSION` and/or
/// `BUILD_GIT_SHA` environment variables are set.
enum BuildInfo {
  static let version = "dev"
  static let gitSHA = "unknown"
}
