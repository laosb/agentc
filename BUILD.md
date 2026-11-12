# Building agentc

This document covers local development and release-style builds. For installation and day-to-day usage, see [README.md](./README.md).

## Requirements

- **Swift 6.4+**. CI and `.swift-version` pin Swift 6.4.2.
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

Run the CLI, runtime-independent, and Docker unit tests with:

```sh
swift test \
  --disable-default-traits \
  --traits ContainerRuntimeDocker \
  --filter 'AgentcTests|AgentIsolationTests|AgentIsolationDockerRuntimeTests'
```

The rootfs-cache tests do not need Containerization and run on Linux too, but only
when the Apple runtime target is linked in — add its trait to pick them up:

```sh
swift test \
  --disable-default-traits \
  --traits ContainerRuntimeAppleContainer,ContainerRuntimeDocker \
  --skip AgentcIntegrationTests
```

SOCKS5 protocol, helper-lifecycle, and configuration tests are included in the
unit tests above. The packet-engine harness runs separately with actual lwIP and
a deterministic mock upstream transport:

```sh
sh scripts/test-packet-engine.sh
SANITIZE=address sh scripts/test-packet-engine.sh --control-eof
SANITIZE=address sh scripts/test-packet-engine.sh --readiness --control-eof
```

It checks strict Swift 6 concurrency, packet validation, backpressure, adverse
half-close orderings, and slot recycling. The readiness harness additionally
checks coalesced wakeups, quiet cancellation, and Dispatch-source cancellation
completion before borrowed file descriptors can be closed/reused.
The new native networking code uses
Swift 6 concurrency; lwIP 2.2.1 is vendored, so no Go toolchain or extra executable
is needed.

For an opt-in real-VM proxy check on macOS, build/sign agentc and run:

```sh
./build.sh --debug
python3 scripts/test-socks5-network.py
```

This starts a local authenticated SOCKS5 fixture serving synthetic DNS, TCP, and
UDP destinations. It checks configured UDP/TCP gateway DNS, a 1 MiB TCP transfer,
UDP boundaries/empty/max payloads/source-port isolation, hidden credentials,
rejected traffic, UDP control-connection failure, and loss of connectivity when the
networking child is killed. Additional VM cases verify TCP-only and policy-rejecting
proxies fail closed for UDP. It defaults to `python:3.13-slim`; use `AGENTC_TEST_SOCKS_IMAGE` to
select another image with `/usr/local/bin/python3`. Host image/kernel downloads
may still access the internet; the fixture itself never does.

Existing bridge smoke tests accept `AGENTC_TEST_SOCKS_PROXY=socks5://HOST:PORT` to
exercise their compatibility with enforced proxy networking. Host execution
remains outside the guest network policy. The MCP test's host relay can work even
with an unreachable upstream proxy; its explicitly permitted local connection is
independent of internet connectivity.

For local NAT-versus-proxy throughput, RTT, helper CPU, and RSS measurements, see
[the network benchmark guide](docs/network-benchmark.md). Measure release binaries
for shipping performance; keep debug/release results separate.

On macOS, enable both runtime traits when working on Apple Containerization code:

```sh
swift test \
  --disable-default-traits \
  --traits ContainerRuntimeAppleContainer,ContainerRuntimeDocker
```

The integration test suite also needs a working container runtime, a locally available `agentc-bootstrap`, test images, and agent configurations. See [`.github/workflows/test.yml`](./.github/workflows/test.yml) for the CI setup used by the project.

The ACP proxy has a separate real-container smoke test using disposable profiles
and a small shell-based ACP agent, without provider credentials:

```sh
./build.sh --debug
python3 scripts/test-acp.py
AGENTC_TEST_ACP_SIGNAL=1 python3 scripts/test-acp.py
python3 scripts/test-host-mcp.py
```

It defaults to Apple Containerization on macOS and Docker elsewhere, using
`swift:6.4`. Override with `AGENTC_TEST_RUNTIME` / `AGENTC_TEST_IMAGE`. The test
checks two isolated workspaces, settings and CLI mounts, exclusions, protocol
routing, extension passthrough, malformed-message recovery, logging, and cleanup
on EOF or SIGTERM. Python 3 is needed on the host; the image needs `/bin/sh` and
`sed`. The regular `AgentcTests` include runtime-independent ACP state-machine
and policy tests.

`test-host-mcp.py` also verifies execution of an unmounted host-only MCP script,
argument/environment preservation, config opt-in and CLI opt-out, stderr
redirection, and host process cleanup on EOF/SIGTERM. Its guest ACP fixture uses
Swift Codable and executes the bootstrap's native relay. Set
`AGENTC_TEST_BOOTSTRAP` to a freshly built static bootstrap; by default the test
uses `~/.agentc/bin/bootstrap`, which CI builds before testing. The test driver
image needs Swift, not the relay itself. `scripts/test-mcp-relay-minimal.py`
additionally runs the bootstrap in a Docker `scratch` image (with only the kernel
filesystems supplied by Docker), checking 2 MiB of opaque traffic and EOF flushing
without image utilities or shared libraries. CI runs the ACP and host-MCP smoke
scripts against both native and static Linux release binaries on x64 and arm64.
Each architecture builds the native test bundle and static bootstrap once and
reuses the images and fixtures for both binaries. The bootstrap-only scratch-image
test runs once per architecture.

