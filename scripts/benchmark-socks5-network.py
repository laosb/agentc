#!/usr/bin/env python3
"""Local-only Apple VM TCP benchmark. See docs/network-benchmark.md."""

import argparse
import contextlib
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import secrets
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time

CHUNK = bytes(range(256)) * 256
SYNTHETIC = ("203.0.113.7", 9000)

# Keep the guest standalone: the image needs only its standard-library Python.
GUEST = r'''
import concurrent.futures, hashlib, json, math, os, socket, statistics, struct, sys, time
from pathlib import Path

CHUNK = bytes(range(256)) * 256
root = Path(".")
config = json.loads((root / "guest-config.json").read_text())
size = config["bytes"]
token = bytes.fromhex(config["token"])
host = config["host"]
if host is None:
    for line in Path("/proc/net/route").read_text().splitlines()[1:]:
        fields = line.split()
        if (len(fields) >= 4 and fields[1] == "00000000"
                and int(fields[2], 16) != 0 and int(fields[3], 16) & 2):
            host = socket.inet_ntoa(struct.pack("<I", int(fields[2], 16)))
            break
    if host is None:
        raise RuntimeError("No guest IPv4 default gateway; pass --host-address with a VM-reachable host IPv4")
address = (host, config["port"])
deadline = time.monotonic() + config["timeout"]

def wait(name):
    while not (root / name).exists():
        if time.monotonic() >= deadline:
            raise TimeoutError(name)
        time.sleep(0.02)

def exact(conn, count):
    data = bytearray()
    while len(data) < count:
        part = conn.recv(count - len(data))
        if not part:
            raise EOFError((len(data), count))
        data.extend(part)
    return bytes(data)

# Expected checksum computed once, outside all throughput timing.
digest = hashlib.sha256()
for offset in range(0, size, len(CHUNK)):
    digest.update(CHUNK[:min(len(CHUNK), size - offset)])
expected = digest.digest()

def connect(mode, count):
    conn = socket.create_connection(address, timeout=config["timeout"])
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    if config.get("self_test_proxy"):
        conn.sendall(b"\x05\x01\x00")
        assert exact(conn, 2) == b"\x05\x00"
        conn.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("203.0.113.7") + struct.pack("!H", 9000))
        assert exact(conn, 10) == b"\x05\x00\x00\x01" + b"\0" * 6
    conn.sendall(token + struct.pack("!cQ", mode, count))
    assert exact(conn, 1) == b"K"
    return conn

def transfer(mode, barrier=None):
    with connect(mode, size) as conn:
        if barrier:
            barrier.wait(timeout=config["timeout"])
        start = time.perf_counter()
        conn.sendall(b"G")
        if mode == b"U":
            for offset in range(0, size, len(CHUNK)):
                conn.sendall(CHUNK[:min(len(CHUNK), size - offset)])
            actual = exact(conn, 32)
        else:
            digest = hashlib.sha256()
            remaining = size
            while remaining:
                part = conn.recv(min(len(CHUNK), remaining))
                if not part:
                    raise EOFError(remaining)
                remaining -= len(part)
                digest.update(part)
            actual = digest.digest()
        elapsed = time.perf_counter() - start
        assert actual == expected, "payload checksum mismatch"
        return start, elapsed

def bulk(mode, streams):
    import threading
    barrier = threading.Barrier(streams) if streams > 1 else None
    with concurrent.futures.ThreadPoolExecutor(max_workers=streams) as pool:
        results = list(pool.map(lambda _: transfer(mode, barrier), range(streams)))
    elapsed = max(start + duration for start, duration in results) - min(start for start, _ in results)
    return {"streams": streams, "bytes_per_stream": size,
            "total_bytes": size * streams, "seconds": elapsed,
            "mib_per_second": size * streams / elapsed / 1048576,
            "checksum_verified": True}

def echo():
    samples = []
    payload = CHUNK[:64]
    with connect(b"E", config["rtt_samples"] + 10) as conn:
        conn.sendall(b"G")
        for index in range(config["rtt_samples"] + 10):
            start = time.perf_counter()
            conn.sendall(payload)
            reply = exact(conn, len(payload))
            elapsed = time.perf_counter() - start
            assert reply == payload
            if index >= 10:
                samples.append(elapsed * 1000)
    return {"samples": len(samples), "payload_bytes": len(payload),
            "median_ms": statistics.median(samples),
            "p95_ms": sorted(samples)[math.ceil(len(samples) * .95) - 1]}

(root / "guest-ready").touch()
wait("host-go")
results = {"guest_python": sys.version, "destination": address, "upload": bulk(b"U", 1),
           "download": bulk(b"D", 1), "concurrent_upload": bulk(b"U", 8),
           "concurrent_download": bulk(b"D", 8), "echo_rtt": echo()}
(root / "guest-result.tmp").write_text(json.dumps(results))
os.replace(root / "guest-result.tmp", root / "guest-result.json")
wait("host-done")
'''


