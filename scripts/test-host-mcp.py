#!/usr/bin/env python3
"""Real container -> host stdio MCP test; uses disposable profiles and no credentials.

Run ./build.sh --debug first. Uses the same AGENTC_TEST_RUNTIME/IMAGE overrides
as test-acp.py. The ACP test driver image needs Swift. AGENTC_TEST_BOOTSTRAP selects a freshly built
static bootstrap (default: ~/.agentc/bin/bootstrap, as installed by CI).
"""

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading


HOST_MCP = r"""
import json, os, sys
print("host-mcp-stderr-marker", file=sys.stderr, flush=True)
for line in sys.stdin:
    request = json.loads(line)
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {
        "cwd": os.getcwd(), "value": os.environ["HOST_MCP_TEST"],
        "argument": sys.argv[1], "pid": os.getpid(), "echoedMethod": request["method"]
    }}), flush=True)
"""


def run_case(repo, root, mode):
    configs = root / "configurations"
    (configs / ".git").mkdir(parents=True)
    (configs / ".agentc-last-pull").touch()
    (configs / "test").mkdir()
    (configs / "test/settings.json").write_text('{"v":0}')
    (configs / "test/agent.swift").write_text(
        (repo / "scripts/fixtures/acp-host-mcp.swift").read_text()
    )
    project = root / "project"
    (project / ".agentc").mkdir(parents=True)
    (project / ".agentc/settings.json").write_text(json.dumps({
        "agent": {"acp": {"bridgeHostStdioMcp": mode != "cli"}}
    }))
    # This script is outside all guest mounts. Successful execution proves that
    # the client-provided command runs on the host, not merely in the container.
    host_script = root / "host-only-mcp.py"
    host_script.write_text(HOST_MCP)
    args = [
        os.environ.get("AGENTC_TEST_BINARY", str(repo / "agentc")), "acp", "--verbose",
        "-r", os.environ.get("AGENTC_TEST_RUNTIME", "apple-container" if sys.platform == "darwin" else "docker"),
        "-i", os.environ.get("AGENTC_TEST_IMAGE", "swift:6.4"),
        "-c", "test", "--configurations-dir", str(configs),
        "--profile-dir", str(root / "profile"),
        "--respect-image-entrypoint", "--no-toolkit",
        "--bootstrap", str(Path(os.environ.get("AGENTC_TEST_BOOTSTRAP", "~/.agentc/bin/bootstrap")).expanduser().resolve()),
        "--log-file", str(root / "agent.log"),
    ]
    if proxy := os.environ.get("AGENTC_TEST_SOCKS_PROXY"):
        args += ["--socks5-proxy", proxy]
    if mode == "cli":
        args.append("--bridge-host-stdio-mcp")
    elif mode == "disabled":
        args.append("--no-bridge-host-stdio-mcp")
    args += ["--", "/usr/bin/swift", "/agent-isolation/agents/test/agent.swift"]
    process = subprocess.Popen(
        args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1,
    )
    responses = queue.Queue()
    stderr = []

    def read_stdout():
        try:
            for line in process.stdout:
                responses.put(json.loads(line))
        finally:
            responses.put(None)

    def read_stderr():
        stderr.extend(process.stderr)

    threading.Thread(target=read_stdout, daemon=True).start()
    threading.Thread(target=read_stderr, daemon=True).start()

    def request(number, method, params):
        process.stdin.write(json.dumps({
            "jsonrpc": "2.0", "id": number, "method": method, "params": params
        }) + "\n")
        process.stdin.flush()
        response = responses.get(timeout=150)
        assert response and response.get("id") == number and "result" in response, response
        return response["result"]

    host_pid = None
    try:
        request(1, "initialize", {"protocolVersion": 1})
        result = request(2, "session/new", {
            "cwd": str(project),
            "mcpServers": [{
                "name": "host-only-test", "command": sys.executable,
                "args": ["-u", str(host_script), "literal $(not-a-shell)"],
                "env": [{"name": "HOST_MCP_TEST", "value": "supplied-by-client"}],
            }],
        })
        assert result["bridged"] == (mode != "disabled"), result
        if mode != "disabled":
            host = result["host"]
            assert Path(host["cwd"]).resolve() == project.resolve(), host
            assert host["value"] == "supplied-by-client", host
            assert host["argument"] == "literal $(not-a-shell)", host
            assert host["echoedMethod"] == "_unknown/initialize", host
            host_pid = host["pid"]
        if mode == "settings":
            process.terminate()  # Verify host process cleanup on SIGTERM too.
        else:
            process.stdin.close()
        assert process.wait(timeout=30) == 0
        if host_pid is not None:
            try:
                os.kill(host_pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError(f"Host MCP process {host_pid} survived ACP shutdown")
        log = (root / "agent.log").read_text()
        assert ("host-mcp-stderr-marker" in log) == (mode != "disabled")
        assert not stderr, stderr
        print(f"PASS: host MCP bridge ({mode}): host execution, environment, argv, opaque traffic, cleanup")
    except BaseException:
        if (root / "agent.log").exists():
            print((root / "agent.log").read_text(), file=sys.stderr)
        raise
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def main():
    repo = Path(__file__).resolve().parent.parent
    for mode in ["cli", "settings", "disabled"]:
        with tempfile.TemporaryDirectory(prefix="host-mcp-test-", dir=repo / ".build") as temp:
            run_case(repo, Path(temp), mode)


if __name__ == "__main__":
    main()
