#!/usr/bin/env python3
"""Real Apple VM smoke test using a local SOCKS5 fixture, never a public proxy.

Usage: python3 scripts/test-socks5-network.py [path/to/signed/agentc]
       python3 scripts/test-socks5-network.py --self-test
AGENTC_TEST_SOCKS_IMAGE defaults to python:3.13-slim. The host may need to pull it.
All guest destinations are synthetic: the fixture serves DNS and TCP/UDP echo
without opening any upstream sockets. UDP sockets bind only to host loopback.
Artifacts stay under the checkout's .build. --self-test needs no VM or agentc.
"""

import os
from pathlib import Path
import select
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time


DNS_UPSTREAM = ("198.51.100.53", 5353)
ECHO_ADDRESS = "203.0.113.7"
GATEWAY_UDP_ID = 0xA101
GATEWAY_TCP_ID = 0xA102


GUEST = r'''
import errno, os, socket, struct, sys, time
from pathlib import Path

def read_exact(conn, count):
    result = bytearray()
    while len(result) < count:
        chunk = conn.recv(count - len(result))
        assert chunk, "unexpected TCP EOF"
        result += chunk
    return bytes(result)

def query(identifier):
    name = b"\x11agentc-proxy-test\x07invalid\x00"
    # The first label is 17 bytes.
    return struct.pack("!6H", identifier, 0x100, 1, 0, 0, 0) + name + b"\x00\x01\x00\x01"

def check_answer(answer, identifier):
    assert len(answer) >= 12 and struct.unpack("!H", answer[:2])[0] == identifier
    assert answer[2:4] == b"\x81\x80" and answer[-4:] == socket.inet_aton("203.0.113.7")

def no_datagram(sock):
    timeout = sock.gettimeout()
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            sock.settimeout(max(0.001, deadline - time.monotonic()))
            try:
                received = sock.recvfrom(4096)
            except TimeoutError:
                return
            except (ConnectionRefusedError, ConnectionResetError):
                # An early ICMP error must not shorten the control-close test:
                # keep listening for the fixture's delayed, now-invalid reply.
                continue
            raise AssertionError(("fail-closed UDP carried data", received))
    finally:
        sock.settimeout(timeout)

def expect_datagram(sock, expected, destination):
    actual, source = sock.recvfrom(4096)
    assert (actual, source) == (expected, destination), (len(actual), actual[:64], source)

assert not any(k.lower() in ("http_proxy", "https_proxy", "all_proxy")
               or k.startswith("AGENTC_SOCKS5_") for k in os.environ)
mode = sys.argv[1]
if mode != "accepted":
    # Command-not-supported and policy-rejected associations must not fall back
    # to CONNECT or to direct UDP. The host verifies command 3 was attempted.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        udp.settimeout(3)
        udp.sendto(b"rejected-association", ("203.0.113.7", 9000))
        no_datagram(udp)
    print("PASS: UDP association " + mode + " fails closed", flush=True)
    sys.exit(0)

assert socket.gethostbyname("agentc-proxy-test.invalid") == "203.0.113.7"
# Distinct transaction IDs let the host prove both gateway protocols used the
# configured nondefault address AND port, not the old resolver or UDP ASSOCIATE.
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as dns:
    dns.settimeout(10)
    dns.sendto(query(0xA101), ("10.87.0.1", 53))
    answer, source = dns.recvfrom(4096)
    assert source == ("10.87.0.1", 53), source
    check_answer(answer, 0xA101)
with socket.create_connection(("10.87.0.1", 53), timeout=10) as dns:
    message = query(0xA102)
    dns.sendall(struct.pack("!H", len(message)) + message)
    check_answer(read_exact(dns, struct.unpack("!H", read_exact(dns, 2))[0]), 0xA102)

payload = bytes(range(256)) * 4096
with socket.create_connection(("203.0.113.7", 9000), timeout=15) as conn:
    conn.sendall(payload)
    conn.shutdown(socket.SHUT_WR)
    result = bytearray()
    while chunk := conn.recv(16384):
        result += chunk
    assert result == payload, (len(result), len(payload))
try:
    with socket.create_connection(("203.0.113.8", 9000), timeout=3) as rejected:
        # The guest TCP handshake terminates at lwIP before SOCKS CONNECT
        # finishes. A refused upstream must reset/close, never carry payload.
        rejected.sendall(b"must-not-be-forwarded")
        assert not rejected.recv(64), "proxy refusal carried application data"
except OSError:
    pass
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
    udp.settimeout(10)
    destination = ("203.0.113.7", 9000)
    # One tuple must retain one association. Sequential sends avoid testing an
    # unspecified overload policy for the engine's eight-datagram queue.
    for message in [b"first", b"", bytes(range(256)) * 5 + bytes(range(192))]:
        udp.sendto(message, destination)
        expect_datagram(udp, message, destination)
    for index in range(24):
        message = ("repeat-%02d" % index).encode()
        udp.sendto(message, destination)
        expect_datagram(udp, message, destination)
    # Every valid reply is preceded by invalid SOCKS headers with a distinctive
    # payload. No malformed envelope may escape as an extra guest datagram.
    udp.settimeout(0.5)
    no_datagram(udp)
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as left, \
     socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as right:
    destination = ("203.0.113.7", 9000)
    left.settimeout(10)
    right.settimeout(10)
    # Both flows are live concurrently; different lengths expose coalescing,
    # truncation, reordering, and cross-delivery between the same destination.
    for message in [b"L", b"left-two", b"left-three-longer"]:
        left.sendto(message, destination)
    for message in [b"right-one", b"R", b"right-three-longer-still"]:
        right.sendto(message, destination)
    for message in [b"L", b"left-two", b"left-three-longer"]:
        expect_datagram(left, message, destination)
    for message in [b"right-one", b"R", b"right-three-longer-still"]:
        expect_datagram(right, message, destination)
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as dns:
    dns.settimeout(10)
    destination = ("203.0.113.7", 53)
    # Non-gateway DNS is ordinary UDP, not redirected to the configured DNS
    # server. The synthetic UDP relay echoes rather than resolving this query.
    message = query(0xA103)
    dns.sendto(message, destination)
    expect_datagram(dns, message, destination)
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
    udp.settimeout(10)
    destination = ("203.0.113.7", 9002)
    udp.sendto(b"before-close", destination)
    expect_datagram(udp, b"before-close", destination)
    udp.sendto(b"close-control", destination)
    # Fixture closes TCP, keeps its UDP socket briefly alive, and sends a valid
    # late reply. Closing the association must discard that reply as well.
    udp.settimeout(2)
    no_datagram(udp)
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
    udp.settimeout(1)
    try:
        # Linux normally fragments this above-MTU datagram. EMSGSIZE is also a
        # valid rejection if the guest stack refuses fragmentation.
        udp.sendto(b"fragment" * 250, ("203.0.113.7", 9010))
    except OSError as error:
        assert error.errno == errno.EMSGSIZE, error
    else:
        no_datagram(udp)
with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as ipv6:
    ipv6.settimeout(0.5)
    try:
        ipv6.connect(("2001:db8::1", 9000))
        raise AssertionError("IPv6 was not blocked")
    except OSError:
        pass
with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as ipv6:
    ipv6.settimeout(0.5)
    try:
        ipv6.sendto(b"unsupported IPv6 UDP", ("2001:db8::1", 9000))
    except OSError:
        pass
    else:
        no_datagram(ipv6)
Path("ready-to-kill-helper").touch()
deadline = time.monotonic() + 20
while not Path("helper-killed").exists():
    assert time.monotonic() < deadline, "host did not kill networking helper"
    time.sleep(0.05)
try:
    with socket.create_connection(("203.0.113.7", 9000), timeout=3) as conn:
        conn.sendall(b"after-helper-kill")
        conn.shutdown(socket.SHUT_WR)
        assert not conn.recv(64), "helper failure carried TCP payload"
except OSError:
    pass
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
    udp.settimeout(1)
    udp.sendto(b"after-helper-kill", ("203.0.113.7", 9000))
    no_datagram(udp)
print("PASS: TCP 1MiB half-close, configured UDP/TCP gateway DNS, hidden auth, "
      "UDP boundaries/empty/1472/repeats/isolation/non-gateway DNS, "
      "malformed replies/control closure/refusal/fragments/IPv6/helper fail closed",
      flush=True)
'''


