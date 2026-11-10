# Local AppleVM TCP benchmark

`scripts/benchmark-socks5-network.py` measures the normal AppleVM NAT path and the
transparent `--socks5-proxy` TCP path against the same synthetic host fixture.
It needs macOS, a signed `agentc` binary with Apple Containerization support,
and Python 3 on the host. The guest uses the standard library in
`python:3.13-slim`; cache that image before measuring. Image acquisition, if
necessary, is the only operation that should need the Internet.

```sh
python3 scripts/benchmark-socks5-network.py \
  --binary /absolute/path/to/signed/agentc \
  --output .build/network-before.json
```

The script prints JSON to stdout and a readable summary to stderr. `--output`
also saves the JSON; its parent directory must already exist. By default, NAT
runs first, followed by SOCKS, with a fresh VM for each. Startup, image
preparation, connection establishment, and expected-checksum generation are
excluded from throughput and RTT timing.

## Workload and interpretation

Each path performs:

- A 32 MiB bulk upload and a separate 32 MiB bulk download.
- Eight simultaneous upload streams, then eight simultaneous download streams.
  Each stream transfers 32 MiB: **256 MiB per concurrent test**, not 32 MiB split
  among the streams. Concurrent throughput is aggregate bytes divided by the
  interval from the first stream's start to the last stream's completion.
- 200 sequential 64-byte request/reply RTT samples on an established connection,
  after ten discarded warmup samples. The summary reports median and nearest-rank
  p95. Both ends enable `TCP_NODELAY`.
- For the SOCKS helper only, cumulative user+system CPU-time deltas from `ps`,
  an initial five-second idle CPU snapshot while the guest waits, and RSS sampled
  during the active workload approximately every 200 ms.

