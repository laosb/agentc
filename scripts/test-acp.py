#!/usr/bin/env python3
"""Real-container ACP smoke test. Run ./build.sh --debug first.

Uses only disposable profiles and fixtures under .build, never the user's agent
credentials. Requires a local swift:6.4 image (or AGENTC_TEST_IMAGE) with /bin/sh.
AGENTC_TEST_RUNTIME defaults to apple-container on macOS and docker elsewhere.
Set AGENTC_TEST_ACP_SIGNAL=1 to test SIGTERM shutdown instead of stdin EOF.
"""

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading


AGENT = r"""
while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed 's/.*"id":"\([^"]*\)".*/\1/')
    case "$line" in
      *'"method":"initialize"'*)
        result='{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}'
        ;;
      *'"method":"session\/new"'*|*'"method":"session/new"'*)
        visible=''
        for path in "$ACP_ONE" "$ACP_TWO" "$ACP_SHARED" "$ACP_CLI" "$ACP_HIDDEN" "$PWD/excluded/secret"; do
            exists=false
            [ ! -e "$path" ] || exists=true
            visible="$visible\"$path\":$exists,"
        done
        result="{\"sessionId\":\"same-native-id\",\"cwd\":\"$PWD\",\"visible\":{${visible%,}}}"
        ;;
      *'"method":"_opaque"'*)
        printf 'malformed backend message\n'
        result=$(printf '%s' "$line" | sed 's/.*"params":\(.*\)}$/\1/')
        ;;
      *) result='{}' ;;
    esac
    printf '{"jsonrpc":"2.0","id":"%s","result":%s}\n' "$id" "$result"
done
"""


def main():
    repo = Path(__file__).resolve().parent.parent
    runtime = os.environ.get(
        "AGENTC_TEST_RUNTIME", "apple-container" if sys.platform == "darwin" else "docker"
    )
    with tempfile.TemporaryDirectory(prefix="acp-smoke-", dir=repo / ".build") as temporary:
        root = Path(temporary)
        assert not any(character in str(root) for character in '"\\\n')
        configs = root / "configurations"
        (configs / ".git").mkdir(parents=True)
        (configs / ".agentc-last-pull").touch()
        (configs / "test").mkdir()
        (configs / "test/settings.json").write_text('{"v":0}')
        projects = [root / "one", root / "two"]
        shared = root / "shared"
        hidden = root / "not-mounted"
        cli_shared = root / "cli-shared"
        for path in projects + [shared, hidden, cli_shared]:
            path.mkdir()
        for project in projects:
            (project / ".agentc").mkdir()
            (project / "excluded").mkdir()
            (project / "excluded/secret").write_text("not visible")
            (project / ".agentc/settings.json").write_text(json.dumps({
                "agent": {"additionalMounts": ["../shared"], "excludes": ["excluded"]}
            }))
        args = [
            str(repo / "agentc"), "acp", "-r", runtime,
            "-i", os.environ.get("AGENTC_TEST_IMAGE", "swift:6.4"),
            "-c", "test", "--configurations-dir", str(configs),
            "--profile-dir", str(root / "profile"),
            "--respect-image-entrypoint", "--no-toolkit",
            "--additional-mount", str(cli_shared),
            "--log-file", str(root / "agent.log"),
            "--stdio-log-file", str(root / "stdio.log"),
            "--env", f"ACP_ONE={projects[0]}", "--env", f"ACP_TWO={projects[1]}",
            "--env", f"ACP_SHARED={shared}", "--env", f"ACP_CLI={cli_shared}",
            "--env", f"ACP_HIDDEN={hidden}",
            "--", "/bin/sh", "-c", AGENT,
        ]
        process = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1,
        )
        responses = queue.Queue()
        stderr = []

        def read_stdout():
            for line in process.stdout:
                responses.put(json.loads(line))
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
            assert response is not None, f"Unexpected EOF: {stderr}"
            assert response["id"] == number, response
            return response

        try:
            assert "result" in request(1, "initialize", {"protocolVersion": 1})
            session_ids = []
            for index, project in enumerate(projects):
                other = projects[1 - index]
                probes = [
                    str(project), str(shared), str(cli_shared), str(hidden),
                    str(other), str(project / "excluded/secret"),
                ]
                response = request(index + 2, "session/new", {
                    "cwd": str(project), "mcpServers": [], "probe": probes,
                })
                assert "result" in response, response
                result = response["result"]
                assert result["cwd"] == str(project), result
                assert result["visible"] == dict(zip(probes, [True, True, True, False, False, False])), result
                session_ids.append(result["sessionId"])
            assert session_ids[0] != session_ids[1]
            assert "error" in request(4, "session/add_directory", {
                "sessionId": session_ids[0], "path": str(hidden),
            })
            process.stdin.write("malformed client message\n")
            process.stdin.flush()
            opaque = {"sessionId": session_ids[1], "unknown": {"array": [True, None, "🌍"]}}
            result = request(5, "_opaque", opaque)["result"]
            # The echo has a top-level sessionId, so the proxy namespaces it again.
            assert result == opaque, result
            if os.environ.get("AGENTC_TEST_ACP_SIGNAL") == "1":
                process.terminate()
            else:
                process.stdin.close()
            assert process.wait(timeout=30) == 0
            log = (root / "agent.log").read_text()
            assert "malformed client ACP message" in log, log
            assert "malformed ACP message from backend" in log, log
            transcript = (root / "stdio.log").read_text()
            assert "stdin:" in transcript and "stdout:" in transcript
            assert not stderr, stderr
            print("PASS: real-container ACP negotiation, two isolated workspaces, settings/CLI mounts,")
            shutdown = "SIGTERM" if os.environ.get("AGENTC_TEST_ACP_SIGNAL") == "1" else "EOF"
            print(f"      exclusions, ID routing, extension passthrough, recovery, logs, and {shutdown} shutdown")
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


if __name__ == "__main__":
    main()
