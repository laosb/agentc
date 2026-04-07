import Foundation

/// Creates a local git repo mimicking agent-isolation-configurations with a
/// minimal `claude` configuration (no-op prepare, no additional bin paths).
func createLocalConfigRepo(at repoDir: URL) throws {
  let fm = FileManager.default
  let claudeDir = repoDir.appendingPathComponent("claude")
  try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

  try """
  {"v":0,"dependsOn":[],"additionalMounts":[],"additionalBinPaths":[],"entrypoint":["echo","config-ok"]}
  """.write(
    to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
  try "#!/bin/bash\n".write(
    to: claudeDir.appendingPathComponent("prepare.sh"), atomically: true, encoding: .utf8)

  for args: [String] in [
    ["init"],
    ["add", "."],
    ["-c", "user.email=test@test.com", "-c", "user.name=Test", "commit", "-m", "init"],
  ] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", repoDir.path] + args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      fatalError("git \(args.joined(separator: " ")) failed in createLocalConfigRepo")
    }
  }
}
