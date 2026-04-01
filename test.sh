#!/usr/bin/env bash
# Tests for claudec. Runs entirely via `claudec sh` — does not test Claude Code CLI itself.
#
# All test profiles are prefixed with __TEST and are cleaned up on exit.
# The first run against a fresh profile triggers bootstrap setup (slow); subsequent
# runs reuse the cached profile and are fast. CI caches ~/.claudec/profiles/__TEST_shared.
#
# Set VERBOSE=1 to see all command output and debug info.
set -euo pipefail

VERBOSE="${VERBOSE:-0}"

debug() {
    if [[ $VERBOSE -eq 1 ]]; then
        echo "    DEBUG: $*" >&2
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDEC="${SCRIPT_DIR}/claudec"

SHARED_PROFILE="__TEST_shared"
SHARED_PROFILE_DIR="${HOME}/.claudec/profiles/${SHARED_PROFILE}"

PASS=0
FAIL=0
FAILURES=()

# Disable auto-update during tests to avoid network variance
export CLAUDEC_IMAGE_AUTO_UPDATE=0

# Use the local bootstrap.sh so tests run against the current code,
# not whatever is baked into the image.
export CLAUDEC_BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/bootstrap.sh"

cleanup() {
    rm -rf "${HOME}/.claudec/profiles/__TEST"* 2>/dev/null || true
    rm -rf /tmp/__TEST* 2>/dev/null || true
}
trap cleanup EXIT

pass() {
    ((PASS++))
    echo "  ✓ $1"
}

fail() {
    ((FAIL++))
    FAILURES+=("$1")
    echo "  ✗ $1"
}

# Run a test function and report pass/fail
test_case() {
    local desc="$1"
    local func="$2"

    debug "Running test: $func"
    if $func; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

# Run claudec and capture combined stdout+stderr. Sets two variables in the
# caller's scope:
#   _out   — captured output
#   _rc    — exit code
# Usage:  run_claudec [env_vars...] [claudec_args...]
# Example: run_claudec CLAUDEC_PROFILE=foo sh echo hello
run_claudec() {
    local env_vars=()
    while [[ $# -gt 0 && "$1" == *=* && "$1" != sh ]]; do
        env_vars+=("$1")
        shift
    done
    _rc=0
    _out=$(env "${env_vars[@]}" "${CLAUDEC}" "$@" 2>&1) || _rc=$?
    debug "claudec ${env_vars[*]} $* => exit $_rc"
    if [[ -n "$_out" ]]; then
        debug "output: $_out"
    fi
}

# ── Stub helper ───────────────────────────────────────────────────────────────
# Creates minimal stubs inside a profile home dir so bootstrap skips the heavy
# swiftly / Swift / Claude Code installation steps.
stub_profile_home() {
    local home_dir="$1"

    mkdir -p \
        "${home_dir}/.local/share/swiftly/bin" \
        "${home_dir}/.local/share/swiftly/toolchains" \
        "${home_dir}/.claude/bin"

    # Stub swiftly binary — bootstrap checks `command -v swiftly`
    printf '#!/bin/sh\nexit 0\n' > "${home_dir}/.local/share/swiftly/bin/swiftly"
    chmod +x "${home_dir}/.local/share/swiftly/bin/swiftly"

    # env.sh — bootstrap sources this to add swiftly to PATH
    printf 'export PATH="${HOME}/.local/share/swiftly/bin:${PATH}"\n' \
        > "${home_dir}/.local/share/swiftly/env.sh"

    # Non-empty toolchains dir — bootstrap skips `swiftly install latest` when non-empty
    touch "${home_dir}/.local/share/swiftly/toolchains/.placeholder"

    # Stub claude binary — bootstrap checks `command -v claude`
    printf '#!/bin/sh\nexit 0\n' > "${home_dir}/.claude/bin/claude"
    chmod +x "${home_dir}/.claude/bin/claude"
}

# ── Preflight ─────────────────────────────────────────────────────────────────
echo "Preflight checks..."
preflight_ok=true

if ! command -v container &>/dev/null; then
    echo "  ✗ 'container' CLI not found in PATH"
    preflight_ok=false
else
    echo "  ✓ container CLI found: $(command -v container)"
fi

if ! command -v sha256sum &>/dev/null; then
    echo "  ✗ 'sha256sum' not found in PATH"
    preflight_ok=false
else
    echo "  ✓ sha256sum found: $(command -v sha256sum)"
fi

if [[ ! -x "${CLAUDEC}" ]]; then
    echo "  ✗ claudec not executable at ${CLAUDEC}"
    preflight_ok=false
else
    echo "  ✓ claudec executable at ${CLAUDEC}"
fi

if [[ "$preflight_ok" != true ]]; then
    echo ""
    echo "Preflight failed. Aborting."
    exit 1
fi

# ── Setup ─────────────────────────────────────────────────────────────────────
echo ""
echo "Preparing shared test profile..."
stub_profile_home "${SHARED_PROFILE_DIR}/home"

# ── Tests ─────────────────────────────────────────────────────────────────────
echo ""
echo "Running tests..."

# Test: claudec sh <command> — arguments are joined and run inside the container
test_sh_command() {
    run_claudec CLAUDEC_PROFILE="${SHARED_PROFILE}" sh echo hello
    [[ $_rc -eq 0 ]] || { debug "Expected exit 0, got $_rc"; return 1; }
    [[ "$_out" == *"hello"* ]] || { debug "Expected 'hello' in output"; return 1; }
}
test_case "claudec sh <command> runs command in container" test_sh_command

# Test: CLAUDEC_PROFILE — profile dir is created at ~/.claudec/profiles/<name>
test_profile_name() {
    local profile="__TEST_profile_name"
    stub_profile_home "${HOME}/.claudec/profiles/${profile}/home"
    run_claudec CLAUDEC_PROFILE="${profile}" sh echo ok
    [[ $_rc -eq 0 ]] || { debug "Expected exit 0, got $_rc"; return 1; }
    [[ -d "${HOME}/.claudec/profiles/${profile}/home" ]] || {
        debug "Profile dir not found at ${HOME}/.claudec/profiles/${profile}/home"
        return 1
    }
}
test_case "CLAUDEC_PROFILE creates profile dir at expected path" test_profile_name

# Test: CLAUDEC_PROFILE_DIR — custom profile dir is used and mounted as /home/claude
test_profile_dir() {
    local dir
    dir="$(mktemp -d /tmp/__TEST_profile_dir.XXXXXX)"
    stub_profile_home "${dir}/home"
    echo "sentinel_content" > "${dir}/home/sentinel.txt"

    run_claudec CLAUDEC_PROFILE_DIR="${dir}" sh cat /home/claude/sentinel.txt
    [[ $_rc -eq 0 ]] || { debug "Expected exit 0, got $_rc"; return 1; }
    [[ "$_out" == *"sentinel_content"* ]] || { debug "Expected 'sentinel_content' in output"; return 1; }
}
test_case "CLAUDEC_PROFILE_DIR mounts custom home dir into container" test_profile_dir

# Test: CLAUDEC_WORKSPACE — custom workspace is mounted
test_workspace() {
    local ws
    ws="$(mktemp -d /tmp/__TEST_workspace.XXXXXX)"
    echo "workspace_content" > "${ws}/probe.txt"

    local hash
    hash="$(printf '%s' "$(cd "${ws}" && pwd -P)" | sha256sum | cut -d' ' -f1)"
    debug "Workspace: $ws  hash: $hash"

    run_claudec CLAUDEC_PROFILE="${SHARED_PROFILE}" CLAUDEC_WORKSPACE="${ws}" \
        sh cat "/workspace/${hash}/probe.txt"
    [[ $_rc -eq 0 ]] || { debug "Expected exit 0, got $_rc"; return 1; }
    [[ "$_out" == *"workspace_content"* ]] || { debug "Expected 'workspace_content' in output"; return 1; }
}
test_case "CLAUDEC_WORKSPACE mounts custom directory as workspace" test_workspace

# Test: CLAUDEC_WORKSPACE — working directory inside container is correct
test_workspace_cwd() {
    local ws
    ws="$(mktemp -d /tmp/__TEST_workspace_cwd.XXXXXX)"

    local hash
    hash="$(printf '%s' "$(cd "${ws}" && pwd -P)" | sha256sum | cut -d' ' -f1)"
    debug "Workspace: $ws  hash: $hash"

    run_claudec CLAUDEC_PROFILE="${SHARED_PROFILE}" CLAUDEC_WORKSPACE="${ws}" sh pwd
    [[ $_rc -eq 0 ]] || { debug "Expected exit 0, got $_rc"; return 1; }
    [[ "$_out" == *"/workspace/${hash}"* ]] || {
        debug "Expected '/workspace/${hash}' in output"
        return 1
    }
}
test_case "CLAUDEC_WORKSPACE sets container working directory correctly" test_workspace_cwd

# Test: CLAUDEC_EXCLUDE_FOLDERS — listed sub-folder appears empty
test_exclude_folders() {
    local ws
    ws="$(mktemp -d /tmp/__TEST_ws_exclude.XXXXXX)"
    mkdir -p "${ws}/secret"
    echo "sensitive_data" > "${ws}/secret/data.txt"

    local hash
    hash="$(printf '%s' "$(cd "${ws}" && pwd -P)" | sha256sum | cut -d' ' -f1)"

    run_claudec CLAUDEC_PROFILE="${SHARED_PROFILE}" CLAUDEC_WORKSPACE="${ws}" \
        CLAUDEC_EXCLUDE_FOLDERS="secret" sh ls "/workspace/${hash}/secret"
    [[ $_rc -eq 0 ]] || { debug "Expected exit 0, got $_rc"; return 1; }
    [[ -z "$_out" ]] || { debug "Expected empty output, got: '$_out'"; return 1; }
}
test_case "CLAUDEC_EXCLUDE_FOLDERS hides sub-folder contents" test_exclude_folders

# Test: CLAUDEC_EXCLUDE_FOLDERS — multiple folders are each hidden
test_exclude_folders_multi() {
    local ws
    ws="$(mktemp -d /tmp/__TEST_ws_exclude_multi.XXXXXX)"
    mkdir -p "${ws}/folderA" "${ws}/folderB"
    echo "a" > "${ws}/folderA/a.txt"
    echo "b" > "${ws}/folderB/b.txt"

    local hash
    hash="$(printf '%s' "$(cd "${ws}" && pwd -P)" | sha256sum | cut -d' ' -f1)"

    run_claudec CLAUDEC_PROFILE="${SHARED_PROFILE}" CLAUDEC_WORKSPACE="${ws}" \
        CLAUDEC_EXCLUDE_FOLDERS="folderA,folderB" sh ls "/workspace/${hash}/folderA"
    local rc_a=$_rc out_a=$_out

    run_claudec CLAUDEC_PROFILE="${SHARED_PROFILE}" CLAUDEC_WORKSPACE="${ws}" \
        CLAUDEC_EXCLUDE_FOLDERS="folderA,folderB" sh ls "/workspace/${hash}/folderB"
    local rc_b=$_rc out_b=$_out

    [[ $rc_a -eq 0 && $rc_b -eq 0 ]] || {
        debug "Expected exit 0 for both, got folderA=$rc_a folderB=$rc_b"
        return 1
    }
    [[ -z "$out_a" && -z "$out_b" ]] || {
        debug "Expected both empty, got folderA='$out_a' folderB='$out_b'"
        return 1
    }
}
test_case "CLAUDEC_EXCLUDE_FOLDERS hides multiple comma-separated folders" test_exclude_folders_multi

# Test: CLAUDEC_CONTAINER_FLAGS — extra flags are passed through
test_container_flags() {
    run_claudec CLAUDEC_PROFILE="${SHARED_PROFILE}" \
        CLAUDEC_CONTAINER_FLAGS="-e __TEST_FLAG=hello_from_flags" \
        sh printenv __TEST_FLAG
    [[ $_rc -eq 0 ]] || { debug "Expected exit 0, got $_rc"; return 1; }
    [[ "$_out" == *"hello_from_flags"* ]] || { debug "Expected 'hello_from_flags' in output"; return 1; }
}
test_case "CLAUDEC_CONTAINER_FLAGS passes extra flags to container run" test_container_flags

# Test: CLAUDEC_BOOTSTRAP_SCRIPT — custom bootstrap script overrides the one in the image
test_bootstrap_script() {
    local custom_bootstrap
    custom_bootstrap="$(mktemp /tmp/__TEST_bootstrap.XXXXXX)"
    cat > "$custom_bootstrap" <<'SCRIPT'
#!/bin/bash
echo "custom_bootstrap_marker"
if [ "${1:-}" = "sh" ]; then
    shift
    exec /bin/bash -c "$*"
fi
SCRIPT
    chmod +x "$custom_bootstrap"

    run_claudec CLAUDEC_PROFILE="${SHARED_PROFILE}" \
        CLAUDEC_BOOTSTRAP_SCRIPT="${custom_bootstrap}" \
        sh echo ok
    rm -f "$custom_bootstrap"
    [[ $_rc -eq 0 ]] || { debug "Expected exit 0, got $_rc"; return 1; }
    [[ "$_out" == *"custom_bootstrap_marker"* ]] || {
        debug "Expected 'custom_bootstrap_marker' in output"
        return 1
    }
}
test_case "CLAUDEC_BOOTSTRAP_SCRIPT overrides bootstrap in container" test_bootstrap_script

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ ${FAIL} -eq 0 ]]; then
    echo "✓ All ${PASS} tests passed"
    exit 0
else
    echo "✗ ${FAIL} test(s) failed, ${PASS} passed"
    echo ""
    echo "Failed tests:"
    for f in "${FAILURES[@]}"; do
        echo "  • ${f}"
    done
    echo ""
    echo "Run with VERBOSE=1 for debugging output:"
    echo "  VERBOSE=1 bash test.sh"
    exit 1
fi
