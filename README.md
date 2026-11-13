# agentc

Run AI coding agents in isolated containers, with persistent profiles and per-project memory isolation.

Works with [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [OpenAI Codex CLI](https://learn.chatgpt.com/docs/codex/cli), [GitHub Copilot CLI](https://docs.github.com/en/copilot/github-copilot-in-the-cli), and other agents through [pluggable configurations](https://github.com/laosb/agent-isolation-configurations).

## Quick start

**Requirements:** macOS 15+ on Apple Silicon or Intel for Apple Containerization; or macOS/Linux on x64 or arm64 with a Docker Engine API v1.44+ compatible daemon (Docker or Podman in Docker-compatible mode).

Install the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/laosb/agentc/main/install.sh | sh
```

From your project directory, launch Claude Code (the default):

```sh
agentc run
```

Choose another agent or pass a prompt:

```sh
agentc run -c codex
agentc run -c copilot
agentc run -- "explain this code"
```

Keep separate profiles, save project defaults, or open a container shell:

```sh
agentc run -p work
agentc init -c codex
agentc sh
```

Use `agentc --help` or `agentc <subcommand> --help` for all options. See the [usage guide](docs/usage.md) for more examples.

## Features

- **Isolated execution** — run agents with Apple Containerization on macOS or a Docker-compatible runtime on macOS/Linux. Standard Docker containers share the host kernel; agentc prefers Kata Containers or gVisor when available. See [safer Docker isolation](docs/docker-runtimes.md).
- **Persistent profiles** — keep authentication, settings, MCP servers, and memory across sessions, with separate profiles for work and personal use.
- **Flexible agent choice** — switch or combine [agent configurations](https://github.com/laosb/agent-isolation-configurations) without rebuilding agentc.
- **Project defaults** — save agent, resource, environment, mount, and image preferences in [`.agentc/settings.json`](docs/project-settings.md).
- **Custom images and mounts** — use your preferred container image and share additional directories with the agent. See [images](docs/usage.md#use-a-different-image) and [mounts](docs/usage.md#share-additional-directories).
- **Editor and scripting support** — connect [ACP clients](docs/usage.md#connect-an-editor-through-acp) with automatic workspace mounts, or pipe agent output without mixing in setup logs.
- **Host tools, by explicit opt-in** — let containerized agents use [host commands](docs/host-bridge.md) or [host stdio MCP servers](docs/usage.md#use-host-only-mcp-tools). These commands run outside container isolation.
- **SOCKS5 networking** — on Apple Containerization, optionally route guest IPv4 TCP, UDP, and DNS through a proxy without configuring each application. See [scope and exceptions](docs/socks5-networking.md).
