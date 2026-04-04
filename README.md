# claudec

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
- Docker Engine installed and running

### From GitHub Releases

Download the binary for your platform from [Releases](https://github.com/laosb/claudec/releases):

| Platform | Artifact |
|---|---|
| macOS arm64 | `claudec-arm64-macos.tar.gz` |
| macOS x64 | `claudec-x64-macos.tar.gz` |
| Linux arm64 | `claudec-arm64-linux.tar.gz` |
| Linux x64 | `claudec-x64-linux.tar.gz` |

```sh
tar xzf claudec-<arch>-<os>.tar.gz
sudo mv claudec /usr/local/bin/
```

macOS builds include both Apple Container and Docker runtime support. Linux builds only support Docker as runtime currently. New runtime and platform support is welcome!

### Build from source

Requires Swift 6.1+ (install via [swiftly](https://swiftlang.github.io/swiftly/)).

```sh
git clone https://github.com/laosb/claudec.git && cd claudec
./build.sh                                    # default runtimes for your platform
./build.sh --runtimes docker                  # Docker only (macOS or Linux)
./build.sh --runtimes apple-container,docker  # both (macOS only)
sudo cp claudec /usr/local/bin/
```

## Usage

```sh
claudec                         # start Claude Code in $PWD
claudec "explain this codebase" # pass arguments to Claude Code
claudec sh                      # open a shell in the container
claudec sh ls -la /home/claude  # run a command inside the container
```

On first run, the bootstrap script installs swiftly, a Swift toolchain, Bun, and Claude Code into the profile's home directory. Subsequent runs reuse the existing install. Customise by setting `CLAUDEC_BOOTSTRAP_SCRIPT` or by building your own image from the [Dockerfile](./Dockerfile).

### Profiles

A profile is a persistent `/home/claude` that survives container restarts — keeping Claude Code auth, memory, MCP servers, and settings.

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
