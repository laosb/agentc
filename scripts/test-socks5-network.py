#!/usr/bin/env python3
"""Real Apple VM smoke test using a local SOCKS5 fixture, never a public proxy.

Usage: python3 scripts/test-socks5-network.py [path/to/signed/agentc]
AGENTC_TEST_SOCKS_IMAGE defaults to python:3.13-slim. The host may need to pull it.
All guest destinations are synthetic: the fixture serves DNS and an echo stream
without opening any upstream sockets. Artifacts stay under the checkout's .build.
"""

import os
from pathlib import Path
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time


GUEST = r'''
import os, socket, time
from pathlib import Path

assert not any(k.lower() in ("http_proxy", "https_proxy", "all_proxy")
               or k.startswith("AGENTC_SOCKS5_") for k in os.environ)
assert socket.gethostbyname("agentc-proxy-test.invalid") == "203.0.113.7"
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
    udp.settimeout(0.5)
    udp.sendto(b"unsupported UDP", ("203.0.113.7", 9000))
    try:
        udp.recv(128)
        raise AssertionError("non-DNS UDP was not blocked")
    except TimeoutError:
        pass
with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as ipv6:
    ipv6.settimeout(0.5)
    try:
        ipv6.connect(("2001:db8::1", 9000))
        raise AssertionError("IPv6 was not blocked")
    except OSError:
        pass
Path("ready-to-kill-helper").touch()
deadline = time.monotonic() + 20
while not Path("helper-killed").exists():
    assert time.monotonic() < deadline, "host did not kill networking helper"
    time.sleep(0.05)
try:
    with socket.create_connection(("203.0.113.7", 9000), timeout=3):
        raise AssertionError("helper failure did not cut network access")
except OSError:
    pass
print("PASS: transparent TCP, DNS, 1MiB half-close, credentials hidden, "
      "refusal/UDP/IPv6/helper failure fail closed", flush=True)
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
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.requests = []
        self.lock = threading.Lock()


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.serve()
        except (EOFError, OSError):
            pass

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
        assert (version, command, reserved, kind) == (5, 1, 0, 1)
        destination = socket.inet_ntoa(read_exact(conn, 4))
        port = struct.unpack("!H", read_exact(conn, 2))[0]
        with self.server.lock:
            self.server.requests.append((destination, port))
        permitted = (destination, port) in [("203.0.113.7", 9000), ("1.1.1.1", 53)]
        reply = bytes([5, 0 if permitted else 2, 0, 1]) + b"\0" * 6
        # Exercise partial protocol reads, rather than one convenient recv().
        for byte in reply:
            conn.sendall(bytes([byte]))
        if not permitted:
            return
        if port == 53:
            length = struct.unpack("!H", read_exact(conn, 2))[0]
            query = read_exact(conn, length)
            assert 12 <= len(query) <= 4096
            answer = (
                query[:2] + b"\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00"
                + query[12:]
                + b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04"
                + socket.inet_aton("203.0.113.7")
            )
            conn.sendall(struct.pack("!H", len(answer)) + answer)
        else:
            payload = bytearray()
            while chunk := conn.recv(16384):
                payload += chunk
                assert len(payload) <= 1024 * 1024
            conn.sendall(payload)


def children(pid):
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True)
    result = []
    for line in output.splitlines():
        fields = line.strip().split(maxsplit=2)
        if len(fields) == 3 and int(fields[1]) == pid and "--agentc-socks-network-v1" in fields[2]:
            result.append(int(fields[0]))
    return result


def main():
    if sys.platform != "darwin":
        raise SystemExit("This test requires macOS and Apple Containerization")
    repo = Path(__file__).resolve().parent.parent
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else repo / "agentc").resolve()
    (repo / ".build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="socks-smoke-", dir=repo / ".build") as tmp:
        root = Path(tmp)
        configs = root / "configs"
        (configs / ".git").mkdir(parents=True)
        (configs / ".agentc-last-pull").touch()
        (configs / "noop").mkdir()
        (configs / "noop/settings.json").write_text("{}")
        (root / "settings.json").write_text("{}")
        (root / "guest.py").write_text(GUEST)
        with Proxy() as proxy:
            thread = threading.Thread(target=proxy.serve_forever, daemon=True)
            thread.start()
            env = os.environ | {
                "AGENTC_SOCKS5_USERNAME": "fixture-user",
                "AGENTC_SOCKS5_PASSWORD": "fixture-password",
            }
            args = [
                str(binary), "run", "--runtime", "apple-container",
                "--socks5-proxy", f"socks5://127.0.0.1:{proxy.server_address[1]}",
                "--image", os.environ.get("AGENTC_TEST_SOCKS_IMAGE", "python:3.13-slim"),
                "--respect-image-entrypoint", "--no-toolkit", "--no-update-image",
                "--configurations-dir", str(configs), "-c", "noop",
                "--profile-dir", str(root / "profile"), "--workspace", str(root),
                "--agentc-folder", str(root), "--suppress-migration-from-claudec",
                "--", "/usr/local/bin/python3", "guest.py",
            ]
            process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            try:
                deadline = time.monotonic() + 180
                while not (root / "ready-to-kill-helper").exists():
                    if process.poll() is not None:
                        raise AssertionError(process.communicate())
                    if time.monotonic() > deadline:
                        raise AssertionError("Guest smoke test timed out")
                    time.sleep(0.05)
                helpers = children(process.pid)
                assert len(helpers) == 1, helpers
                os.kill(helpers[0], signal.SIGKILL)
                (root / "helper-killed").touch()
                stdout, stderr = process.communicate(timeout=30)
                assert process.returncode == 0, (process.returncode, stdout, stderr)
                assert b"PASS:" in stdout, stdout
                assert ("1.1.1.1", 53) in proxy.requests, proxy.requests
                assert ("203.0.113.7", 9000) in proxy.requests, proxy.requests
                assert ("203.0.113.8", 9000) in proxy.requests, proxy.requests
                print(stdout.decode(), end="")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.communicate(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate(timeout=5)
                proxy.shutdown()
                thread.join(timeout=5)


if __name__ == "__main__":
    main()