For the minimal-image test on macOS, set `AGENTC_TEST_MINIMAL_RUNTIME=container`
to use Apple's `container` CLI instead of Docker. The script constructs and loads
a one-file image archive directly; no image builder or base-image download is needed.

Bootstrap ownership regression tests run on Linux with the native toolchain (the
Static Linux SDK does not include the Testing module):

```sh
swift test --disable-default-traits --traits ContainerRuntimeDocker --filter AgentcBootstrapTests
```

These exercise the bootstrap's ownership code against temporary directories,
simulating mounts that reject unnecessary ownership changes, without requiring root
or a container runtime. CI runs them on both Linux architectures.

To also check a real shared mount, set `AGENTC_TEST_UNCHOWNABLE_DIRECTORY` to an
existing directory owned by the test user whose mount rejects even a same-owner
`chown` (for example, `/home/agent` inside an Apple Containerization guest). This
opt-in test attempts only that no-op ownership change and does not create files.

Apple Container's **share root** is different: it reports synthetic `0:0`
ownership and rejects `chown`, even though a non-root agent can access host-owned
private files. The Apple runtime selects access-based profile initialization:
bootstrap creates and probes the managed directories as the image's agent user,
without changing ownership or permissions. Ownership-record fast-path opt-in is
not applicable to this runtime.

To test this behavior, mount a **disposable**, writable host directory at
`/home/agent` in an Apple Container guest, run the Linux bootstrap tests as guest
root, and set `AGENTC_TEST_APPLE_SHARED_HOME=/home/agent`. Unlike the no-op test
above, this creates managed directories and temporary write probes. The test
asserts that mount-root `chown` fails and initialization succeeds twice as a
non-root UID. The regular Linux tests also check that genuinely inaccessible
homes and managed directories fail, and that private permissions are preserved.

## CI selection and reuse

The Test workflow runs on PRs targeting `main` and pushes to `main`. A lightweight
selection job examines the complete Git diff (the PR merge base or the entire
push range), including deleted and renamed paths:

- Package/toolchain, shared CI action, or CI helper changes select every test job.
- Source and Swift-test changes select macOS and Linux unit tests on x64 and arm64.
- Source, Dockerfile, build-script, integration-test, and smoke-fixture changes
  select native and static Linux integration tests.
- Shared isolation and Docker-runtime changes select gVisor E2E on both Linux
  architectures and the existing best-effort Kata E2E on x64. Kata probes KVM
  before installing Swift.
- Packet-engine inputs select the macOS AddressSanitizer harnesses.
- Documentation, installer, toolkit-only, and release-workflow-only changes do not
  start Swift jobs. The cheap selection/build-script checks still run.

Manual dispatch runs everything. Missing diff history also runs everything rather
than silently skipping coverage. Superseded Test runs on the same PR/ref are
cancelled; publication workflows are serialized instead. `Test result` is the
stable aggregate check suitable for branch protection, including docs-only PRs.
When adding CI inputs or commands, update `scripts/ci/changes.py` and its tests.
PR and main runs are intentionally separate: the latter validates the actual
landed tree and populates caches accessible to subsequent PRs.

Linux unit and integration tests share one native test bundle per architecture;
integration tests use `--skip-build` while launching the selected `./agentc`
release binary. Local Docker images replace image artifact export/upload/download,
and tests create their own stub configurations/profiles instead of cloning or
caching unused fixtures. Build caches are scoped by platform, architecture,
purpose, toolchain and package inputs, with a revision suffix so restored builds
can be refreshed.

Tagged releases still build all six CLI variants. Each static Linux job also
packages its bootstrap, avoiding separate bootstrap jobs. Release builds remain
separate from tests because they embed tag-specific metadata. Toolkit publication
remains independently path-filtered and versioned.

Validate the selection rules and build wrapper without installing Swift:

```sh
python3 -m unittest discover -s scripts/ci -p 'test_*.py'
bash scripts/test-build-paths.sh
```

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

### Dependency compatibility

The package uses Containerization 0.54.0 with its matching vminit 0.54.0 image.
Swift Crypto is on 4.5.2 because Containerization requires a version below 5.0.0;
upgrading to Crypto 5 requires an upstream Containerization compatibility update.
The guest kernel uses Kata 4.3.1, matching Apple Container 1.7.1's kernel
defaults rather than the newest standalone Kata release.

## Startup performance

Startup is instrumented behind `--verbose`, and the Apple Containerization backend caches unpacked image root filesystems so repeat launches skip the unpack while still getting a fresh, disposable rootfs. See [Startup Performance](./docs/startup-performance.md) for the phase list, the cache layout and its maintenance, the `--no-rootfs-cache` rollback switch, and how to benchmark with [`scripts/benchmark-startup.sh`](./scripts/benchmark-startup.sh).
