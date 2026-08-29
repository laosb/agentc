# Building agentc

This document covers local development and release-style builds. For installation and day-to-day usage, see [README.md](./README.md).

## Requirements

- **Swift 6.3+**. CI currently uses Swift 6.3.2.
- **macOS 15+** to build the Apple Containerization backend.
- **macOS or Linux** to build the Docker backend.
- A Docker-compatible daemon is only required when running Docker-backed integration tests or using a Docker build locally.
- A Swift **Static Linux SDK** is required to build the statically linked Linux `agentc` binary or `agentc-bootstrap`.

The package exposes two Swift package traits:

- `ContainerRuntimeAppleContainer` — Apple Containerization, macOS only.
- `ContainerRuntimeDocker` — Docker Engine API, macOS and Linux.

## Development builds

On macOS, the package defaults to both runtime traits:

```sh
swift build
```

For a Docker-only build, including on Linux:

```sh
swift build --disable-default-traits --traits ContainerRuntimeDocker
```

To build with both runtimes explicitly on macOS:

```sh
swift build \
  --disable-default-traits \
  --traits ContainerRuntimeAppleContainer,ContainerRuntimeDocker
```

## Tests

Run the runtime-independent and Docker unit tests with:

```sh
swift test \
  --disable-default-traits \
  --traits ContainerRuntimeDocker \
  --filter 'AgentIsolationTests|AgentIsolationDockerRuntimeTests'
```

On macOS, enable both runtime traits when working on Apple Containerization code:

```sh
swift test \
  --disable-default-traits \
  --traits ContainerRuntimeAppleContainer,ContainerRuntimeDocker
```

The integration test suite also needs a working container runtime, a locally available `agentc-bootstrap`, test images, and agent configurations. See [`.github/workflows/test.yml`](./.github/workflows/test.yml) for the CI setup used by the project.

## Release-style `agentc` builds

`build.sh` builds the `agentc` executable, selects runtime traits, and copies the result to `./agentc`.

```sh
./build.sh                                      # release build; platform-default runtimes
./build.sh --debug                              # debug build
./build.sh --runtimes docker                    # Docker only
./build.sh --runtimes apple-container,docker    # both runtimes on macOS
```

Defaults are:

- macOS: `apple-container,docker`
- Linux: `docker`

When Apple Containerization is included on macOS, `build.sh` ad-hoc signs the executable with the virtualization entitlement.

Set build metadata through environment variables:

```sh
BUILD_VERSION=1.2.3 BUILD_GIT_SHA=$(git rev-parse HEAD) ./build.sh
```

These values are reported by `agentc version`. If omitted, the build uses `dev` and the current Git SHA when available.

## Static Linux builds

Install a Swift Static Linux SDK matching your toolchain, then pass its SDK name to `build.sh`:

```sh
./build.sh --runtimes docker --swift-sdk x86_64-swift-linux-musl
./build.sh --runtimes docker --swift-sdk aarch64-swift-linux-musl
```

The CI-pinned Static Linux SDK installation is defined in [`.github/actions/setup-swift/action.yml`](./.github/actions/setup-swift/action.yml).

## Building `agentc-bootstrap`

`agentc-bootstrap` is the in-container entrypoint and is built separately as a statically linked Linux executable:

```sh
# x64
swift build \
  --product agentc-bootstrap \
  -c release \
  --swift-sdk x86_64-swift-linux-musl

# arm64
swift build \
  --product agentc-bootstrap \
  -c release \
  --swift-sdk aarch64-swift-linux-musl
```

For local development, either install the binary where agentc looks for it:

```sh
mkdir -p ~/.agentc/bin
cp .build/<sdk>/release/agentc-bootstrap ~/.agentc/bin/bootstrap
chmod +x ~/.agentc/bin/bootstrap
```

or pass it explicitly:

```sh
./agentc run --bootstrap /path/to/agentc-bootstrap
```

Released versions of agentc download the matching bootstrap binary automatically on first use.

## Toolkit

The agentc Toolkit is released independently from the main executable. Its contents are defined by [`scripts/toolkit/manifest.sh`](./scripts/toolkit/manifest.sh), and its release workflow lives in [`.github/workflows/toolkit.yml`](./.github/workflows/toolkit.yml).

When the manifest, builder, or release workflow changes on `main`, CI increments the Toolkit version in both the manifest and `ToolkitManager`, squash-merges a short-lived version-bump PR, and publishes the new Toolkit release from that merge.

## Architecture

```text
agentc (CLI)
  ├─ AgentIsolation                       runtime-agnostic orchestration
  ├─ AgentIsolationAppleContainerRuntime  Apple Containerization backend
  └─ AgentIsolationDockerRuntime          Docker Engine backend

agentc-bootstrap                          in-container initialization/entrypoint
agentc Toolkit                            curl, jq, ripgrep, CA bundle
```

`AgentIsolation` depends only on Foundation and `swift-crypto`; runtime-specific dependencies are isolated behind Swift package traits.