def exact(conn, count):
    result = bytearray()
    while len(result) < count:
        part = conn.recv(count - len(result))
        if not part:
            raise EOFError()
        result.extend(part)
    return bytes(result)


class Fixture(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 32

    def __init__(self, bind, proxy, token, size, rtt_samples, timeout):
        super().__init__((bind, 0), Handler)
        self.proxy = proxy
        self.token = token
        self.size = size
        self.rtt_samples = rtt_samples
        self.timeout = timeout
        self.errors = []
        self.connections = set()
        self.lock = threading.Lock()

    def close_connections(self):
        with self.lock:
            for conn in self.connections:
                with contextlib.suppress(OSError):
                    conn.shutdown(socket.SHUT_RDWR)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        conn = self.request
        with self.server.lock:
            self.server.connections.add(conn)
        try:
            conn.settimeout(self.server.timeout)
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            if self.server.proxy:
                version, count = exact(conn, 2)
                methods = exact(conn, count)
                if version != 5 or 0 not in methods:
                    return
                conn.sendall(b"\x05\x00")
                header = exact(conn, 4)
                if header != b"\x05\x01\x00\x01":
                    conn.sendall(b"\x05\x08\x00\x01" + b"\0" * 6)
                    return
                destination = (socket.inet_ntoa(exact(conn, 4)),
                               struct.unpack("!H", exact(conn, 2))[0])
                permitted = destination == SYNTHETIC
                conn.sendall(bytes([5, 0 if permitted else 2, 0, 1]) + b"\0" * 6)
                if not permitted:
                    return
            # Even the LAN-facing NAT listener only accepts a per-run random
            # token and bounded synthetic operations. It never opens a socket.
            if not secrets.compare_digest(exact(conn, 32), self.server.token):
                return
            mode, count = struct.unpack("!cQ", exact(conn, 9))
            if not ((mode in (b"U", b"D") and count == self.server.size)
                    or (mode == b"E" and count == self.server.rtt_samples + 10)):
                return
            conn.sendall(b"K")
            if exact(conn, 1) != b"G":
                return
            if mode == b"D":
                for offset in range(0, count, len(CHUNK)):
                    conn.sendall(CHUNK[:min(len(CHUNK), count - offset)])
            elif mode == b"U":
                digest = hashlib.sha256()
                remaining = count
                while remaining:
                    part = conn.recv(min(len(CHUNK), remaining))
                    if not part:
                        raise EOFError()
                    remaining -= len(part)
                    digest.update(part)
                conn.sendall(digest.digest())
            else:
                for _ in range(count):
                    conn.sendall(exact(conn, 64))
        except (EOFError, OSError) as error:
            with self.server.lock:
                self.server.errors.append(repr(error))
        finally:
            with self.server.lock:
                self.server.connections.discard(conn)


def cpu_seconds(value):
    days, separator, clock = value.partition("-")
    total = int(days) * 86400 if separator else 0
    for index, part in enumerate(reversed((clock if separator else days).split(":"))):
        total += float(part) * 60 ** index
    return total


def process_sample(pid):
    output = subprocess.check_output(
        ["ps", "-p", str(pid), "-o", "time=,rss="], text=True, timeout=5).strip()
    cpu, rss = output.split()
    return {"cpu_seconds": cpu_seconds(cpu), "rss_bytes": int(rss) * 1024}


def helper_pid(parent):
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,command="], text=True, timeout=5)
    matches = []
    for line in output.splitlines():
        fields = line.strip().split(maxsplit=2)
        if (len(fields) == 3 and int(fields[1]) == parent
                and "--agentc-socks-network-v1" in fields[2]):
            matches.append(int(fields[0]))
    if len(matches) != 1:
        raise RuntimeError(f"Expected one private SOCKS helper under {parent}, got {matches}")
    return matches[0]


def stop(process, helper=None):
    # Kill our dedicated process group even if its leader already exited.
    # Foundation Process may put the helper in a separate process group.
    if helper is None and process.poll() is None:
        with contextlib.suppress(RuntimeError, subprocess.SubprocessError):
            helper = helper_pid(process.pid)
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGTERM)
    if helper:
        with contextlib.suppress(ProcessLookupError):
            os.kill(helper, signal.SIGTERM)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGKILL)
    if helper:
        with contextlib.suppress(ProcessLookupError):
            os.kill(helper, signal.SIGKILL)
    process.wait(timeout=5)


