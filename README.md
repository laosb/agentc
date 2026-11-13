# agentc

Run AI coding agents in isolated containers with persistent profiles and per-project memory isolation.

`agentc` works with [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [OpenAI Codex CLI](https://learn.chatgpt.com/docs/codex/cli), [GitHub Copilot CLI](https://docs.github.com/en/copilot/github-copilot-in-the-cli), and other agents through pluggable configurations from [agent-isolation-configurations](https://github.com/laosb/agent-isolation-configurations).

## Highlights

- **Isolated execution** — use Apple Containerization on macOS or a Docker-compatible runtime on macOS/Linux. On Docker, agentc prefers Kata Containers or gVisor over `runc` when available.
- **Persistent profiles** — keep agent authentication, settings, MCP servers, and memory across sessions without mixing every project into one workspace.
- **Pluggable agents** — switch or combine agent configurations without rebuilding agentc.
- **Bring your own image** — run on normal or minimal container images; the bootstrap and Toolkit provide the basics needed to get started.
- **Project-aware defaults** — store agent, resource, environment, mount, and image settings in `.agentc/settings.json`.
- **Enforced SOCKS5 networking** — on Apple Containerization, optionally route guest IPv4 TCP, UDP, and configurable DNS through a host-side proxy adapter, without proxy-aware applications. See [networking scope and host-bridge exceptions](docs/socks5-networking.md).

## Install

### Prerequisites

**macOS with Apple Containerization:** macOS 15+, Apple Silicon or Intel.

**macOS / Linux with Docker:** x64 or arm64, with a Docker Engine API v1.44+ compatible daemon such as Docker or Podman in Docker-compatible mode.

> [!IMPORTANT]
> Standard Docker containers share the host kernel. Because coding agents run code you did not write, agentc automatically prefers Kata Containers or gVisor when available and warns when only standard `runc` isolation is available. See [Safer Docker Isolation](./docs/docker-runtimes.md).

Install the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/laosb/agentc/main/install.sh | sh
```

## Quick start

Run the default agent, Claude Code, in the current directory:

```sh
agentc run
```

Choose another agent configuration or forward arguments to the agent:

```sh
agentc run -c codex
agentc run -c copilot
agentc run -c claude -- --model opus
agentc run -- "explain this code"
```

Open a shell in the same kind of isolated environment:

```sh
agentc sh
agentc sh -- ls -la /home/agent
```

Use `agentc --help` and `agentc <subcommand> --help` for the full CLI reference.

## Agent configurations

Agent configurations are modular setup recipes. They install or prepare an agent and can depend on other configurations.

Pass a comma-separated list with `-c` / `--configurations`:

```sh
# Prepare Claude Code and GitHub Copilot CLI, then launch Copilot.
agentc run -c claude,copilot
```

Configurations are activated in order; the last activated configuration that defines an entrypoint provides the command that runs. See [agent-isolation-configurations](https://github.com/laosb/agent-isolation-configurations) for the available configurations and their definitions.

## Persistent profiles

A profile keeps a persistent agent home directory across container restarts. Its `home` directory is mounted as `/home/agent`, so agent authentication, settings, memory, and MCP configuration survive between sessions.

```sh
agentc run -p work
agentc run -p personal

agentc profiles
agentc profiles list work

agentc run --profile-dir ~/my-agent-profile
```

Profiles are stored under `~/.agentc/profiles/<name>/`. You can also use a custom directory.

## Project settings

Initialize a project to create `.agentc/settings.json` and prepare its container environment:

```sh
agentc init
```

You can set useful defaults while initializing:

```sh
agentc init -c codex --cpus 4 --memory-mib 4096
```

CLI flags override project settings, while mergeable fields such as excludes and additional mounts are combined. See [Project Settings](./docs/project-settings.md) for the full schema and resolution rules.

## Container images and Toolkit

agentc can use any standard container image. By default, its bootstrap prepares the agent user and environment before launching the configured agent.

```sh
agentc run -i debian:latest
agentc run -i alpine:latest
agentc run -i buildpack-deps:scm
agentc run -i my-custom-image:latest
```

By default, agentc mounts an **agentc Toolkit** into the container, which provides `curl`, `jq`, `ripgrep` in `$PATH`, if they are not supplied by the image. This allows you to use coding agents on virtually any kind of Docker images.

## Workspaces and additional mounts

By default, host-backed paths use the `workspace` mount scheme: the project workspace and additional mounts receive stable destinations under `/workspace`.

```sh
agentc run --additional-mount ~/shared
```

When an editor, protocol, or script requires the same absolute path inside and outside the container, use the `host` scheme:

```sh
agentc run \
  --mount-path-scheme host \
  --additional-mount /Users/me/shared
```

The project default can be set with `agent.mountPathScheme` in `.agentc/settings.json`; the CLI flag overrides it.

## Scripted execution

For `agentc run` and `agentc sh`, stdout belongs to the launched workload. agentc progress, setup output, warnings, and verbose diagnostics go to stderr, including configuration `prepare.sh` output.

That makes non-interactive output safe to pipe or parse:

```sh
agentc run -- "summarize this project" > summary.txt
```

This allows you to use agentc to run stdio-based MCP or ACP. Automatic TTY behavior is preserved for interactive sessions.

### ACP clients and automatic workspace mounts

Use `agentc acp` when the client supplies the project directory through ACP rather
than launching agentc in that directory:

```sh
agentc acp -c claude-acp -i swift:6.4 \
  --log-file /tmp/agentc.log --stdio-log-file /tmp/agentc.stdio.log
```

The command forces non-terminal I/O and host-preserving mount paths. On
`session/new`, `session/load`, or `session/resume`, it reads the requested `cwd`'s
`.agentc/settings.json` (not the launch directory's settings or an ancestor's).
`--agentc-folder` can explicitly select another settings folder. Malformed
settings reject the request rather than silently falling back to defaults.
CLI options take precedence as usual; additional mounts and exclusions are
combined with the project settings. Relative additional mounts resolve against
the session cwd.

Only that workspace and its configured `agent.additionalMounts` /
`--additional-mount` directories are mounted as project directories, in addition
to agentc's normal persistent profile, configurations, bootstrap, and toolkit.
Paths mentioned in prompts, file requests, MCP commands, or unknown extensions
never cause mounts. The ACP client is trusted to choose host directories:
optionally use `--workspace /Users/me/Developer` to restrict session cwd selection
to that root (including symlink resolution). Explicit additional mounts may be
outside that root.

Each workspace gets a separate container-backed agent, with mounts and settings
fixed until that backend exits. Settings edits do not expand an existing
backend. Live directory expansion, session listing, and session forking are not
currently supported or advertised. At most eight workspace backends plus one
initialization backend run on a connection.

ACP initialization happens before the client supplies a cwd. A real agent in an
empty temporary workspace supplies the initial capabilities, using CLI options
and profile defaults. Specify the ACP configuration and image on the CLI rather
than relying only on project settings. Project agents must have compatible
protocol capabilities. Connection-scoped authentication uses this initialization
backend; projects selecting another profile need credentials in that profile.
Session IDs are namespaced by workspace to avoid collisions and can be passed
back to `session/load` / `session/resume` with the same cwd.

Messages are forwarded as opaque bytes. Every line is validated as JSON
(RFC 8259 grammar, well-formed UTF-8, paired surrogate escapes, at most 512
levels of nesting) by a streaming scanner, and only the routing values, the
JSON-RPC `id` and `params.sessionId` / `result.sessionId`, are replaced in
place. Attachments, numbers, member order, and unknown fields and extensions
reach the other side byte for byte, and numeric IDs are echoed as the exact
token the client sent. Only `initialize`, `session/new`, `session/load`,
`session/resume`, and initialization responses are decoded and re-encoded with
Swift Codable, to apply workspace policy and remove unsupported advertised
capabilities. A message that repeats a routing member (`id`, `method`,
`params`, `result`, `error`, `jsonrpc`, or a `sessionId` directly inside
`params` or `result`) is rejected rather than routed.

Memory use does not grow with message size:

| Limit | Value |
| --- | --- |
| Held in memory; larger messages are spooled to disk | 256 KiB |
| Messages the proxy decodes (the methods listed above) | 1 MiB |
| One message, either direction | 1 GiB |
| Disk used by all in-flight spooled messages | 4 GiB |
| Undelivered messages per input stream, after which reading pauses | 64 messages and 4 MiB in memory |
| Session requests waiting for workspace backends to start | 8 MiB |
| `id` / `method` / `sessionId` length | 256 bytes / 256 bytes / 8 KiB |

Spool files live in a private (`0700`) directory under the system temporary
directory, outside every container mount, and are unlinked as soon as they are
created, so their space is reclaimed however `agentc` exits. A large message is
forwarded only once it has been received and validated in full. When a peer
stops reading, the proxy stops reading from the peers that are sending to it
instead of buffering, as a direct pipe would; since all workspaces share the
client connection, one stalled backend can eventually delay client traffic to
the others.

Nothing is dropped silently. A client line that is not valid JSON gets a
JSON-RPC parse error (`-32700`) with `id: null`, because no field of it can be
trusted. A well-formed request that is too large, exhausts the spool quota, or
has an invalid envelope gets an error (`-32600`) with its own `id`, wherever in
the message that `id` appeared. If an agent sends a line that is not valid JSON, or one
that cannot be matched to a request, that workspace backend is stopped and
everything it owes is answered with an error, since the line may have been a
response a client is waiting for; an oversized agent response fails only its
own request. Rejected requests receive JSON-RPC errors, and a failed backend
does not stop other workspaces. Backend initialization times out after 120
seconds.


#### Host stdio MCP servers

To use host-only tools such as Xcode's macOS `mcpbridge`, explicitly enable:

```sh
agentc acp -c claude-acp -i swift:6.4 --bridge-host-stdio-mcp
```

Or opt in per workspace in `.agentc/settings.json`:

```json
{
  "agent": {
    "acp": {
      "bridgeHostStdioMcp": true
    }
  }
}
```

The default is **off**. An explicit `--no-bridge-host-stdio-mcp` overrides a
project's opt-in. This setting is snapshotted with the workspace's other settings.

**Enabling this trusts the ACP client to execute commands as your host user,
outside container isolation.** Project settings can enable it too; use the
negative CLI flag when opening untrusted projects. `--workspace` does not sandbox
host MCP commands.

For session creation/loading/resumption, agentc replaces each client-provided
stdio MCP definition with a guest relay. The host launches the original command
directly (not through a shell), with its original arguments, the host environment
overridden by the supplied environment entries, and the session cwd. HTTP/SSE and
unknown transport definitions remain unchanged. MCP bytes pass through unchanged,
including notifications and server-initiated requests. MCP stderr follows
`--log-file` / stderr, never ACP or MCP stdout.

The relay is a native mode of the existing statically linked Swift bootstrap.
It invokes the already-mounted `/entrypoint-bootstrap/bootstrap` directly:
there is no additional relay copy, alias, or mount. With an image entrypoint,
agentc adds that same bootstrap mount without changing the image's entrypoint.
It requires **no shell, utilities,
dynamic loader, or shared libraries** in the selected image, and works with
`--respect-image-entrypoint`. Install an updated `agentc-bootstrap` or use
`--bootstrap <updated-static-bootstrap>`; old or dynamically linked bootstraps
are rejected with an actionable error before the workspace agent starts.
The normal Linux `/proc` mount is still required by Swift's runtime; it is
supplied by the container runtime, not by image utilities.
The bridge uses an ephemeral host TCP listener with random,
per-definition capabilities; the network peer cannot supply commands. The guest
connects via its default gateway, falling back to `host.docker.internal`.
This is intended for local Apple Containerization and local Docker networks, not
remote Docker daemons. The listener binds IPv4 interfaces to allow guest access;
the transport is **not encrypted**, so use only trusted local networks and allow
the connection through any host firewall. Capabilities are revoked and host
processes terminated when their workspace backend stops or ACP shuts down.

Alternatively, declare an explicit [`agent.hostBinaries` mapping](docs/host-bridge.md)
and authorize it with `--allow-host-binaries`. That separate mechanism maps
configured container paths to host commands and restricts environment forwarding
to each mapping's explicit allow list; it does not rewrite ACP MCP definitions.

Logging uses [apple/swift-log](https://github.com/apple/swift-log), with stderr as
the default destination. Add `--verbose` (or `-v`) for debug logs and startup timings.
Use `--log-file <file>` to append logs and stderr, including container bootstrap
and configuration setup output, to a file instead:

```sh
agentc run --verbose --log-file agentc.log -- "summarize this project"
```

For protocol diagnostics, `--stdio-log-file <file>` on `run`, `sh`, or `init`
records session traffic with `stdin:` and `stdout:` prefixes while forwarding the
original bytes unchanged. It works independently of `--verbose` and `--log-file`:

On `acp`, this option records the client-facing traffic, before incoming routing
rewrites and after outgoing rewrites; internal initialization traffic is omitted.
Incoming bytes are recorded as received, including messages that are then
rejected, so the transcript of a very large message is as large as the message.

```sh
agentc run --log-file agentc.log --stdio-log-file stdio.log
```

Both files are appended to across runs; their parent directories must already
exist. Transcript lines are written as they complete, and final unterminated
lines are flushed when the session ends. Lines longer than 64 KiB are recorded in
fragments. Stderr stays in the diagnostic stream; in interactive TTY sessions,
the terminal's combined guest output is recorded as `stdout:`.

## Development

Building agentc, running tests, creating static Linux binaries, and building `agentc-bootstrap` are documented in [BUILD.md](./BUILD.md).

## License

[MIT License](./LICENSE).
