#!/bin/bash
set -e

# Adjust docker group GID to match the mounted socket, if present
if [ -S /var/run/docker.sock ]; then
    SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
    CURRENT_GID=$(getent group docker | cut -d: -f3)
    if [ "$SOCK_GID" != "$CURRENT_GID" ] && [ "$SOCK_GID" != "0" ]; then
        sudo groupmod -g "$SOCK_GID" docker
    fi
fi

# Ensure volume-mounted user home is owned by claude
sudo chown -R claude:claude /home/claude 2>/dev/null || true

# ── Swiftly ────────────────────────────────────────────────────────────────────
SWIFTLY_HOME="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}"

if [ ! -x "$SWIFTLY_HOME/bin/swiftly" ]; then
    ARCH=$(uname -m)
    SWIFTLY_URL="https://download.swift.org/swiftly/linux/swiftly-${ARCH}.tar.gz"

    echo "==> System info: $(uname -a)"
    echo "==> Downloading swiftly from: ${SWIFTLY_URL}"

    curl -fsSL "${SWIFTLY_URL}" -o /tmp/swiftly.tar.gz
    tar -zxf /tmp/swiftly.tar.gz -C /tmp

    # debian:latest is Debian 13 (Trixie); swiftly's platform detection only
    # knows debian12. Override to debian12, which is ABI-compatible.
    echo "==> Installing swiftly (platform override: debian12)..."
    /tmp/swiftly init --quiet-shell-followup --assume-yes --platform debian12
    rm -f /tmp/swiftly /tmp/swiftly.tar.gz
fi

# Source swiftly environment so PATH is updated
[ -f "$SWIFTLY_HOME/env.sh" ] && . "$SWIFTLY_HOME/env.sh"

# Install latest stable Swift toolchain if none is active
if command -v swiftly &>/dev/null && ! swift --version &>/dev/null 2>&1; then
    echo "==> Installing Swift latest release..."
    swiftly install --assume-yes latest
fi

# Extend PATH with all user-local bin directories
export PATH="$HOME/.claude/bin:$HOME/.local/bin:$SWIFTLY_HOME/bin:$PATH"

# ── Claude Code ────────────────────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
    echo "==> Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
    # Re-export PATH in case the installer added new directories
    export PATH="$HOME/.claude/bin:$HOME/.local/bin:$PATH"
fi

exec claude "$@"
