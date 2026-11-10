#!/usr/bin/env python3
"""Opt-in real-container smoke test. All fixtures stay under the checkout's .build.

Usage: python3 scripts/test-host-bridge.py AGENTC LINUX_BOOTSTRAP [apple-container|docker]
The agentc binary must already be signed on macOS. Docker requires native Linux/runc.
"""
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time


def main():
    agentc, bootstrap = (str(Path(arg).resolve()) for arg in sys.argv[1:3])
    runtime = sys.argv[3] if len(sys.argv) > 3 else "apple-container"
    root = Path(__file__).resolve().parent.parent
    (root / ".build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bridge-smoke-", dir=root / ".build") as tmp:
        fixture = Path(tmp)
        configs = fixture / "configs"
        configs.mkdir()
        subprocess.run(["git", "init", "-q", str(configs)], check=True)
        (configs / ".agentc-last-pull").touch()
        (configs / "noop").mkdir()
        (configs / "noop" / "settings.json").write_text("{}")
        probe = (
            "printf 'host=%s allow=%s deny=%s\\n' \"$(uname -s)\" "
            "\"$BRIDGE_ALLOW\" \"${BRIDGE_DENY-unset}\"; "
            "cat; printf 'host stderr\\n' >&2; exit 37"
        )
        (fixture / "settings.json").write_text(json.dumps({
            "agent": {"hostBinaries": [{
                "containerPath": "/usr/local/bin/host-probe",
                "hostCommand": "/bin/sh",
                "arguments": ["-c", probe],
                "forwardArguments": False,
                "forwardEnvironment": ["BRIDGE_ALLOW"],
            }, {
                "containerPath": "/usr/local/bin/host-wait",
                "hostCommand": "/bin/sh",
                "arguments": ["-c", "echo $$ > host-child.pid; exec sleep 60"],
                "forwardArguments": False,
            }]}
        }))
        common = [
            agentc, "sh", "--runtime", runtime,
            "--image", "docker.io/library/alpine:3.22",
            "--workspace", str(fixture), "--profile-dir", str(fixture / "profile"),
            "--configurations-dir", str(configs), "-c", "noop",
            "--agentc-folder", str(fixture), "--bootstrap", bootstrap,
            "--bootstrap-host-bridge", "--no-toolkit", "--no-update-image",
            "--suppress-migration-from-claudec",
        ]
        if runtime == "docker":
            common += ["--docker-runtime", "runc"]
        if proxy := os.environ.get("AGENTC_TEST_SOCKS_PROXY"):
            common += ["--socks5-proxy", proxy]
        denied = subprocess.run(common + ["--", "true"], capture_output=True, timeout=30)
        assert denied.returncode != 0 and b"--allow-host-binaries" in denied.stderr, denied
        env = os.environ.copy()
        env.pop("BRIDGE_ALLOW", None)
        env.pop("BRIDGE_DENY", None)
        result = subprocess.run(common + [
            "--allow-host-binaries", "--",
            "export BRIDGE_ALLOW=guest-value BRIDGE_DENY=must-not-forward; "
            "printf 'binary stdin\\n' | /usr/local/bin/host-probe",
        ], capture_output=True, timeout=180, env=env)
        expected = (
            f"host={platform.system()} allow=guest-value deny=unset\nbinary stdin\n"
        ).encode()
        assert result.returncode == 37, (result.returncode, result.stdout, result.stderr)
        assert result.stdout == expected, result.stdout
        assert b"host stderr\n" in result.stderr, result.stderr
        print("PASS: authorization, guest wrapper, host execution, env allow list, stdio, exit 37")
        signaled = subprocess.run(common + [
            "--allow-host-binaries", "--",
            "/usr/local/bin/host-wait & child=$!; sleep 1; kill -TERM \"$child\"; wait \"$child\"",
        ], capture_output=True, timeout=30, env=env)
        assert signaled.returncode == 143, (signaled.returncode, signaled.stdout, signaled.stderr)
        print("PASS: guest SIGTERM reaches host process group and is mirrored in guest status")
        pid_file = fixture / "host-child.pid"
        pid_file.unlink()
        running = subprocess.Popen(
            common + ["--allow-host-binaries", "--", "/usr/local/bin/host-wait"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        try:
            deadline = time.monotonic() + 30
            while not pid_file.exists():
                assert running.poll() is None, running.communicate()
                assert time.monotonic() < deadline, "Host child did not start"
                time.sleep(0.05)
            child = int(pid_file.read_text())
            running.terminate()
            running.communicate(timeout=30)
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError(f"Host child {child} survived agentc shutdown")
            print("PASS: SIGTERM to agentc cancels the container and reaps the host child")
        finally:
            if running.poll() is None:
                running.terminate()
                running.communicate(timeout=30)
        settings = json.loads((fixture / "settings.json").read_text())
        for path, diagnostic in [
            ("/bin/sh", b"existing files are never replaced"),
            (str(fixture / "must-not-create"), b"container image filesystem"),
        ]:
            settings["agent"]["hostBinaries"][0]["containerPath"] = path
            (fixture / "settings.json").write_text(json.dumps(settings))
            rejected = subprocess.run(
                common + ["--allow-host-binaries", "--mount-path-scheme", "host", "--", "true"],
                capture_output=True, timeout=30, env=env)
            assert rejected.returncode != 0 and diagnostic in rejected.stderr, (
                rejected.returncode, rejected.stdout, rejected.stderr)
        assert not (fixture / "must-not-create").exists()
        print("PASS: existing binaries and host-backed mount destinations are not overwritten")


if __name__ == "__main__":
    main()
