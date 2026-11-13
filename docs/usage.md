# Using agentc

Start with the [installation and quick start](../README.md#quick-start).
Run the examples below from your project directory. Use `agentc <subcommand> --help` for all options.

## Choose an agent

Use `-c` to select an agent, and `--` to pass arguments to it:

```sh
agentc run -c codex
agentc run -c claude -- --model opus
```

To prepare multiple agents, separate their configurations with commas:

```sh
agentc run -c claude,copilot
```

This prepares both agents and launches Copilot. In general, the last configuration with a launch command wins.
Browse [available configurations](https://github.com/laosb/agent-isolation-configurations) for more agents.

## Keep work and personal profiles separate

Profiles remember your agent logins, settings, memory, and MCP servers between runs:

```sh
agentc run -p work
agentc run -p personal
agentc profiles
```

Profiles live in `~/.agentc/profiles/`. To use another location, pass `--profile-dir ~/my-agent-profile`.

## Save project defaults

Set your preferred agent and resources once:

```sh
agentc init -c codex --cpus 4 --memory-mib 4096
agentc run
```

`init` saves defaults in `.agentc/settings.json` and prepares the environment.
CLI flags override saved defaults; additional mounts and exclusions are combined.
See [project settings](project-settings.md) for all options.

## Use a different image

Choose an image with the tools your project needs:

```sh
agentc run -i debian:latest
agentc run -i my-custom-image:latest
```

agentc supplies `curl`, `jq`, and `ripgrep` when the image doesn't include them.

## Share additional directories

Your project is available inside the container. Add other directories explicitly:

```sh
agentc run --additional-mount ~/shared
```

By default, shared directories appear under `/workspace`. If a tool needs the same absolute paths inside and outside the container, add `--mount-path-scheme host`.

## Use agentc in scripts

Pass a prompt or shell command after `--`:

```sh
agentc run -- "summarize this project" > summary.txt
agentc sh -- ls -la /home/agent
```

Agent and command output goes to stdout; agentc setup messages and diagnostics go to stderr, so they won't appear in redirected output.

## Connect an editor through ACP

In your ACP-compatible editor, use `agentc` as the command with these arguments:

```text
acp -c claude-acp -i swift:6.4
```

The editor chooses the project directory. agentc loads that project's settings and starts an isolated agent for it.

- **Set the agent and image in the editor's command**, as above, rather than relying only on project settings.
- **Limit project access** with `--workspace /Users/me/Developer`. Explicit additional mounts can still be outside that folder.
- **Share extra folders explicitly** with `--additional-mount` or project settings. Mentioning a path in a prompt does not mount it.
- **Restart the agentc connection after changing settings or mounts.** Existing workspace agents keep their original settings.
- **Using a different profile per project?** Make sure each profile is already authenticated.

### Use host-only MCP tools

For tools such as Xcode's `mcpbridge`, add `--bridge-host-stdio-mcp` to the ACP command:

```sh
agentc acp -c claude-acp -i swift:6.4 --bridge-host-stdio-mcp
```

**This lets the ACP client run commands as your host user, outside container isolation.**

- Off by default. Project settings can also enable it with `agent.acp.bridgeHostStdioMcp`.
- For untrusted projects, pass `--no-bridge-host-stdio-mcp` to override their settings.
- `--workspace` does not restrict host MCP commands.
- Use only local container runtimes and trusted local networks: the bridge connection is not encrypted. Your host firewall must allow it.

For other host commands, see [host binary mappings](host-bridge.md).

## Troubleshoot a session

Capture debug logs when startup or an agent fails:

```sh
agentc run --verbose --log-file agentc.log
```

For ACP connection problems, also capture the conversation between the editor and agent:

```sh
agentc acp -c claude-acp -i swift:6.4 \
  --log-file agentc.log --stdio-log-file stdio.log
```

Log files are appended to on each run; their parent directories must exist.
Session transcripts can contain prompts, code, and credentials—review them before sharing.
