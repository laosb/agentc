# agentc

Run AI coding agents in isolated containers with persistent profiles and per-project memory isolation.

Supports [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [ChatGPT Codex CLI](https://learn.chatgpt.com/docs/codex/cli), and more — with pluggable agent configurations via the [agent-isolation-configurations](https://github.com/laosb/agent-isolation-configurations) repo. Contributions for additional agents are welcome!

## Install

### Prerequisites

**macOS (Apple Container runtime):** macOS 15+, Apple Silicon or Intel.

**macOS / Linux (Docker runtime):** x64 or arm64, Docker Engine API v1.44+ (Docker, Podman with Docker compatibility, etc.).

> [!IMPORTANT]
> Standard Docker containers share the host kernel. Because agents run untrusted code,
> `agentc` automatically prefers Kata Containers or gVisor when available and warns when
> only standard `runc` isolation is available. See [*Safer Docker Isolation*](./docs/docker-runtimes.md).

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/laosb/agentc/main/install.sh | sh
```

## Quick Start

```sh
agentc run                          # start default agent (claude) in $PWD
agentc run -c codex                 # use a different agent configuration
agentc run "explain this code"      # forward args to the agent entrypoint
agentc run -e TZ=Europe/Berlin      # set a container environment variable
agentc sh                           # open a shell in the container
agentc sh -- ls -la /home/agent     # run a command inside the container
```

Use `agentc --help` and `agentc <subcommand> --help` for full CLI reference.

### Profiles

A profile contains a persistent `/home/agent` directory that survives container restarts — keeping agent auth, memory, settings, and MCP servers.

```sh
agentc run -p work                  # use a named profile
agentc run --profile-dir ~/my-prof  # use a custom directory
```

Profiles are stored at `~/.agentc/profiles/<name>/`.

### Configurations

Agent configurations are modular setup recipes. Each configuration provides a `prepare.sh` script and optional additional settings. A configuration may declare `dependsOn` to pull in other configurations, which are always activated before it. The last activated configuration that defines an entrypoint provides the command to run.

```sh
# makes sure both Claude Code + GitHub Copilot CLI installed, but invokes GitHub Copilot CLI
agentc run -c claude,copilot

# just GitHub Copilot CLI
agentc run -c copilot
```

### Toolkit

Every session mounts the **agentc Toolkit** read-only at `/agent-isolation/toolkit`: a
small set of static binaries — `curl`, `jq`, `ripgrep` — and a CA bundle. It exists so
agents always have some basic tools to work with even in `alpine`-like slim images.

The toolkit is designed in such a way that they would not override what the image itself
provides.

```sh
agentc run --no-toolkit                 # only what the image itself provides
agentc run --toolkit ~/my-toolkit       # a locally built bundle
```

The toolkit is versioned independently of agentc and downloaded once, to
`~/.agentc/toolkit/v<N>`. Its contents are defined by
[`scripts/toolkit/manifest.sh`](./scripts/toolkit/manifest.sh).

### Project Settings

Use `agentc init` to place a `.agentc/settings.json` file in your project root to set default agent options for the project. CLI flags override project settings; some fields (like `excludes` and `additionalMounts`) are merged. 

See [docs/project-settings.md](./docs/project-settings.md) for the full schema and override rules.

### Container Images

`agentc` works with any standard container image — it automatically sets up the agent user, sudo, and required tools at container start via an embedded bootstrap script. Images that ship no tooling of their own are covered by the [toolkit](#toolkit). The default image is pre-configured for faster startup, but you can use any base image:

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

### Docker Isolation

Agents run code you did not write, so on the Docker backend `agentc` asks the daemon which
runtimes it has and prefers the strongest isolation available: **Kata Containers** (a VM per
container) over **gVisor** (`runsc`) over **`runc`** (shares the host kernel). If only `runc`
is available, `agentc` uses it and prints a warning with setup instructions.

Pick one yourself — including `runc`, which also silences the warning:

```sh
agentc run --docker-runtime runsc
agentc run --docker-runtime runc     # "I know, runc is fine here"
```

See [Safer Docker Isolation](./docs/docker-runtimes.md). The Apple Container backend already
gives every container its own VM, so runtime selection applies only to the Docker backend.

## Architecture

```
agentc (CLI)
  └─ AgentIsolation                          (runtime-agnostic orchestration)
  └─ AgentIsolationAppleContainerRuntime     (Apple Containerization, macOS)
  └─ AgentIsolationDockerRuntime             (Docker Engine API, macOS/Linux)
agentc-bootstrap                             (In-container bootstrap program)
```

`AgentIsolation` depends only on Foundation and [swift-crypto](https://github.com/apple/swift-crypto). Runtime backends are conditionally compiled via Swift package traits.

The `agentc-bootstrap` binary is a standalone statically-linked Linux executable that runs as the container entrypoint. It creates `agent` user and does the rest of agent initialization as needed.

The agentc Toolkit is built separately from `scripts/toolkit/manifest.sh` and released on its own
schedule; see [Toolkit](#toolkit).

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

## License

[MIT License](./LICENSE).
