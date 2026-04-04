# Migrating to claudec v1 (Swift)

claudec has been rewritten from a shell script to a native Swift CLI. This document covers the changes that matters to you, end users.

## Installation

**Before:** Clone the repo, symlink the `claudec` shell script to your `$PATH`.

**Now:** Download a pre-built binary for your platform from [GitHub Releases](https://github.com/laosb/claudec/releases), or build from source with `./build.sh`. macOS binaries are ad-hoc signed with the virtualization entitlement (handled automatically by `build.sh`).

Binaries are available for macOS (arm64, x64) and Linux (arm64, x64).

## Container runtimes

**Before:** Apple Containerization only (macOS).

**Now:** Two runtime backends:
- **Apple Container** — native macOS virtualization (default on macOS)
- **Docker** — Docker Engine API v1.44 (default on Linux, also available on macOS)

Set `CLAUDEC_CONTAINER_RUNTIME=docker` to use Docker on macOS, or `CLAUDEC_CONTAINER_RUNTIME=apple-container` to use Apple Container. The Docker endpoint can be configured with `CLAUDEC_DOCKER_ENDPOINT` (default: `/var/run/docker.sock`).

## Removed environment variables

| Variable | Reason |
|---|---|
| `CLAUDEC_CONTAINER_FLAGS` | No longer applicable — this Swift version calls `apple/containerization` library instead of invoking `container` CLI |
| `CLAUDEC_CHECK_UPDATE` | It's temporary removed because update by git pulling is not going to work unless you build it yourself |

## New environment variables

| Variable | Default | Description |
|---|---|---|
| `CLAUDEC_IMAGE_AUTO_UPDATE_REMOVE_OLD` | `1` | Set `0` to keep old image after auto-update pulls a newer one. |
| `CLAUDEC_CONTAINER_RUNTIME` | *(auto)* | Container runtime: `apple-container` or `docker`. |
| `CLAUDEC_DOCKER_ENDPOINT` | `/var/run/docker.sock` | Docker Engine API endpoint. |

All other environment variables (`CLAUDEC_PROFILE`, `CLAUDEC_PROFILE_DIR`, `CLAUDEC_IMAGE`, `CLAUDEC_WORKSPACE`, `CLAUDEC_IMAGE_AUTO_UPDATE`, `CLAUDEC_EXCLUDE_FOLDERS`, `CLAUDEC_BOOTSTRAP_SCRIPT`) work the same as before.

## Behavioral changes

- **Bootstrap script mounting** now copies the script to a temp directory rather than bind-mounting it directly. This avoids issues with some runtime configurations but is functionally identical.
- **Error reporting** is more structured. Invalid environment variables produce clear error messages instead of silent fallbacks.

## Internal changes

- `AgentIsolation` library: runtime-agnostic orchestration layer with a `ContainerRuntime` protocol. This enables future support for Docker, Podman, or other backends.
- `AgentIsolationAppleContainerRuntime`: Apple Containerization backend, isolated from the orchestration logic.
- Tests: migrated from simple bash script (`test.sh`) to Swift Testing.
