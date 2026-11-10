# Enforced SOCKS5 networking (Apple Containerization)

Use `--socks5-proxy socks5://HOST:PORT` to replace the guest's ordinary network
attachment with a host-side SOCKS5 adapter:

```sh
agentc run --socks5-proxy socks5://127.0.0.1:1080
```

Or opt in per project:

```json
{
  "agent": {
    "socks5Proxy": "socks5://127.0.0.1:1080"
  }
}
```

The CLI overrides the project setting. Unset means existing networking is
unchanged. Empty or invalid values are errors, not an instruction to disable the
proxy. Docker rejects this setting; it does not silently run unrestricted.
Malformed/unreadable project settings also fail CLI startup instead of falling
back to defaults.

## Transparent to the guest

The adapter runs **on the Mac**, in a child process of the same `agentc`
executable. No extra binary is installed. The child handles guest Ethernet
packets using lwIP and Swift networking code; it opens ordinary upstream TCP
connections only to the configured SOCKS5 endpoint.

There is no simultaneous NAT attachment. Guest root cannot restore direct
internet access by changing routes. If the proxy or child fails, connections
fail; agentc never falls back to direct networking.

Applications use ordinary sockets. agentc does not inject proxy variables,
credentials, a proxy client, or a guest-side helper. The guest sees a virtual
Ethernet device and a DNS resolver/default gateway. If the proxy URL is in the
mounted project's settings, the guest can read that file, just as with other
project files. Public egress IP, latency, and unsupported protocols may still
reveal that traffic passes through an intermediary; this is transparency, not
undetectability.

`127.0.0.1` in the proxy URL refers to the **Mac**, not the container. A hostname
for the proxy itself is resolved by the Mac before connecting. Guest DNS queries
do not use the Mac's resolver.

## Supported traffic

- IPv4 TCP, transparently tunneled using SOCKS5 `CONNECT`.
- Guest UDP DNS to the configured gateway resolver, forwarded as DNS-over-TCP
  through SOCKS5 to `1.1.1.1:53`. TCP DNS to that gateway uses the same resolver,
  including fallback after a truncated UDP answer.
- IPv6, other UDP (including QUIC/HTTP/3), ICMP, and fragmented IP traffic are
  blocked in this first version. Applications that support it may fall back from
  QUIC to HTTPS over TCP.
- TLS remains end-to-end. No interception CA is installed.

The proxy must permit the relevant destination ports, including TCP port 53 for
DNS. Custom DNS traffic over ordinary TCP follows the same SOCKS5 path as any
other TCP connection.

Resource limits are deliberately bounded: 128 TCP flows (including lwIP's
TIME_WAIT state), 32 concurrent UDP DNS jobs, a 20-second connection deadline,
a 15-second UDP DNS deadline, and a one-hour established inactivity timeout.
Exceeding a limit fails or drops traffic; it never enables a direct path.

## Authentication

For username/password authentication, supply both host environment variables
`AGENTC_SOCKS5_USERNAME` and `AGENTC_SOCKS5_PASSWORD` through your shell or secret
manager. Omit both for unauthenticated SOCKS5.

Credentials in the URL are rejected so they cannot accidentally be persisted by
`agentc init`. Credentials are not put in the helper's arguments, environment,
logs, or guest environment; they are sent over a private parent/child socket.
Do not store them in project settings.

SOCKS5 itself does not encrypt the connection to the proxy, including its
username/password handshake. Use a trusted local endpoint or a separately
secured transport for remote proxies.

## Host bridges and the boundary of enforcement

`--allow-host-binaries` and ACP `--bridge-host-stdio-mcp` remain supported.

- Host-binary relays continue to use the existing Unix-socket/vsock transport.
- With host stdio MCP enabled, the adapter permits one explicit local exception:
  the guest gateway's selected MCP port connects to the Mac's loopback listener
  on that same port. The listener still requires its per-definition capability.
  This is not a general host-network bypass.
- Commands executed on the host through either bridge are **outside the guest
  network policy** and may use the Mac's ordinary network access. Enabling those
  bridges grants host execution as before.

Host-side image/kernel downloads and configuration-repository updates are also
outside this setting.

## Implementation boundary

The networking child has a separate address space and lifetime, not an additional
macOS security sandbox. It runs with the user's privileges. Packet processing,
policy, SOCKS5, and scheduling are Swift; lwIP and its narrow interop adapter are
C. See `Sources/CSOCKSNetwork/vendor/README.md` for the pinned dependency and
license.
