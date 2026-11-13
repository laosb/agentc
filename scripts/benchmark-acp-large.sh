#!/bin/sh
# Measure forwarding of one very large ACP message through the proxy pipeline:
# framing/validation thread, flow-control window, spool, proxy, and the
# pull-based backend stream. The ~321 MiB payload is synthetic; no container,
# network, or user data is involved.
#
#   scripts/benchmark-acp-large.sh [size-in-MiB] [extra swift test arguments]
#
# Reports throughput and peak resident memory growth, and fails if memory
# grows with the message instead of staying bounded.
set -eu
cd "$(dirname "$0")/.."
size=${1:-321}
[ $# -eq 0 ] || shift
AGENTC_ACP_BENCHMARK=1 AGENTC_ACP_BENCHMARK_MIB="$size" exec swift test -c release \
  -Xswiftc -enable-testing --filter 'ACPTransferTests/largePromptBenchmark' "$@"
