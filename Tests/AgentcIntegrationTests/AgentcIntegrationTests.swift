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

  @Test("agentc forwards non-zero container exit codes (session start+wait)")
  func nonZeroExitCodeFlow() async throws {
    // Exercises the AgentSession.start() + wait() path end-to-end: a
    // container that exits with code 42 should cause agentc to exit 42.
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        // ShellCommand joins the argv with spaces and runs it via `bash -c`,
        // so passing `["exit", "42"]` lands as `bash -c "exit 42"` (builtin).
        "--", "exit", "42",
      ]
    )
    print(
      "DIAG nonZeroExitCodeFlow: exitCode=\(result.exitCode) stdout=\(result.stdout.prefix(200)) stderr=\(result.stderr.prefix(200))"
    )
    #expect(result.exitCode == 42)
  }

  @Test("agentc sh -- echo runs command in container")
  func shCommand() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
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
        "--configurations-dir", sharedConfigurationsDir,
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
        "--configurations-dir", sharedConfigurationsDir,
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
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--", "cat", "/home/agent/sentinel.txt",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("sentinel_agentc"))
  }

  @Test("dependsOn activates the dependency first and inherits its entrypoint")
  func dependsOnConfiguration() async throws {
    let dir = URL(fileURLWithPath: "/tmp/__TEST_agentc_dependson.\(UUID().uuidString.prefix(6))")
    let homeDir = dir.appendingPathComponent("home")
    try stubProfileHome(at: homeDir)
    defer { try? FileManager.default.removeItem(at: dir) }

    // `toolchain` prepares a marker and owns the entrypoint that prints it;
    // `myagent` only depends on it, so both must run — dependency first.
    let configsDir = dir.appendingPathComponent("configurations")
    let fm = FileManager.default
    let toolchainDir = configsDir.appendingPathComponent("toolchain")
    try fm.createDirectory(at: toolchainDir, withIntermediateDirectories: true)
    try #"{"v":0,"entrypoint":["/bin/cat","/home/agent/dependsOn-marker"]}"#.write(
      to: toolchainDir.appendingPathComponent("settings.json"),
      atomically: true, encoding: .utf8)
    let prepareScript = toolchainDir.appendingPathComponent("prepare.sh")
    try "#!/bin/sh\necho dependency_prepared > /home/agent/dependsOn-marker\n".write(
      to: prepareScript, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: prepareScript.path)

    let myAgentDir = configsDir.appendingPathComponent("myagent")
    try fm.createDirectory(at: myAgentDir, withIntermediateDirectories: true)
    try #"{"v":0,"dependsOn":["toolchain"]}"#.write(
      to: myAgentDir.appendingPathComponent("settings.json"),
      atomically: true, encoding: .utf8)

    // Look like a freshly pulled clone so ensureRepo neither clones nor pulls.
    try fm.createDirectory(
      at: configsDir.appendingPathComponent(".git"), withIntermediateDirectories: true)
    _ = fm.createFile(
      atPath: configsDir.appendingPathComponent(".agentc-last-pull").path, contents: nil)

    let result = await runAgentc(
      args: [
        "run",
        "--profile-dir", dir.path,
        "--configurations-dir", configsDir.path,
        "--no-update-image",
        "-c", "myagent",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("dependency_prepared"))
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
        "--configurations-dir", sharedConfigurationsDir,
        "--workspace", ws.path,
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
        "--configurations-dir", sharedConfigurationsDir,
        "--workspace", ws.path,
        "--no-update-image",
        "--", "pwd",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains(containerPath))
  }

  @Test("--mount-path-scheme host preserves the workspace path and working directory")
  func hostMountPathScheme() async throws {
    let ws = URL(fileURLWithPath: "/tmp/__TEST_agentc_hostws.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    try "host_scheme_content".write(
      to: ws.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: ws) }

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--workspace", ws.path,
        "--mount-path-scheme", "host",
        "--no-update-image",
        "--", "printf '%s|' \"$PWD\"; cat probe.txt",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout == "\(ws.path)|host_scheme_content")
  }

  @Test("--mount-path-scheme host applies to --additional-mount")
  func hostSchemeAdditionalMount() async throws {
    let shared = URL(fileURLWithPath: "/tmp/__TEST_agentc_hostmnt.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    try "additional_host_content".write(
      to: shared.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: shared) }

    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--mount-path-scheme", "host",
        "--additional-mount", shared.path,
        "--no-update-image",
        "--", "cat", "\(shared.path)/probe.txt",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout == "additional_host_content")
  }

  @Test("--exclude hides sub-folder contents")
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
        "--configurations-dir", sharedConfigurationsDir,
        "--workspace", ws.path,
        "--exclude", "secret",
        "--no-update-image",
        "--", "ls", "\(containerPath)/secret",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  @Test("--bootstrap overrides entrypoint")
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
        "--configurations-dir", sharedConfigurationsDir,
        "--bootstrap", customBootstrap.path,
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
        "--configurations-dir", sharedConfigurationsDir,
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
        "--configurations-dir", sharedConfigurationsDir,
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
        "--configurations-dir", sharedConfigurationsDir,
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

  @Test("--configurations flag works for run")
  func configurationsFlag() async throws {
    let tempDir = URL(fileURLWithPath: "/tmp/__TEST_agentc_posconf.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configsDir = tempDir.appendingPathComponent("configurations")
    let localRepo = tempDir.appendingPathComponent("repo")

    try await createLocalConfigRepo(at: localRepo)

    // `agentc run --configurations claude` with custom configs dir/repo
    let result = await runAgentc(
      args: [
        "run",
        "--profile", sharedProfile,
        "--configurations-dir", configsDir.path,
        "--configurations-repo", localRepo.path,
        "--no-update-image",
        "--configurations", "claude",
        "echo", "configurations-ok",
      ],
      env: [:]
    )
    // The run command should forward "echo configurations-ok" to the entrypoint
    #expect(result.exitCode == 0)
  }

  @Test("--cpus flag is accepted and used")
  func cpuCountFlag() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--cpus", "2",
        "--", "nproc",
      ]
    )
    #expect(result.exitCode == 0)
    // nproc should report the number of CPUs we requested
    let reported = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(reported == "2")
  }

  @Test("--memory-mib flag is accepted")
  func memoryMiBFlag() async throws {
    // Use a distinct, recognizable limit (512 MiB = 536870912 bytes)
    let limitMiB = 512
    let limitBytes = limitMiB * 1024 * 1024
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--memory-mib", "\(limitMiB)",
        "--", "cat", "/sys/fs/cgroup/memory.max",
      ]
    )
    #expect(result.exitCode == 0)
    let reported = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(reported == "\(limitBytes)")
  }

  // MARK: - Short flag aliases

  @Test("-p short flag works as --profile alias")
  func shortProfile() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "-p", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--", "echo", "short-p",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("short-p"))
  }

  @Test("-w short flag works as --workspace alias")
  func shortWorkspace() async throws {
    let ws = URL(fileURLWithPath: "/tmp/__TEST_agentc_shortw.\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    try "short_w_content".write(
      to: ws.appendingPathComponent("probe.txt"),
      atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: ws) }

    let containerPath = workspaceContainerPath(for: ws)

    let result = await runAgentc(
      args: [
        "sh",
        "-p", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "-w", ws.path,
        "--no-update-image",
        "--", "cat", "\(containerPath)/probe.txt",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.output.contains("short_w_content"))
  }

  @Test("-c short flag works as --configurations alias")
  func shortConfigurations() async throws {
    let tempDir = URL(fileURLWithPath: "/tmp/__TEST_agentc_shortc.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configsDir = tempDir.appendingPathComponent("configurations")
    let localRepo = tempDir.appendingPathComponent("repo")

    try await createLocalConfigRepo(at: localRepo)

    let result = await runAgentc(
      args: [
        "run",
        "-p", sharedProfile,
        "--configurations-dir", configsDir.path,
        "--configurations-repo", localRepo.path,
        "--no-update-image",
        "-c", "claude",
        "echo", "short-c-ok",
      ],
      env: [:]
    )
    #expect(result.exitCode == 0)
  }

  // MARK: - Remaining arguments parsing

  @Test("sh command accepts arguments without -- separator")
  func shRemainingWithoutSeparator() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "echo", "no-separator",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("no-separator"))
  }

  @Test("run command accepts entrypoint arguments without -- separator")
  func runRemainingWithoutSeparator() async throws {
    let tempDir = URL(fileURLWithPath: "/tmp/__TEST_agentc_remain.\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configsDir = tempDir.appendingPathComponent("configurations")
    let localRepo = tempDir.appendingPathComponent("repo")

    try await createLocalConfigRepo(at: localRepo)

    let result = await runAgentc(
      args: [
        "run",
        "--profile", sharedProfile,
        "--configurations-dir", configsDir.path,
        "--configurations-repo", localRepo.path,
        "--no-update-image",
        "--configurations", "claude",
        "echo", "remaining-ok",
      ],
      env: [:]
    )
    #expect(result.exitCode == 0)
  }

  // MARK: - --verbose flag

  @Test("Non-TTY run reserves stdout for workload output")
  func nonTTYRunReservesStdout() async throws {
    let base = URL(fileURLWithPath: "/tmp/__TEST_agentc_stdout.\(UUID().uuidString.prefix(6))")
    let configDir = base.appendingPathComponent("configurations/stdout-test")
    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    try """
    {
      "v": 0,
      "entrypoint": ["/bin/sh", "-c", "printf workload-output"],
      "additionalMounts": [],
      "additionalBinPaths": []
    }
    """.write(
      to: configDir.appendingPathComponent("settings.json"),
      atomically: true,
      encoding: .utf8)

    let prepareScript = configDir.appendingPathComponent("prepare.sh")
    try """
    #!/bin/sh
    echo prepare-stdout
    echo prepare-stderr >&2
    """.write(to: prepareScript, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: prepareScript.path)

    let configurationsDir = base.appendingPathComponent("configurations")
    try FileManager.default.createDirectory(
      at: configurationsDir.appendingPathComponent(".git"), withIntermediateDirectories: true)
    _ = FileManager.default.createFile(
      atPath: configurationsDir.appendingPathComponent(".agentc-last-pull").path,
      contents: nil)

    let result = await runAgentc(
      args: [
        "run",
        "--verbose",
        "--profile", sharedProfile,
        "--configurations-dir", configurationsDir.path,
        "--configurations", "stdout-test",
        "--no-update-image",
        "--no-toolkit",
      ]
    )

    #expect(result.exitCode == 0)
    #expect(result.stdout == "workload-output")
    #expect(result.stderr.contains("==> Running prepare.sh"))
    #expect(result.stderr.contains("prepare-stdout"))
    #expect(result.stderr.contains("prepare-stderr"))
  }

  @Test("Without --verbose, bootstrap prepare.sh message is suppressed")
  func verboseSuppressed() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--", "echo", "ok",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(!result.stderr.contains("==> Running prepare.sh"))
  }

  @Test("With --verbose, bootstrap prepare.sh message is printed")
  func verbosePrinted() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "--verbose",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--", "echo", "ok",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stderr.contains("==> Running prepare.sh"))
  }

  @Test("-v short flag works as --verbose alias")
  func shortVerbose() async throws {
    let result = await runAgentc(
      args: [
        "sh",
        "-v",
        "--profile", sharedProfile,
        "--configurations-dir", sharedConfigurationsDir,
        "--no-update-image",
        "--", "echo", "ok",
      ]
    )
    #expect(result.exitCode == 0)
    #expect(result.stderr.contains("==> Running prepare.sh"))
  }
}