def read_exact(stream, count):
    result = bytearray()
    while len(result) < count:
        chunk = stream.recv(count - len(result))
        if not chunk:
            raise EOFError()
        result += chunk
    return bytes(result)


class Proxy(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = False

    def __init__(self, udp_reply=0):
        super().__init__(("127.0.0.1", 0), Handler)
        self.udp_reply = udp_reply
        self.requests = []
        self.dns_queries = []
        self.udp_packets = []
        self.closed_controls = []
        self.errors = []
        self.connections = set()
        self.stopping = threading.Event()
        self.lock = threading.Lock()

    def server_close(self):
        self.stopping.set()
        with self.lock:
            for conn in self.connections:
                try:
                    conn.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        # ThreadingMixIn joins all non-daemon handlers. UDP loops observe stop
        # within 100ms; blocked authentication/CONNECT reads were woken above.
        super().server_close()


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        with self.server.lock:
            self.server.connections.add(self.request)
        try:
            self.serve()
        except (EOFError, OSError):
            pass
        except Exception as error:
            with self.server.lock:
                self.server.errors.append(repr(error))
        finally:
            with self.server.lock:
                self.server.connections.discard(self.request)

    def serve(self):
        conn = self.request
        conn.settimeout(20)
        version, count = read_exact(conn, 2)
        assert version == 5 and 2 in read_exact(conn, count)
        conn.sendall(b"\x05\x02")
        version, count = read_exact(conn, 2)
        assert version == 1 and read_exact(conn, count) == b"fixture-user"
        count = read_exact(conn, 1)[0]
        assert read_exact(conn, count) == b"fixture-password"
        conn.sendall(b"\x01\x00")
        version, command, reserved, kind = read_exact(conn, 4)
        assert (version, reserved, kind) == (5, 0, 1)
        assert command in (1, 3), command
        destination = socket.inet_ntoa(read_exact(conn, 4))
        port = struct.unpack("!H", read_exact(conn, 2))[0]
        with self.server.lock:
            association = len(self.server.requests)
            self.server.requests.append((command, destination, port))
        if command == 3:
            self.serve_udp(conn, association)
            return
        permitted = (destination, port) in [(ECHO_ADDRESS, 9000), DNS_UPSTREAM]
        reply = bytes([5, 0 if permitted else 2, 0, 1]) + b"\0" * 6
        # Exercise partial protocol reads, rather than one convenient recv().
        for byte in reply:
            conn.sendall(bytes([byte]))
        if not permitted:
            return
        if (destination, port) == DNS_UPSTREAM:
            length = struct.unpack("!H", read_exact(conn, 2))[0]
            query = read_exact(conn, length)
            assert 12 <= len(query) <= 4096
            with self.server.lock:
                self.server.dns_queries.append(
                    (struct.unpack("!H", query[:2])[0], destination, port))
            answer = (
                query[:2] + b"\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00"
                + query[12:]
                + b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04"
                + socket.inet_aton(ECHO_ADDRESS)
            )
            conn.sendall(struct.pack("!H", len(answer)) + answer)
        else:
            payload = bytearray()
            while chunk := conn.recv(16384):
                payload += chunk
                assert len(payload) <= 1024 * 1024
            conn.sendall(payload)

    def serve_udp(self, conn, association):
        if self.server.udp_reply:
            conn.sendall(bytes([5, self.server.udp_reply, 0, 1]) + b"\0" * 6)
            return
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as relay:
            relay.bind(("127.0.0.1", 0))
            conn.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1")
                         + struct.pack("!H", relay.getsockname()[1]))
            peer = None
            target = None
            while not self.server.stopping.is_set():
                readable, _, _ = select.select([conn, relay], [], [], 0.1)
                if conn in readable:
                    assert not conn.recv(1), "UDP control carried application data"
                    return
                if relay not in readable:
                    continue
                packet, sender = relay.recvfrom(65535)
                assert sender[0] == "127.0.0.1", sender
                assert len(packet) >= 10 and packet[:4] == b"\0\0\0\x01", packet[:10]
                destination = socket.inet_ntoa(packet[4:8])
                port = struct.unpack("!H", packet[8:10])[0]
                payload = packet[10:]
                assert destination == ECHO_ADDRESS and port in (53, 9000, 9002), (destination, port)
                assert len(payload) <= 1472, len(payload)
                # Each association belongs to one guest tuple and one helper
                # UDP socket, never a shared relay for unrelated guest flows.
                if peer is None:
                    peer, target = sender, (destination, port)
                assert peer == sender and target == (destination, port)
                with self.server.lock:
                    self.server.udp_packets.append(
                        (association, sender, destination, port, payload))
                if port == 9002 and payload == b"close-control":
                    conn.shutdown(socket.SHUT_RDWR)
                    with self.server.lock:
                        self.server.closed_controls.append(association)
                    # Valid source, target and payload, but control is dead.
                    if not self.server.stopping.wait(0.5):
                        relay.sendto(packet, peer)
                    return
                invalid = b"invalid-envelope-must-not-reach-guest"
                headers = [
                    b"\0\x01" + packet[2:10],       # Nonzero RSV.
                    packet[:2] + b"\x01" + packet[3:10],  # Fragmented SOCKS UDP.
                    packet[:4] + socket.inet_aton("203.0.113.8") + packet[8:10],
                    packet[:8] + struct.pack("!H", port + 1),
                ]
                for header in headers:
                    relay.sendto(header + invalid, peer)
                relay.sendto(packet, peer)


