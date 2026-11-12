#!/usr/bin/env python3
"""Regression tests for CI selection; no third-party Python dependencies."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from changes import JOBS, changed_paths, classify


class ClassificationTests(unittest.TestCase):
    def assert_jobs(self, paths, *expected):
        self.assertEqual({job for job, run in classify(paths).items() if run}, set(expected))

    def test_unrelated_changes(self):
        self.assert_jobs([
            "README.md", "docs/design.md", "install.sh", "LICENSE",
            ".github/FUNDING.yml", ".github/workflows/build.yml",
            ".github/workflows/build-image.yml", ".github/workflows/toolkit.yml",
            "scripts/toolkit/manifest.sh", "scripts/benchmark-startup.sh",
        ])

    def test_shared_build_inputs(self):
        for path in [
            "Package.swift", "Package.resolved", ".swift-version",
            ".github/actions/setup-swift/action.yml", ".github/workflows/test.yml",
            "scripts/ci/changes.py", "scripts/ci/test-integration.sh",
        ]:
            with self.subTest(path=path):
                self.assert_jobs([path], *JOBS)

    def test_source_dependencies(self):
        self.assert_jobs(["Sources/agentc/Run.swift"], "unit", "integration")
        self.assert_jobs(["Sources/HostBridge/Transport.swift"], "unit", "integration")
        self.assert_jobs(["Sources/agentc-bootstrap/main.swift"], "unit", "integration")
        self.assert_jobs(
            ["Sources/AgentIsolationDockerRuntime/DockerRuntime.swift"],
            "unit", "integration", "runtime",
        )
        self.assert_jobs(
            ["Sources/AgentIsolation/SOCKS5Proxy.swift"], *JOBS
        )
        self.assert_jobs(
            ["Sources/CSOCKSNetwork/network.c"], "unit", "integration", "packet"
        )

    def test_test_only_changes(self):
        self.assert_jobs(["Tests/AgentcTests/ArgumentsTests.swift"], "unit")
        self.assert_jobs(
            ["Tests/AgentcIntegrationTests/AgentcHelpers.swift"], "unit", "integration"
        )
        self.assert_jobs(
            ["Tests/AgentIsolationDockerRuntimeTests/DockerRuntimeTests.swift"],
            "unit", "runtime",
        )
        self.assert_jobs(["scripts/test-host-mcp.py"], "integration")
        self.assert_jobs(["scripts/fixtures/acp-host-mcp.swift"], "integration")
        self.assert_jobs(["scripts/test-packet-engine.sh"], "packet")
        self.assert_jobs(["Tests/PacketEngineHarness/ReadinessHarness.swift"], "packet")
        self.assert_jobs(["Dockerfile"], "integration")
        self.assert_jobs(["build.sh"], "integration")

    def test_empty_and_large_diffs(self):
        self.assert_jobs([])
        self.assert_jobs(
            [f"docs/{i}.md" for i in range(400)] + ["Sources/agentc/main.swift"],
            "unit", "integration",
        )

    def test_manual_and_unknown_base_run_everything(self):
        self.assertIsNone(changed_paths("workflow_dispatch", "base", "head"))
        self.assertIsNone(changed_paths("push", "0" * 40, "head"))
        with patch("changes.subprocess.check_output", side_effect=subprocess.CalledProcessError(1, "git")):
            self.assertIsNone(changed_paths("push", "missing", "head"))


class GitDiffTests(unittest.TestCase):
    def test_push_range_pr_merge_base_and_renames(self):
        with tempfile.TemporaryDirectory() as directory:
            previous = os.getcwd()
            os.chdir(directory)
            try:
                def git(*args):
                    return subprocess.check_output(["git", *args], text=True).strip()

                git("init", "-q", "-b", "main")
                git("config", "user.name", "CI test")
                git("config", "user.email", "ci@example.invalid")
                git("config", "commit.gpgsign", "false")
                Path("original.swift").write_text("original")
                git("add", ".")
                git("commit", "-qm", "base")
                base = git("rev-parse", "HEAD")
                git("switch", "-qc", "feature")
                git("mv", "original.swift", "renamed file.swift")
                git("commit", "-qm", "rename")
                Path("second.swift").write_text("second")
                git("add", ".")
                git("commit", "-qm", "second")
                head = git("rev-parse", "HEAD")
                expected = {"original.swift", "renamed file.swift", "second.swift"}
                self.assertEqual(set(changed_paths("push", base, head)), expected)
                git("switch", "-q", "main")
                Path("base-only.swift").write_text("not part of the PR")
                git("add", ".")
                git("commit", "-qm", "advance main")
                self.assertEqual(set(changed_paths("pull_request", "HEAD", head)), expected)
            finally:
                os.chdir(previous)


if __name__ == "__main__":
    unittest.main()
