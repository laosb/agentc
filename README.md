# agentc

Run AI coding agents in isolated containers with persistent profiles and per-project memory isolation.

Supports [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [GitHub Copilot CLI](https://gh.io/copilot-install), and more — with pluggable agent configurations via the [agent-isolation-configurations](https://github.com/laosb/agent-isolation-configurations) repo. Contributions for additional agents are welcome!

Available container runtimes: [Apple Containerization](https://apple.github.io/containerization/) (macOS) and Docker (macOS/Linux).

## Install

### Prerequisites

**macOS (Apple Container runtime):** macOS 15+, Apple Silicon or Intel.

**macOS / Linux (Docker runtime):** x64 or arm64, Docker Engine API v1.44+ (Docker, Podman with Docker compatibility, etc.).

### From GitHub Releases

```sh
tar xzf agentc-<arch>-<os>.tar.gz
sudo mv agentc /usr/local/bin/
```

macOS builds include both runtimes. Linux builds support Docker only. A `-static` flavor is available for Linux distros not officially supported by Swift.

## Quick Start

```sh
agentc run                          # start default agent (claude) in $PWD
agentc run claude,copilot           # activate multiple configurations
agentc run -- "explain this code"   # forward args to the agent entrypoint
agentc sh                           # open a shell in the container
agentc sh -- ls -la /home/agent     # run a command inside the container
agentc version                      # print version info
```

On first run, `agentc` clones the [agent-isolation-configurations](https://github.com/laosb/agent-isolation-configurations) repo and runs each configuration's `prepare.sh` to install required tools. Subsequent runs reuse the existing install.

Use `agentc --help` and `agentc <subcommand> --help` for full CLI reference.

### Profiles

A profile is a persistent `/home/agent` directory that survives container restarts — keeping agent auth, memory, settings, and MCP servers.

```sh
agentc run --profile work           # use a named profile
agentc run --profile-dir ~/my-prof  # use a custom directory
```

Profiles are stored at `~/.claudec/profiles/<name>/home/`.

### Configurations

Agent configurations are modular setup recipes. Each configuration provides a `prepare.sh` script, optional additional PATH entries, and an entrypoint command. The last configuration's entrypoint is used.

```sh
agentc run -c claude                # just Claude Code
agentc run -c claude,copilot        # Claude Code + GitHub Copilot CLI
agentc run copilot                  # just GitHub Copilot CLI
```

## Architecture

```
agentc / claudec (CLI)
  └─ AgentIsolation                          (runtime-agnostic orchestration)
  └─ AgentIsolationAppleContainerRuntime     (Apple Containerization, macOS)
  └─ AgentIsolationDockerRuntime             (Docker Engine API, macOS/Linux)
```

`AgentIsolation` depends only on Foundation and [swift-crypto](https://github.com/apple/swift-crypto). Runtime backends are conditionally compiled via Swift package traits.

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

## Legacy: claudec

The original `claudec` CLI is still included for backward compatibility. It uses environment variables for configuration. See [docs/CLAUDEC_README.md](./docs/CLAUDEC_README.md) for its documentation.

## License

[MIT License](./LICENSE).
