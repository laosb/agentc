import Foundation
import Subprocess
import Testing

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

/// A toolkit bundle built from the manifest in this checkout.
///
/// Built rather than downloaded so the tests cover the manifest as it stands in
/// the branch, not the last one that happened to be released. `nil` when the
/// build fails (no network, no `xz`), which skips the suite instead of failing it.
let sharedToolkitDir: String? = {
  let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let output = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("agentc-toolkit-tests")
  let staged = output.appendingPathComponent("toolkit")

  if FileManager.default.fileExists(atPath: staged.appendingPathComponent("TOOLKIT").path) {
    return staged.path
  }

  let script = repoRoot.appendingPathComponent("scripts/toolkit/build-toolkit.sh")
  let archive = output.appendingPathComponent(
    "agentc-toolkit-\(hostArchLabel())-linux-static.tar.gz")

  do {
    try? FileManager.default.removeItem(at: output)
    try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
    guard try runSync(script.path, ["--output", output.path]) else { return nil }
    guard try runSync("/usr/bin/env", ["tar", "xzf", archive.path, "-C", staged.path]) else {
      return nil
    }
    return staged.path
  } catch {
    return nil
  }
}()

private func hostArchLabel() -> String {
  #if arch(arm64)
    return "arm64"
  #else
    return "x64"
  #endif
}

private func runSync(_ executable: String, _ arguments: [String]) throws -> Bool {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  return process.terminationStatus == 0
}

/// End-to-end coverage for the agentc Toolkit.
///
/// The guarantee under test is not just "curl exists" but where it sits: the
/// toolkit fills in what an image lacks and never displaces what it has.
@Suite("Toolkit Integration Tests", .enabled(if: sharedToolkitDir != nil))
struct ToolkitIntegrationTests {
  init() {
    _ = sharedProfile
  }

  private func run(image: String, command: String, toolkit: Bool = true) async -> ProcessOutput {
    var args = [
      "sh",
      "--profile", sharedProfile,
      "--configurations-dir", sharedConfigurationsDir,
      "--image", image,
      "--no-update-image",
    ]
    if toolkit {
      args += ["--toolkit", sharedToolkitDir!]
    } else {
      args += ["--no-toolkit"]
    }
    // `agentc sh` joins what follows into a single `bash -c` string.
    return await runAgentc(args: args + ["--", command])
  }

  @Test("Fills in tools an image does not ship")
  func providesMissingTools() async throws {
    // debian:latest carries none of these.
    let result = await run(
      image: "docker.io/library/debian:latest",
      command: "command -v curl jq rg && curl --version | head -1 && rg --version | head -1")

    #expect(result.exitCode == 0)
    #expect(result.output.contains("/agent-isolation/toolkit/bin/curl"))
    #expect(result.output.contains("/agent-isolation/toolkit/bin/jq"))
    #expect(result.output.contains("/agent-isolation/toolkit/bin/rg"))
    #expect(result.output.contains("curl 8."))
    #expect(result.output.contains("ripgrep"))
  }

  @Test("Never displaces a tool the image already has")
  func imageToolsWin() async throws {
    // buildpack-deps:scm ships its own curl, and it must stay the one that runs.
    let result = await run(
      image: "docker.io/library/buildpack-deps:scm",
      command: "command -v curl")

    #expect(result.exitCode == 0)
    #expect(result.output.contains("/usr/bin/curl"))
    #expect(!result.output.contains("/agent-isolation/toolkit/bin/curl"))
  }

  @Test("Leaves the container untouched when asked not to mount")
  func noToolkitFlag() async throws {
    let result = await run(
      image: "docker.io/library/debian:latest",
      command: "command -v rg || echo no-ripgrep",
      toolkit: false)

    #expect(result.exitCode == 0)
    #expect(result.output.contains("no-ripgrep"))
    #expect(!result.output.contains("/agent-isolation/toolkit"))
  }

  @Test("HTTPS works even on an image with no trust store")
  func httpsWorksWithoutSystemTrustStore() async throws {
    let result = await run(
      image: "docker.io/library/debian:latest",
      command: """
        if [ -e /etc/ssl/certs/ca-certificates.crt ] || [ -e /etc/ssl/cert.pem ]; then \
        echo image-has-store; else echo image-has-no-store; fi; \
        echo "cainfo=${CURL_CA_BUNDLE:-unset}"; \
        curl -fsS -o /dev/null -w 'status=%{http_code}\\n' https://github.com/
        """)

    #expect(result.exitCode == 0)
    #expect(result.output.contains("status=200"))

    // The bundled roots are a fallback, not an override: whichever branch the
    // image falls into, the variable must agree with it.
    if result.output.contains("image-has-no-store") {
      #expect(result.output.contains("cainfo=/agent-isolation/toolkit/share/ca-certificates.crt"))
    } else {
      #expect(result.output.contains("cainfo=unset"))
    }
  }
}