def run_mode(args, root, mode, binary, address):
    folder = root / mode
    folder.mkdir()
    configs = folder / "configs"
    (configs / ".git").mkdir(parents=True)
    (configs / ".agentc-last-pull").touch()
    (configs / "noop").mkdir()
    (configs / "noop/settings.json").write_text("{}")
    (folder / "settings.json").write_text("{}")
    (folder / "guest.py").write_text(GUEST)
    token = secrets.token_bytes(32)
    proxy = mode == "socks"
    bind = "127.0.0.1" if proxy or args.self_test else (address or "0.0.0.0")
    with Fixture(bind, proxy, token, args.bytes, args.rtt_samples, args.timeout) as fixture:
        server_thread = threading.Thread(target=fixture.serve_forever, daemon=True)
        server_thread.start()
        config = {"host": SYNTHETIC[0] if proxy else address,
                  "port": SYNTHETIC[1] if proxy else fixture.server_address[1],
                  "bytes": args.bytes, "token": token.hex(), "timeout": args.timeout,
                  "rtt_samples": args.rtt_samples}
        if args.self_test:
            config.update(host=address, port=fixture.server_address[1], self_test_proxy=proxy)
        (folder / "guest-config.json").write_text(json.dumps(config))
        env = {k: v for k, v in os.environ.items()
               if not k.startswith("AGENTC_SOCKS5_")
               and k.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
        command = [
            str(binary), "run", "--runtime", "apple-container",
            "--image", args.image, "--respect-image-entrypoint",
            "--no-toolkit", "--no-update-image",
            "--configurations-dir", str(configs), "-c", "noop",
            "--profile-dir", str(folder / "profile"), "--workspace", str(folder),
            "--agentc-folder", str(folder), "--suppress-migration-from-claudec",
        ]
        if proxy:
            command += ["--socks5-proxy", f"socks5://127.0.0.1:{fixture.server_address[1]}"]
        command += ["--", "/usr/local/bin/python3", "guest.py"]
        if args.self_test:
            command = [sys.executable, "guest.py"]
        process = None
        pid = None
        with (folder / "agentc.log").open("w+") as log:
            try:
                process = subprocess.Popen(command, cwd=folder, env=env, stdout=log,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                deadline = time.monotonic() + args.timeout

                def wait_for(name):
                    while not (folder / name).exists():
                        if process.poll() is not None:
                            raise RuntimeError(f"{mode}: process exited {process.returncode}")
                        if time.monotonic() >= deadline:
                            raise TimeoutError(f"{mode}: waiting for {name}")
                        time.sleep(0.05)

                wait_for("guest-ready")
                pid = helper_pid(process.pid) if proxy and not args.self_test else None
                idle = None
                if pid:
                    before = process_sample(pid)
                    start = time.monotonic()
                    time.sleep(args.idle_seconds)
                    after = process_sample(pid)
                    elapsed = time.monotonic() - start
                    idle = {"seconds": elapsed,
                            "cpu_seconds": after["cpu_seconds"] - before["cpu_seconds"],
                            "rss_bytes": after["rss_bytes"]}
                    idle["average_cpu_percent_one_core"] = idle["cpu_seconds"] / elapsed * 100
                before = process_sample(pid) if pid else None
                peak = before["rss_bytes"] if before else None
                active_start = time.monotonic()
                (folder / "host-go").touch()
                while not (folder / "guest-result.json").exists():
                    if process.poll() is not None:
                        raise RuntimeError(f"{mode}: process exited {process.returncode}")
                    if time.monotonic() >= deadline:
                        raise TimeoutError(f"{mode}: benchmark timeout")
                    if pid:
                        peak = max(peak, process_sample(pid)["rss_bytes"])
                    time.sleep(0.2)
                after = process_sample(pid) if pid else None
                elapsed = time.monotonic() - active_start
                result = json.loads((folder / "guest-result.json").read_text())
                result["helper"] = None
                if pid:
                    cpu = after["cpu_seconds"] - before["cpu_seconds"]
                    result["helper"] = {
                        "pid": pid, "idle": idle, "active_seconds": elapsed,
                        "active_cpu_seconds": cpu,
                        "active_average_cpu_percent_one_core": cpu / elapsed * 100,
                        "peak_sampled_rss_bytes": max(peak, after["rss_bytes"]),
                        "rss_sample_interval_seconds": 0.2,
                    }
                (folder / "host-done").touch()
                process.wait(timeout=30)
                if process.returncode:
                    raise RuntimeError(f"{mode}: process exited {process.returncode}")
                if fixture.errors:
                    raise RuntimeError(f"{mode}: fixture errors: {fixture.errors}")
                return result
            except BaseException:
                log.flush()
                log.seek(0)
                print(log.read(), file=sys.stderr)
                raise
            finally:
                try:
                    if process:
                        stop(process, pid)
                finally:
                    fixture.close_connections()
                    fixture.shutdown()
                    server_thread.join(timeout=5)


def summary(report):
    title = ("Native fixture self-test — NOT AppleVM performance" if report["self_test"]
             else "Local AppleVM TCP benchmark")
    lines = [title + " (MiB = 1,048,576 bytes)"]
    for mode, result in report["runs"].items():
        lines.append(f"{mode}:")
        for name in ("upload", "download", "concurrent_upload", "concurrent_download"):
            item = result[name]
            lines.append(f"  {name:22} {item['mib_per_second']:9.2f} MiB/s"
                         f"  {item['streams']} stream(s), {item['seconds']:.3f}s")
        item = result["echo_rtt"]
        lines.append(f"  echo RTT median {item['median_ms']:.3f} ms, p95 {item['p95_ms']:.3f} ms")
        helper = result["helper"]
        if helper:
            lines.append(f"  helper active CPU {helper['active_cpu_seconds']:.3f}s,"
                         f" average {helper['active_average_cpu_percent_one_core']:.1f}% of one core,"
                         f" peak sampled RSS {helper['peak_sampled_rss_bytes'] / 1048576:.2f} MiB")
            idle = helper["idle"]
            lines.append(f"  helper idle CPU {idle['cpu_seconds']:.3f}s over {idle['seconds']:.2f}s"
                         f" ({idle['average_cpu_percent_one_core']:.2f}% of one core)")
    if "comparison" in report:
        lines.append("SOCKS / NAT throughput ratios (higher is better):")
        lines += [f"  {name}: {value:.3f}x"
                  for name, value in report["comparison"]["throughput_ratios"].items()]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parent.parent / "agentc")
    parser.add_argument("--bytes", type=int, default=32 * 1024 * 1024,
                        help="bytes per stream (default 32 MiB; concurrent cases each use eight streams)")
    parser.add_argument("--image", default="python:3.13-slim")
    parser.add_argument("--mode", choices=("both", "nat", "socks"), default="both")
    parser.add_argument("--host-address", help="guest-reachable host IPv4 for NAT (default guest's NAT gateway)")
    parser.add_argument("--idle-seconds", type=float, default=5)
    parser.add_argument("--rtt-samples", type=int, default=200)
    parser.add_argument("--timeout", type=float, default=600, help="deadline per VM run, including boot")
    parser.add_argument("--output", type=Path, help="write JSON here as well as stdout; summary goes to stderr")
    parser.add_argument("--self-test", action="store_true", help="test native loopback fixtures, NOT AppleVM performance")
    args = parser.parse_args()
    if (args.bytes < 1 or args.rtt_samples < 1 or args.idle_seconds < 0
            or not math.isfinite(args.idle_seconds) or not math.isfinite(args.timeout)
            or args.timeout <= args.idle_seconds):
        parser.error("sizes/counts must be positive; timeout must exceed nonnegative idle interval")
    if not args.self_test and sys.platform != "darwin":
        parser.error("AppleVM benchmarking requires macOS")
    binary = args.binary.resolve()
    if not args.self_test and not binary.is_file():
        parser.error(f"binary not found: {binary}; provide --binary /path/to/signed/agentc")
    modes = ["nat", "socks"] if args.mode == "both" else [args.mode]
    address = "127.0.0.1" if args.self_test else args.host_address
    if address:
        socket.inet_aton(address)
    repo = Path(__file__).resolve().parent.parent
    (repo / ".build").mkdir(exist_ok=True)
    version = None
    if not args.self_test:
        version = subprocess.check_output([str(binary), "version"], text=True, timeout=10).strip()
    report = {"schema_version": 1, "self_test": args.self_test,
              "platform": platform.platform(), "machine": platform.machine(),
              "host_python": sys.version, "agentc_version": version,
              "binary": str(binary), "image": args.image, "bytes_per_stream": args.bytes,
              "host_address": address, "unix_time": time.time(), "runs": {}}
    with tempfile.TemporaryDirectory(prefix="socks-benchmark-", dir=repo / ".build") as tmp:
        for mode in modes:
            print(f"Running {mode}{' (native self-test)' if args.self_test else ' AppleVM'}…", file=sys.stderr)
            report["runs"][mode] = run_mode(args, Path(tmp), mode, binary, address)
    if set(report["runs"]) == {"nat", "socks"}:
        nat, socks = report["runs"]["nat"], report["runs"]["socks"]
        report["comparison"] = {
            "throughput_ratios": {key: socks[key]["mib_per_second"] / nat[key]["mib_per_second"]
                                  for key in ("upload", "download", "concurrent_upload", "concurrent_download")},
            "echo_median_ratio": socks["echo_rtt"]["median_ms"] / nat["echo_rtt"]["median_ms"],
            "echo_p95_ratio": socks["echo_rtt"]["p95_ms"] / nat["echo_rtt"]["p95_ms"],
        }
    text = json.dumps(report, indent=2)
    if args.output:
        args.output.write_text(text + "\n")
    print(text)
    print(summary(report), file=sys.stderr)


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    main()
