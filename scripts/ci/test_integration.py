"""Check integration orchestration without requiring Swift or a Docker daemon."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("test-integration.sh").resolve()


class IntegrationDriverTests(unittest.TestCase):
    def run_driver(self, fail_at=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "commands"
            for command in ("python3", "swift"):
                mock = root / command
                mock.write_text(
                    '#!/bin/sh\n'
                    'printf "%s|%s|%s|%s|%s\\n" "$*" "${AGENTC_TEST_ACP_SIGNAL-}" '
                    '"$AGENTC_TEST_RUNTIME" "$AGENTC_TEST_IMAGE" "${VERBOSE-}" >> "$LOG"\n'
                    '[ "$*" != "$FAIL_AT" ]\n'
                )
                mock.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{root}:{os.environ['PATH']}",
                "LOG": str(log),
                "FAIL_AT": fail_at,
            }
            env.pop("AGENTC_TEST_ACP_SIGNAL", None)
            env.pop("VERBOSE", None)
            result = subprocess.run(["bash", str(SCRIPT)], env=env, cwd=root)
            return result.returncode, log.read_text().splitlines()

    def test_both_acp_modes_and_native_test_bundle_reuse(self):
        code, commands = self.run_driver()
        self.assertEqual(code, 0)
        image = "docker|docker.io/library/swift:6.4.2"
        self.assertEqual(commands, [
            f"scripts/test-acp.py||{image}|",
            f"scripts/test-acp.py|1|{image}|",
            f"scripts/test-host-mcp.py||{image}|",
            "test --skip-build --disable-default-traits --traits ContainerRuntimeDocker "
            f"--filter AgentcIntegrationTests||{image}|1",
        ])

    def test_smoke_failure_is_not_hidden_by_a_later_success(self):
        code, commands = self.run_driver(fail_at="scripts/test-host-mcp.py")
        self.assertNotEqual(code, 0)
        self.assertEqual(len(commands), 3)


if __name__ == "__main__":
    unittest.main()