def children(pid):
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True)
    result = []
    for line in output.splitlines():
        fields = line.strip().split(maxsplit=2)
        if len(fields) == 3 and int(fields[1]) == pid and "--agentc-socks-network-v1" in fields[2]:
            result.append(int(fields[0]))
    return result


def check_fixture(proxy, mode):
    assert not proxy.errors, proxy.errors
    associations = [index for index, request in enumerate(proxy.requests) if request[0] == 3]
    connects = [request[1:] for request in proxy.requests if request[0] == 1]
    if mode != "accepted":
        assert associations, proxy.requests
        assert not connects and not proxy.udp_packets, proxy.requests
        return
    assert DNS_UPSTREAM in connects, proxy.requests
    assert (ECHO_ADDRESS, 9000) in connects, proxy.requests
    assert ("203.0.113.8", 9000) in connects, proxy.requests
    assert all(target in (DNS_UPSTREAM, (ECHO_ADDRESS, 9000), ("203.0.113.8", 9000))
               for target in connects), connects
    for identifier in (GATEWAY_UDP_ID, GATEWAY_TCP_ID):
        assert (identifier, *DNS_UPSTREAM) in proxy.dns_queries, proxy.dns_queries
    # Sequential/repeated datagrams, two simultaneous sockets, non-gateway DNS,
    # and control-close test: five tuples, exactly five associations.
    assert len(associations) == 5, proxy.requests
    assert len(proxy.udp_packets) == 36, len(proxy.udp_packets)
    assert len(proxy.closed_controls) == 1, proxy.closed_controls
    first = [record for record in proxy.udp_packets if record[4] == b"first"]
    assert len(first) == 1, first
    repeated = [record for record in proxy.udp_packets if record[0] == first[0][0]]
    assert len(repeated) == 27 and {len(record[4]) for record in repeated} >= {0, 1472}
    left = next(record for record in proxy.udp_packets if record[4] == b"L")
    right = next(record for record in proxy.udp_packets if record[4] == b"R")
    assert left[0] != right[0] and left[1] != right[1], (left, right)
    assert {record[0] for record in proxy.udp_packets} == set(associations)


