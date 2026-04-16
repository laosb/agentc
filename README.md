# agentc

Run AI coding agents in isolated containers with persistent profiles and per-project memory isolation.

Supports [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [GitHub Copilot CLI](https://gh.io/copilot-install), and more — with pluggable agent configurations via the [agent-isolation-configurations](https://github.com/laosb/agent-isolation-configurations) repo. Contributions for additional agents are welcome!

Available container runtimes: [Apple Containerization](https://apple.github.io/containerization/) (macOS) and Docker (macOS/Linux).

## Install

### Prerequisites

**macOS (Apple Container runtime):** macOS 15+, Apple Silicon or Intel.

**macOS / Linux (Docker runtime):** x64 or arm64, Docker Engine API v1.44+ (Docker, Podman with Docker compatibility, etc.).

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/laosb/agentc/main/install.sh | sh
```

This detects your platform, downloads the latest release from GitHub, and installs to `~/.agentc/bin/` with a symlink in `~/.local/bin/`.

## Quick Start

```sh
agentc run                          # start default agent (claude) in $PWD
agentc run -c claude,copilot        # activate multiple configurations
agentc run "explain this code"      # forward args to the agent entrypoint
agentc sh                           # open a shell in the container
agentc sh -- ls -la /home/agent     # run a command inside the container
agentc version                      # print version info
```

On first run, `agentc` clones the [agent-isolation-configurations](https://github.com/laosb/agent-isolation-configurations) repo and runs each configuration's `prepare.sh` to install required tools. Subsequent runs reuse the existing install.

Use `agentc --help` and `agentc <subcommand> --help` for full CLI reference.

### Profiles

A profile is a persistent `/home/agent` directory that survives container restarts — keeping agent auth, memory, settings, and MCP servers.

```sh
agentc run -p work                  # use a named profile
agentc run --profile-dir ~/my-prof  # use a custom directory
```

Profiles are stored at `~/.agentc/profiles/<name>/home/`.

### Configurations

Agent configurations are modular setup recipes. Each configuration provides a `prepare.sh` script, optional additional PATH entries, and an entrypoint command. The last configuration's entrypoint is used.

```sh
# makes sure both Claude Code + GitHub Copilot CLI installed, but invokes GitHub Copilot CLI
agentc run -c claude,copilot

# just GitHub Copilot CLI
agentc run -c copilot
```

### Project Settings

Place a `.agentc/settings.json` file in your project root to set default agent options for the project. 

```json
{
  "agent": {
    "image": "ghcr.io/my-org/dev:latest",
    "configurations": ["claude"],
    "cpus": 4,
    "memoryMiB": 4096,
    "excludes": [".git", "secrets"]
  }
}
```

CLI flags override project settings; some fields (like `excludes` and `additionalMounts`) are merged. 

See [docs/project-settings.md](./docs/project-settings.md) for the full schema and override rules.

### Container Images

`agentc` works with any standard container image — it automatically sets up the agent user, sudo, and required tools at container start via an embedded bootstrap script. The default image is pre-configured for faster startup, but you can use any base image:

```sh
agentc run -i debian:latest               # stock Debian
agentc run -i alpine:latest               # Alpine Linux
agentc run -i buildpack-deps:scm          # Debian + git, curl, etc.
agentc run -i my-custom-image:latest      # your own image
```

To skip the bootstrap and use the image's own entrypoint:

```sh
agentc run --respect-image-entrypoint -i my-image:latest
```

## Architecture

```
agentc (CLI)
  └─ AgentIsolation                          (runtime-agnostic orchestration)
  └─ AgentIsolationAppleContainerRuntime     (Apple Containerization, macOS)
  └─ AgentIsolationDockerRuntime             (Docker Engine API, macOS/Linux)
```

`AgentIsolation` depends only on Foundation and [swift-crypto](https://github.com/apple/swift-crypto). Runtime backends are conditionally compiled via Swift package traits.

The `agentc-bootstrap` binary is a standalone statically linked Linux executable that runs as the container entrypoint. It creates `agent` user and does the rest of agent initialization as needed. It is distributed as a separate release artifact and installed alongside the `agentc` binary.

## Development

Swift 6.1+. Tested on Swift 6.3.

```sh
swift build                                    # debug build (default traits)
swift build --traits ContainerRuntimeDocker    # Docker-only
swift test --filter AgentIsolationTests        # unit tests
./build.sh                                     # release build + codesign
./build.sh --runtimes docker                   # Docker-only release
```

Set `BUILD_VERSION` and `BUILD_GIT_SHA` environment variables before `build.sh` to inject version info into the `agentc version` output.

### Bootstrap binary

The `agentc-bootstrap` binary is the container entrypoint. It must be built separately as a statically linked Linux binary:

```sh
# Build for the current architecture (requires Static Linux SDK)
swift build --product agentc-bootstrap -c release --swift-sdk x86_64-swift-linux-musl   # x64
swift build --product agentc-bootstrap -c release --swift-sdk aarch64-swift-linux-musl  # arm64

# Install to the expected location
mkdir -p ~/.agentc/bin
cp .build/<sdk>/release/agentc-bootstrap ~/.agentc/bin/bootstrap
```

For released versions, `agentc` automatically downloads the matching bootstrap binary on first run. During development, you can also use `--bootstrap <path>` to specify a custom bootstrap binary or shell script, or `--respect-image-entrypoint` to skip the bootstrap entirely.

## Migrating from claudec

The `claudec` CLI was removed in v1.0.0-alpha.8. To migrate your profiles and configurations:

```sh
agentc migrate-from-claudec
```

If you have scripts or muscle memory that use the `claudec` command, you can set up a shell alias:

```sh
# bash / zsh
alias claudec='agentc run --'

# fish
alias claudec 'agentc run --'
```

## License

[MIT License](./LICENSE).