The helper is identified by **both** its direct parent PID (this run's `agentc`)
and the private `--agentc-socks-network-v1` marker. The main process owns the VM;
its CPU and RSS are deliberately not attributed to the networking helper.
NAT has no equivalent helper, so its `helper` field is `null`, not zero.

`active_cpu_seconds` includes all active tests, connection setup, and short
control/observation gaps, but excludes the initial idle interval and VM startup.
Average CPU is expressed as a percentage of **one core** and can exceed 100%.
It is calculated from cumulative CPU-time deltas, not `ps %CPU`. The precision
of `ps time` limits very small deltas; zero means below observable resolution,
not proof of no CPU usage. RSS is resident memory, not total allocated bytes;
`peak_sampled_rss_bytes` is a sampled maximum, not a guaranteed high-water mark.
The sampling subprocesses themselves add a small amount of host load.

The fixture generates its deterministic 64 KiB pattern once. Send and receive
loops use at most 64 KiB per operation and never retain a whole bulk payload.
Expected SHA-256 is precomputed outside timing. The receiver hashes chunks using
the native `hashlib` implementation while receiving; upload timing includes the
receiver's checksum acknowledgement. Integrity checks validate every bulk
transfer, including all eight concurrent streams. Hashing remains part of the
measured receive cost, but there is no Python per-byte loop in the data path.
This is an application-throughput measurement, not a claim about line rate.

The JSON includes host platform/architecture, host and guest Python versions,
`agentc version`, exact binary path, image tag, time, workload size, and the
actual guest destination for each path.
The `comparison` section reports SOCKS/NAT throughput ratios and RTT ratios:
higher throughput ratios are better; lower RTT ratios are better. A tag is not
an immutable image identifier; keep the cached image unchanged between runs.

## Before/after comparisons

Use the same machine, image, run size, and host interface, with other workloads
quiet and the machine on the same power mode. Save separate result files:

```sh
python3 scripts/benchmark-socks5-network.py \
  --binary /absolute/path/to/before/agentc \
  --output .build/network-before.json
python3 scripts/benchmark-socks5-network.py \
  --binary /absolute/path/to/after/agentc \
  --output .build/network-after.json
```

Repeat at least three times, alternating before/after order if possible.
Report each workload's throughput, RTT median/p95, active CPU seconds, idle
CPU seconds over the measured interval, and peak sampled RSS. Also report NAT
results: a changed host baseline can explain apparent SOCKS improvements.
Keep the workload size fixed when comparing total CPU seconds, or normalize by
bytes transferred. Do not replace the full workload with a small smoke run when
claiming performance improvements.

Useful overrides:

```sh
# Smaller functional check: 1 MiB per stream.
python3 scripts/benchmark-socks5-network.py --binary /path/to/agentc --bytes 1048576

# Choose a VM-reachable host interface rather than the guest's NAT gateway.
python3 scripts/benchmark-socks5-network.py --binary /path/to/agentc \
  --host-address 192.168.1.20

# If the host firewall or interface prevents NAT access, measure SOCKS alone.
# This produces no NAT comparison; do not present it as a baseline comparison.
python3 scripts/benchmark-socks5-network.py --binary /path/to/agentc --mode socks
```

The default `--timeout 600` is a deadline per VM run, including startup and idle.
Socket operations also have a timeout. Increase it explicitly for unusually slow
builds or machines. `--idle-seconds` and `--rtt-samples` are configurable, but
retain their defaults for comparable results.

## Local-only fixture and cleanup

The SOCKS listener binds `127.0.0.1` on an ephemeral port. It accepts only the
synthetic IPv4 destination `203.0.113.7:9000`. It never connects upstream, resolves
guest names, executes host commands, or reads host files. It does not require
new DNS or UDP options and works with the baseline TCP `--socks5-proxy` flag.

By default, the NAT listener binds `0.0.0.0` on an ephemeral port and the guest
connects to its IPv4 default gateway parsed from `/proc/net/route`, matching the
existing host MCP relay approach. This avoids depending on a LAN address or the
host's default route, which may be a VPN tunnel. `--host-address` overrides the
guest destination and binds only that selected host IPv4 address.
The default listener is reachable by other machines on host interfaces during the run,
but requires a random 256-bit per-run token and accepts only bounded synthetic
upload/download/echo operations. Use a trusted local network; on a host with a
public interface, select a private host interface explicitly. Do not modify
host firewall rules merely to obtain a baseline.
No public benchmark service is used. Literal IPv4 destinations avoid DNS traffic.

The script creates isolated configuration, profile, workspace, and guest control
files under a temporary `.build/socks-benchmark-*` directory. Empty `noop`
configuration, `--no-toolkit`, `--respect-image-entrypoint`, and
`--no-update-image` keep the workload independent of normal agent setup.
Guest-ready and host-go markers ensure measurement begins after guest startup.
Ordinary failure, Ctrl+C, and SIGTERM trigger process-group/helper termination,
socket closure, and temporary-directory cleanup. SIGKILL or a machine crash
cannot be handled by Python. On failure the captured agent log is printed to
stderr; partial results are not presented as a successful benchmark.

## Validate the harness without a VM

```sh
python3 scripts/benchmark-socks5-network.py --self-test \
  --bytes 1048576 --rtt-samples 30 --timeout 30
```

This executes the same workload in a host Python subprocess against both native
loopback fixtures, including an explicit SOCKS handshake for the SOCKS fixture.
It tests protocol handling, chunking, checksums, concurrency, JSON, and cleanup;
it **does not** exercise AppleVM, packet translation, helper sampling, or real NAT.
Its output is marked `"self_test": true` and is not network performance evidence
for `agentc`.

## Validation sample

Local validation on arm64 macOS 27.0 with Swift 6.4.2, the default 32 MiB workload,
and a synthetic loopback SOCKS server produced the following **release-build**
results across three consecutive runs:

| Measurement | Median | Range |
|---|---:|---:|
| Single upload | 126.3 MiB/s | 108.3–129.9 |
| Single download | 211.0 MiB/s | 169.1–212.5 |
| Eight-stream aggregate upload | 78.3 MiB/s | 76.6–78.6 |
| Eight-stream aggregate download | 277.8 MiB/s | 277.7–278.3 |
| Established echo RTT | 0.175 ms | 0.173–0.180 |
| Echo p95 | 0.212 ms | 0.197–0.221 |
| Helper peak sampled RSS | 69.5 MiB | 69.5–69.7 |

The workload moves 576 MiB in total. Helper CPU time was 9.85–10.05 CPU seconds,
averaging about two cores while saturating local transfers. Idle CPU was below
the `ps time` measurement resolution (0.01 CPU seconds over the five-second idle
sample) in all three runs. The separate readiness harness measured roughly
0.05–0.1% of one core while quiet, including the maintenance timer.

A like-for-like **debug-build** before/after comparison isolated the scheduling
change: single upload/download improved from about 2.06/2.06 MiB/s to
58.9/94.6 MiB/s, while median RTT fell from 12.53ms to 0.20ms. Peak sampled RSS
was about 31 MiB before and 29 MiB after. Do not attribute the larger release
numbers entirely to scheduling; optimization mode matters.

This is not zero-overhead NAT: the local NAT fixture achieved roughly
1–3 GiB/s, substantially faster than userspace packet/proxy processing.
Concurrent upload is also slower than a single upload in this sample. These
measurements characterize the adapter on this machine, not Internet speed,
third-party proxy interoperability, maximum UDP packet rate, or a universal
performance guarantee. UDP functionality and isolation are covered by the
separate real-VM smoke test; this throughput benchmark is TCP-only.
