# lwIP

Unmodified `COPYING`, `src/include`, `src/core`, and `src/netif/ethernet.c` from:

- https://github.com/lwip-tcpip/lwip
- Tag: `STABLE-2_2_1_RELEASE`
- Archive: https://github.com/lwip-tcpip/lwip/archive/refs/tags/STABLE-2_2_1_RELEASE.tar.gz
- Archive SHA-256: `ce0b7461c0ad9602c376f0bf07c5eb7253b48c7bf66f011c6bf3e2a96731c539`

The target compiles only the core IPv4/Ethernet sources listed in `Package.swift`.
Port configuration lives outside the upstream tree in `../port`. No upstream
patches are required: the adapter translates TCP tuples before/after lwIP.

Retain `lwip/COPYING` in source distributions and reproduce it in binary release
notices (`agentc` also exposes it with `--third-party-notices`).
