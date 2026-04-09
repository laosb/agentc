import Foundation
import Testing

@Suite("agentc Integration Tests")
struct AgentcIntegrationTests {
  init() {
    _ = sharedProfile
  }

  @Test("agentc version prints version info")
  func versionCommand() async throws {
    let result = await runAgentc(args: ["version"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("agentc"))
  }

  @Test("agentc sh -- echo runs command in container")
  func shCommand() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--bootstrap-script", bootstrapScriptPath,
        "--no-update-image",
        "--", "echo", "hello",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("hello"))
  }

  @Test("agentc run with sh subcommand runs command")
  func runShSubcommand() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--bootstrap-script", bootstrapScriptPath,
        "--no-update-image",
        "--", "echo", "hello-from-sh",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("hello-from-sh"))
  }

  @Test("--profile creates profile dir at expected path")
  func profileFlag() async throws {
    let profile = "__TEST_agentc_profile_flag"
    let profileHome = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".agentc/profiles/\(profile)/home")
    try stubProfileHome(at: profileHome)
    defer { try? FileManager.default.removeItem(at: profileHome.deletingLastPathComponent()) }

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", profile,
        "--bootstrap-script", bootstrapScriptPath,
        "--no-update-image",
        "--", "echo", "ok",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: profileHome.path))
  }

  @Test("--profile-dir mounts custom home dir")
  func profileDirFlag() async throws {
    let dir = URL(fileURLWithPath: "/tmp/__TEST_agentc_profdir.\(UUID().uuidString.prefix(6))")
    let homeDir = dir.appendingPathComponent("home")
    try stubProfileHome(at: homeDir)
    try "sentinel_agentc".write(
      to: homeDir.appendingPathComponent("sentinel.txt"),
      atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = await runAgentc(
      args: [
        "sh",
        "--profile-dir", dir.path,
        "--bootstrap-script", bootstrapScriptPath,
        "--no-update-image",
        "--", "cat", "/home/agent/sentinel.txt",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("sentinel_agentc"))
  }

  @Test("--workspace mounts custom directory")
  func workspaceFlag() async throws {
    let ws = URL(fileURLWithPath: "/tmp/__TEST_agentc_ws.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    try "ws_content_agentc".write(
      to: ws.appendingPathComponent("probe.txt"),
      atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: ws) }

    let containerPath = workspaceContainerPath(for: ws)

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--workspace", ws.path,
        "--bootstrap-script", bootstrapScriptPath,
        "--no-update-image",
        "--", "cat", "\(containerPath)/probe.txt",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("ws_content_agentc"))
  }

  @Test("--workspace sets container working directory")
  func workspaceCwd() async throws {
    let ws = URL(fileURLWithPath: "/tmp/__TEST_agentc_cwd.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: ws) }

    let containerPath = workspaceContainerPath(for: ws)

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--workspace", ws.path,
        "--bootstrap-script", bootstrapScriptPath,
        "--no-update-image",
        "--", "pwd",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains(containerPath))
  }

  @Test("--exclude-folders hides sub-folder contents")
  func excludeFolders() async throws {
    let ws = URL(fileURLWithPath: "/tmp/__TEST_agentc_excl.\(UUID().uuidString.prefix(6))")
    let secretDir = ws.appendingPathComponent("secret")
    try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
    try "sensitive".write(
      to: secretDir.appendingPathComponent("data.txt"),
      atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: ws) }

    let containerPath = workspaceContainerPath(for: ws)

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--workspace", ws.path,
        "--exclude-folders", "secret",
        "--bootstrap-script", bootstrapScriptPath,
        "--no-update-image",
        "--", "ls", "\(containerPath)/secret",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  @Test("--bootstrap-script overrides entrypoint")
  func bootstrapScriptFlag() async throws {
    let customBootstrap = URL(
      fileURLWithPath: "/tmp/__TEST_agentc_bs.\(UUID().uuidString.prefix(6))")
    try """
    #!/bin/bash
    echo "custom_agentc_marker"
    if [ "${1:-}" = "/bin/bash" ]; then
        shift
        exec /bin/bash "$@"
    fi
    """.write(to: customBootstrap, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: customBootstrap.path)
    defer { try? FileManager.default.removeItem(at: customBootstrap) }

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--bootstrap-script", customBootstrap.path,
        "--no-update-image",
        "--", "echo", "ok",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("custom_agentc_marker"))
  }

  @Test("Bun is available on PATH inside the container")
  func bunOnPath() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--bootstrap-script", bootstrapScriptPath,
        "--no-update-image",
        "--", "command", "-v", "bun",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("bun"))
  }

  @Test("Container has /etc/hosts with localhost entries")
  func etcHosts() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--bootstrap-script", bootstrapScriptPath,
        "--no-update-image",
        "--", "cat", "/etc/hosts",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("127.0.0.1"))
    #expect(result.output.contains("localhost"))
  }

  @Test("Container runs with init process (PID 1 is not the entrypoint)")
  func initProcess() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--bootstrap-script", bootstrapScriptPath,
        "--no-update-image",
        "--", "cat", "/proc/1/cmdline",
      ]
    )
    #expect(result.exitCode == 0)
    // When init is enabled, PID 1 should be an init process
    // (docker-init on Docker, vminitd on Apple Container).
    let cmdline = result.output
    #expect(cmdline.contains("init"))
  }

  @Test("Positional configurations argument works for run")
  func positionalConfigurations() async throws {
    let tempDir = URL(fileURLWithPath: "/tmp/__TEST_agentc_posconf.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configsDir = tempDir.appendingPathComponent("configurations")
    let localRepo = tempDir.appendingPathComponent("repo")

    try createLocalConfigRepo(at: localRepo)

    // `agentc run claude` with custom configs dir/repo → uses the "claude" config from our local repo
    let result = await runAgentc(
      args: [
        "run",
        "--profile", sharedProfile,
        "--configurations-dir", configsDir.path,
        "--configurations-repo", localRepo.path,
        "--bootstrap-script", bootstrapScriptPath,
        "--no-update-image",
        "claude",
        "--", "echo", "positional-ok",
      ],
      env: [:]
    )
    // The run command should forward "echo positional-ok" to the entrypoint
    // Since we use bootstrap script, it goes through configurations processing
    #expect(result.exitCode == 0)
  }

  @Test("--cpu-count flag is accepted and used")
  func cpuCountFlag() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--bootstrap-script", bootstrapScriptPath,
        "--no-update-image",
        "--cpu-count", "2",
        "--", "nproc",
      ]
    )
    #expect(result.exitCode == 0)
    // nproc should report the number of CPUs we requested
    let reported = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(reported == "2")
  }

  @Test("--memory-limit-mib flag is accepted")
  func memoryLimitMiBFlag() async throws {
    // Use a distinct, recognizable limit (512 MiB = 536870912 bytes)
    let limitMiB = 512
    let limitBytes = limitMiB * 1024 * 1024
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--bootstrap-script", bootstrapScriptPath,
        "--no-update-image",
        "--memory-limit-mib", "\(limitMiB)",
        "--", "cat", "/sys/fs/cgroup/memory.max",
      ]
    )
    #expect(result.exitCode == 0)
    let reported = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(reported == "\(limitBytes)")
  }
}
