#!/usr/bin/env bash
# Run against ./agentc, reusing the native Swift test bundle for either libc.
set -euo pipefail
export AGENTC_TEST_RUNTIME=docker
export AGENTC_TEST_IMAGE=docker.io/library/swift:6.4.2

python3 scripts/test-acp.py
AGENTC_TEST_ACP_SIGNAL=1 python3 scripts/test-acp.py
python3 scripts/test-host-mcp.py
VERBOSE=1 swift test --skip-build --disable-default-traits \
  --traits ContainerRuntimeDocker --filter AgentcIntegrationTests
