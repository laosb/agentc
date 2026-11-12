#!/usr/bin/env python3
"""Select CI work from the complete Git diff, not GitHub's truncated path list."""

import argparse
import os
import subprocess


JOBS = ("unit", "integration", "runtime", "packet")
COMMON = {
    "Package.swift",
    "Package.resolved",
    ".swift-version",
    ".github/workflows/test.yml",
}
SMOKE_TESTS = {
    "scripts/test-acp.py",
    "scripts/test-host-mcp.py",
    "scripts/test-mcp-relay-minimal.py",
}


def classify(paths):
    selected = dict.fromkeys(JOBS, False)
    for path in paths:
        if path in COMMON or path.startswith((".github/actions/", "scripts/ci/")):
            return dict.fromkeys(JOBS, True)
        # Documentation, release automation, toolkit publishing, and benchmarks
        # don't change the Swift package or the fixtures this workflow runs.
        if path.endswith(".md"):
            continue
        if path.startswith(("Sources/", "Tests/")) and not path.startswith("Tests/PacketEngineHarness/"):
            selected["unit"] = True
        if (
            path.startswith(("Sources/", "Tests/AgentcIntegrationTests/", "scripts/fixtures/"))
            or path in SMOKE_TESTS
            or path in {"Dockerfile", "build.sh"}
        ):
            selected["integration"] = True
        if path.startswith((
            "Sources/AgentIsolation/",
            "Sources/AgentIsolationDockerRuntime/",
            "Tests/AgentIsolationDockerRuntimeTests/",
        )):
            selected["runtime"] = True
        if (
            path.startswith((
                "Sources/CSOCKSNetwork/",
                "Sources/SOCKSNetwork/",
                "Sources/AgentIsolation/SOCKS5",
                "Tests/PacketEngineHarness/",
            ))
            or path == "scripts/test-packet-engine.sh"
        ):
            selected["packet"] = True
    return selected


def changed_paths(event, base, head):
    if event == "workflow_dispatch" or not base or set(base) == {"0"}:
        return None
    try:
        if event == "pull_request":
            base = subprocess.check_output(
                ["git", "merge-base", base, head], text=True
            ).strip()
        diff = subprocess.check_output(
            ["git", "diff", "--name-only", "--no-renames", "-z", base, head, "--"]
        )
    except subprocess.CalledProcessError:
        # A force-pushed/deleted base may not be fetchable. Run everything rather
        # than accidentally report success without testing an unknown diff.
        return None
    return os.fsdecode(diff).split("\0")[:-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", required=True)
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args()
    paths = changed_paths(args.event, args.base, args.head)
    selected = dict.fromkeys(JOBS, True) if paths is None else classify(paths)
    output = "".join(f"{job}={str(run).lower()}\n" for job, run in selected.items())
    print(output, end="")
    if destination := os.environ.get("GITHUB_OUTPUT"):
        with open(destination, "a") as stream:
            stream.write(output)


if __name__ == "__main__":
    main()