def stop_process(process):
    # A separate process group covers helper descendants even when agentc fails
    # before the harness finds the helper PID. Never leave a child VM launcher
    # behind after a timeout or failed assertion.
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=15 if sig == signal.SIGTERM else 5)
        except subprocess.TimeoutExpired:
            if sig == signal.SIGKILL:
                raise


def run_case(binary, root, mode, udp_reply):
    root.mkdir()
    configs = root / "configs"
    (configs / ".git").mkdir(parents=True)
    (configs / ".agentc-last-pull").touch()
    (configs / "noop").mkdir()
    (configs / "noop/settings.json").write_text("{}")
    (root / "settings.json").write_text("{}")
    (root / "guest.py").write_text(GUEST)
    with Proxy(udp_reply) as proxy:
        thread = threading.Thread(target=proxy.serve_forever)
        thread.start()
        try:
            env = os.environ | {
                "AGENTC_SOCKS5_USERNAME": "fixture-user",
                "AGENTC_SOCKS5_PASSWORD": "fixture-password",
            }
            args = [
                str(binary), "run", "--runtime", "apple-container",
                "--socks5-proxy", f"socks5://127.0.0.1:{proxy.server_address[1]}",
                "--socks5-dns", f"{DNS_UPSTREAM[0]}:{DNS_UPSTREAM[1]}",
                "--image", os.environ.get("AGENTC_TEST_SOCKS_IMAGE", "python:3.13-slim"),
                "--respect-image-entrypoint", "--no-toolkit", "--no-update-image",
                "--configurations-dir", str(configs), "-c", "noop",
                "--profile-dir", str(root / "profile"), "--workspace", str(root),
                "--agentc-folder", str(root), "--suppress-migration-from-claudec",
                "--", "/usr/local/bin/python3", "guest.py", mode,
            ]
            # Files, unlike undrained PIPEs, cannot deadlock a verbose launcher
            # while the host waits for the guest's helper-kill checkpoint.
            with (root / "stdout.log").open("w+b") as stdout_file, \
                 (root / "stderr.log").open("w+b") as stderr_file:
                process = subprocess.Popen(args, stdout=stdout_file, stderr=stderr_file,
                                           env=env, start_new_session=True)
                try:
                    if mode == "accepted":
                        deadline = time.monotonic() + 180
                        while not (root / "ready-to-kill-helper").exists():
                            assert process.poll() is None, "guest exited before helper-kill checkpoint"
                            assert time.monotonic() < deadline, "guest smoke test timed out"
                            time.sleep(0.05)
                        helpers = children(process.pid)
                        assert len(helpers) == 1, helpers
                        os.kill(helpers[0], signal.SIGKILL)
                        (root / "helper-killed").touch()
                    process.wait(timeout=30 if mode == "accepted" else 180)
                    assert process.returncode == 0, process.returncode
                    stdout_file.seek(0)
                    stdout = stdout_file.read()
                    assert b"PASS:" in stdout, stdout
                    # Stop and join handlers before inspecting fixture records.
                    proxy.shutdown()
                    thread.join(timeout=5)
                    assert not thread.is_alive(), "fixture server thread leaked"
                    proxy.server_close()
                    check_fixture(proxy, mode)
                    print(stdout.decode(), end="")
                except Exception:
                    stdout_file.seek(0)
                    stderr_file.seek(0)
                    print(f"{mode} guest stdout:\n{stdout_file.read().decode(errors='replace')}",
                          file=sys.stderr)
                    print(f"{mode} guest stderr:\n{stderr_file.read().decode(errors='replace')}",
                          file=sys.stderr)
                    raise
                finally:
                    stop_process(process)
        finally:
            proxy.shutdown()
            thread.join(timeout=5)
            assert not thread.is_alive(), "fixture server thread leaked"


