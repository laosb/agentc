# claudec (Deprecated)

> **Note:** `claudec` is deprecated in favor of [`agentc`](../README.md). It remains functional for backward compatibility.

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside an isolated container with persistent profiles and per-project memory isolation.

Supports [Apple Containerization](https://apple.github.io/containerization/) on macOS and Docker on macOS/Linux.

> [!NOTE]
> If upgrading from the shell script version, see [MIGRATE_TO_V1.md](./MIGRATE_TO_V1.md).
>
> If you want to continue to use the shell script version (though it won't be maintained), see `archive-v0` branch.

## Install

### Prerequisites

**macOS (Apple Container runtime):**
- Apple Silicon or Intel Mac
- macOS 15+

**macOS / Linux (Docker runtime):**
- x64 or arm64 CPU
- A container runtime compatible with the Docker Engine API v1.44 (e.g. Docker, Podman with Docker compatibility API service.)

### From GitHub Releases

Download the binary for your platform from [Releases](https://github.com/laosb/claudec/releases):

```sh
tar xzf claudec-<arch>-<os>.tar.gz
sudo mv claudec /usr/local/bin/
```

macOS builds include both Apple Container and Docker runtime support. Linux builds only support Docker as runtime currently. New runtime and platform support is welcome!

For Linux environments, the normal build is expected to work on [distros directly supported by Swift](https://www.swift.org/platform-support/). If you are not using these officially supported distros, we also provide a `-static` flavor that have all dependencies statically linked and may have better compatibility.

## Usage

```sh
claudec                         # start Claude Code in $PWD
claudec "explain this codebase" # pass arguments to Claude Code
claudec sh                      # open a shell in the container
claudec sh ls -la /home/agent   # run a command inside the container
```

On first run, claudec clones the [agent-isolation-configurations](https://github.com/laosb/agent-isolation-configurations) repo and processes the configured agent configurations (default: `claude`). Each configuration has a `prepare.sh` that installs its required tools into the profile's home directory. Subsequent runs reuse the existing install. Customise configurations via `CLAUDEC_CONFIGURATIONS` or in the profile's `settings.json`.

### Profiles

A profile is a persistent `/home/agent` that survives container restarts — keeping Claude Code auth, memory, MCP servers, and settings.

```sh
CLAUDEC_PROFILE=work claudec        # use a named profile
export CLAUDEC_PROFILE=work         # or set for the whole session
```

Stored at `~/.claudec/profiles/<name>/home/`. You can also use `CLAUDEC_PROFILE_DIR` to specify a custom profile directory path instead.

### Project memory isolation

Each workspace is mounted at a deterministic path inside the container derived from the canonical host path. This ensures Claude Code keeps separate per-project memory even across symlinks or different relative paths to the same directory.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CLAUDEC_PROFILE` | `default` | Profile name (`~/.claudec/profiles/<name>/`). |
| `CLAUDEC_PROFILE_DIR` | *(derived)* | Full path to profile directory. Overrides `CLAUDEC_PROFILE`. |
| `CLAUDEC_IMAGE` | `ghcr.io/laosb/claudec:latest` | Container image reference. |
| `CLAUDEC_WORKSPACE` | `$PWD` | Host directory mounted as the workspace. |
| `CLAUDEC_CONFIGURATIONS` | *(from profile settings or `claude`)* | Comma-separated list of agent configuration names to activate. |
| `CLAUDEC_CONFIGURATIONS_DIR` | `~/.claudec/configurations` | Path to the local configurations directory. Overrides the default. |
| `CLAUDEC_CONFIGURATIONS_REPO` | `https://github.com/laosb/agent-isolation-configurations` | Git repo URL for agent configurations. |
| `CLAUDEC_CONFIGURATIONS_UPDATE_INTERVAL_SECONDS` | `86400` | Seconds between configuration repo update checks. |
| `CLAUDEC_IMAGE_AUTO_UPDATE` | `1` | Set `0` to skip pulling latest image before each run. |
| `CLAUDEC_IMAGE_AUTO_UPDATE_REMOVE_OLD` | `1` | Set `0` to keep old image after auto-update pulls a newer one. |
| `CLAUDEC_EXCLUDE_FOLDERS` | *(empty)* | Comma-separated workspace sub-folders to mask with empty read-only overlays (e.g. `node_modules,.git`). |
| `CLAUDEC_BOOTSTRAP_SCRIPT` | *(empty)* | Path to a custom entrypoint script, replacing the image default. |
| `CLAUDEC_CONTAINER_RUNTIME` | *(auto)* | Container runtime: `apple-container` or `docker`. Defaults to `apple-container` on macOS, `docker` on Linux. |
| `CLAUDEC_DOCKER_ENDPOINT` | `/var/run/docker.sock` | Docker Engine API endpoint. Unix socket path or `tcp://host:port`. Only used with the `docker` runtime. |

## Architecture

```
claudec (CLI)
  └─ AgentIsolation           (runtime-agnostic orchestration)
  └─ AgentIsolationAppleContainerRuntime  (Apple Containerization backend, macOS)
  └─ AgentIsolationDockerRuntime          (Docker Engine API backend, macOS/Linux)
```

`AgentIsolation` depends only on Foundation and [swift-crypto](https://github.com/apple/swift-crypto). Runtime backends are conditionally compiled via Swift package traits (`ContainerRuntimeAppleContainer`, `ContainerRuntimeDocker`). At least one runtime must be enabled at build time.

## Development

Swift 6.1 or later is required. Tested on Swift 6.3.

Use [`.github/workflows`](./.github/workflows) as a reference for build and test steps.

```sh
swift build                                    # debug build (default traits)
swift build --traits ContainerRuntimeDocker    # Docker-only build
swift test                                     # unit + integration tests
swift test --filter AgentIsolationTests        # unit tests only
swift test --filter AgentIsolationDockerRuntimeTests  # Docker runtime tests
./build.sh                                     # release build + codesign (macOS)
./build.sh --runtimes docker                   # Docker-only release build
```

### Building the container image

```sh
docker build -t claudec .
CLAUDEC_IMAGE=claudec claudec
```

# License
[MIT License](./LICENSE).
