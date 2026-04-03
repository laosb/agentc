# claudec

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside an isolated Apple [Containerization](https://apple.github.io/containerization/), container with persistent profiles and per-project memory isolation.

> [!NOTE]
> If upgrading from the shell-script version, see [MIGRATE_TO_V1.md](./MIGRATE_TO_V1.md).

## Install

### Prerequisites

- macOS 15+

### From GitHub Releases

Download the latest `claudec-arm64-macos.tar.gz` from [Releases](https://github.com/laosb/claudec/releases), extract, and place the binary on your `$PATH`:

```sh
tar xzf claudec-arm64-macos.tar.gz
sudo mv claudec /usr/local/bin/
```

### Build from source

Requires Swift 6.1+ (install via [swiftly](https://swiftlang.github.io/swiftly/)).

```sh
git clone https://github.com/laosb/claudec.git && cd claudec
./build.sh          # builds + (ad-hoc) signs with virtualization entitlement
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

Stored at `~/.claudec/profiles/<name>/home/`.

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
| `CLAUDEC_EXCLUDE_FOLDERS` | *(empty)* | Comma-separated workspace sub-folders to mask with empty read-only overlays (e.g. `node_modules,.git`). |
| `CLAUDEC_BOOTSTRAP_SCRIPT` | *(empty)* | Path to a custom entrypoint script, replacing the image default. |

## Architecture

```
claudec (CLI)
  └─ AgentIsolation           (runtime-agnostic orchestration)
  └─ AgentIsolationAppleContainerRuntime  (Apple Containerization backend)
```

`AgentIsolation` has zero third-party dependencies — only Foundation and CryptoKit. Alternative runtime backends (Docker, Podman, etc.) can be added by conforming to the `ContainerRuntime` protocol.

## Development

```sh
swift build                  # debug build
swift test                   # unit + integration tests (integration needs container CLI + image)
./build.sh                   # release build + codesign
```

### Building the container image

```sh
docker build -t claudec .
CLAUDEC_IMAGE=claudec claudec
```