def self_test():
    """Validate fixture framing and lifecycle using only local client sockets."""
    compile(GUEST, "<guest.py>", "exec")

    def connect(proxy, command, target):
        conn = socket.create_connection(proxy.server_address, timeout=3)
        try:
            conn.sendall(b"\x05\x01\x02")
            assert read_exact(conn, 2) == b"\x05\x02"
            conn.sendall(b"\x01\x0cfixture-user\x10fixture-password")
            assert read_exact(conn, 2) == b"\x01\x00"
            conn.sendall(bytes([5, command, 0, 1]) + socket.inet_aton(target[0])
                         + struct.pack("!H", target[1]))
            reply = read_exact(conn, 10)
            assert reply[:1] == b"\x05" and reply[2:4] == b"\0\x01", reply
            endpoint = (socket.inet_ntoa(reply[4:8]), struct.unpack("!H", reply[8:10])[0])
            return conn, reply[1], endpoint
        except BaseException:
            conn.close()
            raise

    for status in (0, 7, 2):
        with Proxy(status) as proxy:
            thread = threading.Thread(target=proxy.serve_forever)
            thread.start()
            try:
                conn, reply, endpoint = connect(proxy, 3, ("0.0.0.0", 0))
                with conn:
                    assert reply == status
                    if status == 0:
                        assert endpoint[0] == "127.0.0.1" and endpoint[1] > 0
                        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                            udp.settimeout(3)
                            header = b"\0\0\0\x01" + socket.inet_aton(ECHO_ADDRESS) + struct.pack("!H", 9002)
                            for payload in (b"", b"x" * 1472, b"repeat"):
                                udp.sendto(header + payload, endpoint)
                                replies = [udp.recvfrom(4096) for _ in range(5)]
                                assert all(source == endpoint for _, source in replies)
                                assert all(packet != header + payload for packet, _ in replies[:4])
                                assert replies[-1][0] == header + payload
                            udp.sendto(header + b"close-control", endpoint)
                            assert conn.recv(1) == b""
                            assert udp.recvfrom(4096) == (header + b"close-control", endpoint)
                    else:
                        assert conn.recv(1) == b""
                if status == 0:
                    # Exercise fragmented reply reads, DNS, TCP half-close,
                    # refusal, and stopping an idle live association.
                    for target in (DNS_UPSTREAM, (ECHO_ADDRESS, 9000), ("203.0.113.8", 9000)):
                        conn, reply, _ = connect(proxy, 1, target)
                        with conn:
                            if target == DNS_UPSTREAM:
                                assert reply == 0
                                query = b"\xa1\x01\x01\0\0\x01\0\0\0\0\0\0\x01x\0\0\x01\0\x01"
                                conn.sendall(struct.pack("!H", len(query)) + query)
                                answer = read_exact(conn, struct.unpack("!H", read_exact(conn, 2))[0])
                                assert answer[:2] == query[:2] and answer[-4:] == socket.inet_aton(ECHO_ADDRESS)
                            elif target[0] == ECHO_ADDRESS:
                                assert reply == 0
                                payload = bytes(range(256)) * 4096
                                conn.sendall(payload)
                                conn.shutdown(socket.SHUT_WR)
                                assert read_exact(conn, len(payload)) == payload
                                assert conn.recv(1) == b""
                            else:
                                assert reply == 2 and conn.recv(1) == b""
                    conn, reply, _ = connect(proxy, 3, ("0.0.0.0", 0))
                    with conn:
                        assert reply == 0
                        proxy.server_close()
                        assert conn.recv(1) == b""
            finally:
                proxy.shutdown()
                thread.join(timeout=5)
                assert not thread.is_alive(), "fixture self-test thread leaked"
                proxy.server_close()
            assert not proxy.errors, proxy.errors
    print("PASS: local authenticated CONNECT/DNS/1MiB half-close/refusal, "
          "UDP ASSOCIATE framing/empty/1472/malformed injection/control close/"
          "rejected/unsupported, and fixture cleanup (not guest integration)")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    if sys.platform != "darwin":
        raise SystemExit("This test requires macOS and Apple Containerization")
    repo = Path(__file__).resolve().parent.parent
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else repo / "agentc").resolve()
    (repo / ".build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="socks-smoke-", dir=repo / ".build") as tmp:
        for mode, udp_reply in (("accepted", 0), ("unsupported", 7), ("rejected", 2)):
            run_case(binary, Path(tmp) / mode, mode, udp_reply)


if __name__ == "__main__":
    main()
