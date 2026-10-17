# Host binary bridge

The host bridge exposes explicitly configured host commands as executables inside
the container. It is opt-in and **executes outside the container's isolation
boundary**, as the user running agentc. It is intended for non-TTY, stdio tools,
including host-only MCP servers.

## Configure and authorize

In `.agentc/settings.json`:

```json
{
  "agent": {
    "hostBinaries": [
      {
        "containerPath": "/usr/local/bin/host-mcp",
        "hostCommand": "/usr/bin/xcrun",
        "arguments": ["mcpbridge"],
        "forwardArguments": false,
        "forwardEnvironment": ["DEVELOPER_DIR"]
      }
    ]
  }
}
```

Then authorize the reviewed declarations for this invocation:

```sh
agentc run --allow-host-binaries
```

The same option works with `agentc sh` and `agentc acp`. In ACP mode it authorizes
the explicit mappings in each selected workspace's settings. Trust both the
client selecting those workspaces and the projects containing the settings.
**Automatic rewriting of ACP MCP descriptors is not implemented yet.**

| Field | Meaning |
|---|---|
| `containerPath` | Required absolute path for a new proxy executable. Existing files, including symlinks, are never replaced. |
| `hostCommand` | Required absolute host executable path. No shell expansion or PATH lookup. |
| `arguments` | Fixed arguments prepended to each host invocation; defaults to `[]`. |
| `forwardArguments` | Append arguments supplied to the container proxy; defaults to `true`. With `false`, supplying any arguments fails. |
| `forwardEnvironment` | Exact, case-sensitive container environment variable names to forward; defaults to `[]`. No wildcards. |

Commands run in the **host workspace directory**, not the container caller's cwd.
They inherit agentc's host environment. Only the named container environment
variables override it, using values at proxy invocation time. A missing container
variable leaves the host value unchanged; an explicitly empty value overrides it
with an empty string. The broker independently checks the allow list, so modifying
the guest helper or manifest cannot add forwarded variables. `AGENTC_*` names
are reserved.

Prefer a dedicated path such as `/usr/local/bin/host-mcp`. Paths must be on the
container image filesystem, not a workspace, profile, or other mounted filesystem.
Kernel, runtime-control, and system-configuration paths are rejected. Parent
directories are created as needed; no PATH modification is performed.

## Bootstrap and runtime support

The proxy is a mode of **`agentc-bootstrap`**, not another guest binary. It uses
Swift's POSIX imports and a bounded `poll` loop; it adds no C source, networking
framework, or process-library dependency to the bootstrap.

A managed bootstrap must declare `host-bridge-v1` in its digest-verified descriptor.
Old bootstraps fail with an update instruction rather than silently ignoring
the mappings. For a newly built, custom bootstrap:

```sh
swift build --product agentc-bootstrap -c release --swift-sdk aarch64-swift-linux-musl
agentc run --allow-host-binaries \
  --bootstrap .build/aarch64-swift-linux-musl/release/agentc-bootstrap \
  --bootstrap-host-bridge
```

Use the SDK matching the container architecture. `--bootstrap-host-bridge` is an
explicit declaration that this custom binary implements the protocol. It does not
add that support to an old binary or arbitrary script. The standard bootstrap must
start as root to install the new paths before dropping to the agent user.
`--respect-image-entrypoint` is not supported with host mappings.

Supported transports:

- **Apple Containerization:** its native Unix-socket relay across the VM boundary.
- **Native Linux Docker, local Unix endpoint, `runc`:** socket bind mount.

Docker Desktop, remote Docker, Kata, gVisor, and unrecognized runtime aliases are
not supported by this first version. There is no TCP fallback, exposed network
listener, or automatic downgrade of the selected container runtime.

## IO, signals, and lifecycle

Each invocation starts a fresh host process group. Stdin, stdout, and stderr are
byte streams: there is no UTF-8 conversion, MCP parsing, or mixing of stderr into
stdout. Stdin EOF is independent of connection shutdown. Buffers and frame sizes
are bounded, with stdin credits so a non-reading child cannot block signal delivery.
There are at most 32 active/handshaking invocations per container.

The proxy forwards `HUP`, `INT`, `QUIT`, `TERM`, `USR1`, `USR2`, and `ALRM` to the
host process group. Signal identities, not OS-specific numbers, cross the wire.
Normal exit codes are preserved; supported fatal host signals are re-raised by
the guest proxy after draining output. Launch, authorization, and transport errors
print to stderr and exit with code 125.

This is not a full POSIX process emulator: no PTY, terminal resizing, job control,
extra file descriptors, or stopped-process notifications. `SIGKILL` and `SIGSTOP`
cannot be intercepted. Killing a proxy closes its connection and triggers host
cleanup; merely stopping it does not stop its host child. Arbitrary host signals
sent by other processes are not observable unless they terminate the child.

Disconnect, session cancellation, and broker shutdown terminate the process group
and reap its leader. Descendants in the group are also killed when the leader
exits, before reporting termination. Tools that daemonize into a different
session/process group are outside this lifecycle guarantee. An uncatchable kill
or crash of agentc itself may also leave host processes behind.

## Security

A mapping is a grant of host privileges, not a sandbox for that command. Mapping
a shell, interpreter, or package runner with caller-controlled arguments can
grant arbitrary host execution. Forwarding loader/configuration variables can
also substantially expand a command's capabilities. Restrict arguments and
environment names to what the tool actually needs.

Every broker has a private host directory, random per-container credential, and
host-owned mapping table. A guest can invoke only that container's registered
commands; it cannot choose a host executable or cwd through the wire protocol.
Credentials are removed on orderly shutdown. Host executable paths and host
environment values are not copied into the guest manifest.

The bridge does not translate paths embedded in arguments or protocol payloads,
nor expose container-only files to host tools. Use host-path workspace mounts
when a tool needs the same workspace path on both sides.

## Validation

Unit/transport tests:

```sh
swift test --filter HostBridgeTests
```

Real-container smoke test (requires built binaries and, on macOS, a signed host
binary with the virtualization entitlement):

```sh
python3 scripts/test-host-bridge.py /path/to/agentc /path/to/linux/agentc-bootstrap
```

Pass `docker` as the third argument on a native Linux Docker host. The test uses
isolated fixtures under `.build`, checks explicit authorization and environment
filtering, and verifies IO, exit status, and guest-to-host signal forwarding.
