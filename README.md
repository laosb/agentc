# agentc

Run AI coding agents in isolated containers with persistent profiles and per-project memory isolation.

`agentc` works with [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [OpenAI Codex CLI](https://learn.chatgpt.com/docs/codex/cli), [GitHub Copilot CLI](https://docs.github.com/en/copilot/github-copilot-in-the-cli), and other agents through pluggable configurations from [agent-isolation-configurations](https://github.com/laosb/agent-isolation-configurations).

## Highlights

- **Isolated execution** — use Apple Containerization on macOS or a Docker-compatible runtime on macOS/Linux. On Docker, agentc prefers Kata Containers or gVisor over `runc` when available.
- **Persistent profiles** — keep agent authentication, settings, MCP servers, and memory across sessions without mixing every project into one workspace.
- **Pluggable agents** — switch or combine agent configurations without rebuilding agentc.
- **Bring your own image** — run on normal or minimal container images; the bootstrap and Toolkit provide the basics needed to get started.
- **Project-aware defaults** — store agent, resource, environment, mount, and image settings in `.agentc/settings.json`.

## Install

### Prerequisites

**macOS with Apple Containerization:** macOS 15+, Apple Silicon or Intel.

**macOS / Linux with Docker:** x64 or arm64, with a Docker Engine API v1.44+ compatible daemon such as Docker or Podman in Docker-compatible mode.

> [!IMPORTANT]
> Standard Docker containers share the host kernel. Because coding agents run code you did not write, agentc automatically prefers Kata Containers or gVisor when available and warns when only standard `runc` isolation is available. See [Safer Docker Isolation](./docs/docker-runtimes.md).

Install the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/laosb/agentc/main/install.sh | sh
```

## Quick start

Run the default agent, Claude Code, in the current directory:

```sh
agentc run
```

Choose another agent configuration or forward arguments to the agent:

```sh
agentc run -c codex
agentc run -c copilot
agentc run -c claude -- --model opus
agentc run -- "explain this code"
```

Open a shell in the same kind of isolated environment:

```sh
agentc sh
agentc sh -- ls -la /home/agent
```

Use `agentc --help` and `agentc <subcommand> --help` for the full CLI reference.

## Agent configurations

Agent configurations are modular setup recipes. They install or prepare an agent and can depend on other configurations.

Pass a comma-separated list with `-c` / `--configurations`:

```sh
# Prepare Claude Code and GitHub Copilot CLI, then launch Copilot.
agentc run -c claude,copilot
```

Configurations are activated in order; the last activated configuration that defines an entrypoint provides the command that runs. See [agent-isolation-configurations](https://github.com/laosb/agent-isolation-configurations) for the available configurations and their definitions.

## Persistent profiles

A profile keeps a persistent agent home directory across container restarts. Its `home` directory is mounted as `/home/agent`, so agent authentication, settings, memory, and MCP configuration survive between sessions.

```sh
agentc run -p work
agentc run -p personal

agentc profiles
agentc profiles list work

agentc run --profile-dir ~/my-agent-profile
```

Profiles are stored under `~/.agentc/profiles/<name>/`. You can also use a custom directory.

## Project settings

Initialize a project to create `.agentc/settings.json` and prepare its container environment:

```sh
agentc init
```

You can set useful defaults while initializing:

```sh
agentc init -c codex --cpus 4 --memory-mib 4096
```

CLI flags override project settings, while mergeable fields such as excludes and additional mounts are combined. See [Project Settings](./docs/project-settings.md) for the full schema and resolution rules.

## Container images and Toolkit

agentc can use any standard container image. By default, its bootstrap prepares the agent user and environment before launching the configured agent.

```sh
agentc run -i debian:latest
agentc run -i alpine:latest
agentc run -i buildpack-deps:scm
agentc run -i my-custom-image:latest
```

By default, agentc mounts an **agentc Toolkit** into the container, which provides `curl`, `jq`, `ripgrep` in `$PATH`, if they are not supplied by the image. This allows you to use coding agents on virtually any kind of Docker images.

## Workspaces and additional mounts

By default, host-backed paths use the `workspace` mount scheme: the project workspace and additional mounts receive stable destinations under `/workspace`.

```sh
agentc run --additional-mount ~/shared
```

When an editor, protocol, or script requires the same absolute path inside and outside the container, use the `host` scheme:

```sh
agentc run \
  --mount-path-scheme host \
  --additional-mount /Users/me/shared
```

The project default can be set with `agent.mountPathScheme` in `.agentc/settings.json`; the CLI flag overrides it.

## Scripted execution

For `agentc run` and `agentc sh`, stdout belongs to the launched workload. agentc progress, setup output, warnings, and verbose diagnostics go to stderr, including configuration `prepare.sh` output.

That makes non-interactive output safe to pipe or parse:

```sh
agentc run -- "summarize this project" > summary.txt
```

This allows you to use agentc to run stdio-based MCP or ACP. Automatic TTY behavior is preserved for interactive sessions.

## Development

Building agentc, running tests, creating static Linux binaries, and building `agentc-bootstrap` are documented in [BUILD.md](./BUILD.md).

## License

[MIT License](./LICENSE).
