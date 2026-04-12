import Foundation
import Testing

/// Tests that agentc works with standard container images by using the
/// embedded bootstrap script to set up the agent user and environment.
@Suite("Base Image Integration Tests")
struct BaseImageIntegrationTests {
  init() {
    _ = sharedProfile
  }

  // MARK: - debian:latest

  @Test("Runs echo on debian:latest")
  func debianEcho() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--image", "docker.io/library/debian:latest",
        "--no-update-image",
        "--", "echo", "hello-from-debian",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("hello-from-debian"))
  }

  @Test("Agent user exists after bootstrap on debian:latest")
  func debianAgentUser() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--image", "docker.io/library/debian:latest",
        "--no-update-image",
        "--", "id",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("agent"))
  }

  // MARK: - alpine:latest

  @Test("Runs echo on alpine:latest")
  func alpineEcho() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--image", "docker.io/library/alpine:latest",
        "--no-update-image",
        "--", "echo", "hello-from-alpine",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("hello-from-alpine"))
  }

  @Test("Agent user exists after bootstrap on alpine:latest")
  func alpineAgentUser() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--image", "docker.io/library/alpine:latest",
        "--no-update-image",
        "--", "id",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("agent"))
  }

  // MARK: - buildpack-deps:scm

  @Test("Runs echo on buildpack-deps:scm")
  func buildpackEcho() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--image", "docker.io/library/buildpack-deps:scm",
        "--no-update-image",
        "--", "echo", "hello-from-buildpack",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("hello-from-buildpack"))
  }

  @Test("Agent user exists after bootstrap on buildpack-deps:scm")
  func buildpackAgentUser() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--image", "docker.io/library/buildpack-deps:scm",
        "--no-update-image",
        "--", "id",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("agent"))
  }

  @Test("git is available on buildpack-deps:scm")
  func buildpackGitAvailable() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--image", "docker.io/library/buildpack-deps:scm",
        "--no-update-image",
        "--", "git", "--version",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("git version"))
  }

  // MARK: - swift:6.3 (UID 1000 already used)

  @Test("Runs echo on swift:6.3")
  func swiftEcho() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--image", "docker.io/library/swift:6.3",
        "--no-update-image",
        "--", "echo", "hello-from-swift",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("hello-from-swift"))
  }

  @Test("Agent user exists and is functional after bootstrap on swift:6.3 (UID 1000 pre-used)")
  func swiftAgentUser() async throws {
    // swift:6.3 is Ubuntu-based and ships with UID 1000 already allocated,
    // so the bootstrap must assign a different UID to the agent user.
    // We only verify the user is named "agent" — not a specific UID.
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--image", "docker.io/library/swift:6.3",
        "--no-update-image",
        "--", "id",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("agent"))
  }

  @Test("Commands run as agent user on swift:6.3")
  func swiftWhoami() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--image", "docker.io/library/swift:6.3",
        "--no-update-image",
        "--", "whoami",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "agent")
  }

  // MARK: - --respect-image-entrypoint

  @Test("--respect-image-entrypoint skips bootstrap")
  func respectImageEntrypoint() async throws {
    // Our own image has no ENTRYPOINT after the Dockerfile rewrite,
    // so running with --respect-image-entrypoint on a plain image should
    // just pass args as CMD to the image (which for debian means /bin/bash).
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--image", "docker.io/library/debian:latest",
        "--respect-image-entrypoint",
        "--no-update-image",
        "--", "whoami",
      ]
    )
    // Without bootstrap, there's no agent user — runs as root
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("root"))
  }

  // MARK: - Workspace and profile mount on stock images

  @Test("Workspace is mounted and accessible on debian:latest")
  func debianWorkspace() async throws {
    let ws = URL(fileURLWithPath: "/tmp/__TEST_baseimg_ws.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    try "base_image_probe".write(
      to: ws.appendingPathComponent("probe.txt"),
      atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: ws) }

    let containerPath = workspaceContainerPath(for: ws)

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--workspace", ws.path,
        "--image", "docker.io/library/debian:latest",
        "--no-update-image",
        "--", "cat", "\(containerPath)/probe.txt",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("base_image_probe"))
  }
}
