# Packet engine validation

Run on macOS:

```sh
sh scripts/test-packet-engine.sh
SANITIZE=address sh scripts/test-packet-engine.sh --control-eof
SANITIZE=address sh scripts/test-packet-engine.sh --readiness --control-eof
```

This compiles the production Swift packet engine with Swift 6 complete
concurrency checking and warnings as errors, the actual unmodified lwIP
sources with C warnings as errors, and a deterministic **mock SOCKS transport**.
It does not exercise real SOCKS socket IO, authentication, Virtualization,
guest kernel TCP, or VM startup. The separate SOCKS transport tests and real-VM
integration test must cover those boundaries.

`--readiness` selects the separate scheduling harness. It tests bounded/coalesced
notifications, idle CPU, quiet cancellation/control EOF, and an async Dispatch
cancellation barrier before descriptor reuse. `--readiness-failure` exercises
cleanup when the parent cannot receive the readiness byte.

The standalone test covers:

- Short/malformed packets, checksum corruption, fragments, unsupported
  protocols, and 10,000 deterministic arbitrary frames.
- ARP identity, TCP interception before SYN, reverse translation and checksums.
- Echo, bidirectional FIN, proxy refusal to guest RST.
- 1 MiB upload, guest SHUT_WR, then a 1 MiB download: upstream sends are
  deliberately delayed and the mock withholds all responses until guest EOF.
- Upstream EOF before guest data/FIN.
- Backpressured upload and guest FIN, then upstream EOF and immediate guest
  ACK of LAST_ACK: PCB destruction must not cancel the still-draining upload.
- 140 sequential refusals, exceeding the 128-slot table without exhaustion.
- UDP DNS translated into framed TCP to a configured non-default SOCKS resolver, oversized
  reply truncation, and guest TCP DNS fallback to that same resolver.
- Generic UDP datagram boundaries/checksums, empty/1472-byte payloads, distinct
  associations for two guest source ports, and the 64-flow association cap.
- The exact gateway-address/host-MCP-port exception.
- Readiness, control input or EOF shutdown, and borrowed descriptor ownership.

## Implementation invariants

The private child owns one process-global lwIP instance. A Swift actor serializes
all lwIP calls and synchronous callbacks. Only `LWIPOutput.swift` and the POSIX
socket calls borrow pointers; parsing and rewriting operate on checked Swift
arrays. The C adapter manages lwIP PCB/pbuf lifetimes, not host networking policy.

There are at most 128 translated TCP flows and 32 DNS jobs. Each TCP flow has a
32 KiB advertised receive window and a 32 KiB lwIP send buffer, plus one at-most
16 KiB proxy receive chunk. Guest receive data stays in a bounded pbuf chain;
only the exact prefix successfully sent to the proxy is consumed and credited
with `tcp_recved`. A single copied upload prefix is held across a socket await.
The global output queue holds at most 256 MTU-sized frames; overflow drops frames
rather than allocating without bound. Socket IO and per-turn frame work are
nonblocking/bounded. DNS-over-TCP answers are bounded by their 16-bit length.
UDP has a separate pool of 64 associations, each with eight queued datagrams and
at most one in-flight send. Inactive associations expire after 60 seconds.

Mappings remain allocated while lwIP owns a PCB (including TIME_WAIT) or output
still references the translated port. PCB destruction is distinct from upstream
completion: an orderly LAST_ACK can precede a backpressured socket send.
Failed connections recycle after their queued output drains; there is no second
TIME_WAIT delay. Handshake/connect timeout is 20 seconds, DNS timeout 15 seconds,
and established inactivity timeout one hour. Transport-level timeouts can be
shorter. These are resource limits, not promises of indefinitely idle connections.

## Intentionally unsupported

IPv6, ICMP, IPv4 fragments/options, VLAN frames, and compressed gateway DNS
query names are dropped. IPv4 TCP and UDP are transparently proxied. DNS
at `10.87.0.1:53` (both UDP and TCP) uses SOCKS CONNECT to the configured
upstream (`1.1.1.1:53` by default). Oversized DNS UDP answers return a complete TC response
so the guest can retry TCP. The only direct host socket exception is the exact
configured MCP port at the gateway, connected to host `127.0.0.1`; ports 0 and 53
are invalid MCP settings. No guest-selected hostname reaches the host resolver.
