# SOCKS5 networking

## Usage

On Apple Containerization, route container traffic through a SOCKS5 proxy:

```sh
agentc run --socks5-proxy socks5://127.0.0.1:1080
```

Optionally choose the upstream DNS resolver:

```sh
agentc run \
  --socks5-proxy socks5://127.0.0.1:1080 \
  --socks5-dns 9.9.9.9:53
```

Or set defaults in `.agentc/settings.json`:

```json
{
  "agent": {
    "socks5Proxy": "socks5://127.0.0.1:1080",
    "socks5Dns": "9.9.9.9:53"
  }
}
```

CLI options override project settings. Without a proxy setting, networking is
unchanged. `127.0.0.1` in the proxy URL refers to the **Mac**, not the container.

DNS defaults to `1.1.1.1:53`. A custom resolver requires a proxy and must use
`IPv4:PORT` with a numeric IPv4 address and nonzero port. Upstream DNS always uses
TCP through the proxy; the legacy `tcp://IPv4:PORT` form is also accepted.

For authentication, supply both `AGENTC_SOCKS5_USERNAME` and
`AGENTC_SOCKS5_PASSWORD` in the **host environment** through your shell or secret
manager. Omit both for an unauthenticated proxy. Credentials in URLs are rejected;
do not store credentials in project settings.

## Behavior

- **Transparent to applications:** no proxy-aware application setup is needed.
  agentc does not inject proxy variables or credentials into the container.
  Settings stored in a mounted project file remain readable there.
- **No direct fallback:** if the proxy fails, traffic fails rather than bypassing
  it. Invalid settings are errors, not an instruction to disable the proxy.
- **IPv4 TCP and UDP are supported.** UDP requires a proxy with `UDP ASSOCIATE`
  support and a reachable UDP relay. TCP-only proxies, including ordinary OpenSSH
  dynamic forwarding, cannot carry UDP.
- **Gateway DNS always goes through SOCKS5 over TCP**, even when the application
  sends a UDP query. The container sees its gateway as the resolver. Queries sent
  to another DNS address use ordinary proxied TCP or UDP.
- **TLS remains end-to-end.** SOCKS5 itself does not encrypt traffic to the proxy,
  including its authentication handshake; use a trusted local proxy or a
  separately secured connection.
- **Host bridges remain available.** Commands run through `--allow-host-binaries`
  or ACP `--bridge-host-stdio-mcp` execute on the host and are outside this network
  policy. Host-side image/kernel downloads and configuration updates are also
  outside the policy.

## Limits

- Apple Containerization only; Docker rejects these settings.
- IPv6 container traffic, ICMP, and fragmented IP packets are blocked.
- UDP payloads may be empty or up to **1472 bytes**. Network MTU and firewall
  restrictions can still cause loss. Domain-name UDP relay addresses and SOCKS
  fragmentation are unsupported.
- The proxy must allow the requested destinations, including the DNS resolver's
  TCP port.

| Traffic | Capacity | Timeouts |
|---|---|---|
| TCP | 128 flows, including connections in TIME_WAIT | 20 seconds to establish; one hour idle |
| UDP | 64 flows; eight queued datagrams per flow, plus one in flight | 60 seconds idle |
| Gateway UDP DNS | 32 concurrent requests | 15 seconds per request |

Exceeding a limit fails or drops traffic; it never enables direct access.
