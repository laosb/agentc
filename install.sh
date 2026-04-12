#!/bin/sh
# agentc installer
# Usage: curl -fsSL https://raw.githubusercontent.com/laosb/agentc/main/install.sh | sh
set -eu

REPO="laosb/agentc"
INSTALL_DIR="${HOME}/.agentc/bin"
LINK_DIR="${HOME}/.local/bin"

info()  { printf '  \033[1;32m✔\033[0m %s\n' "$1"; }
warn()  { printf '  \033[1;33m⚠\033[0m %s\n' "$1"; }
err()   { printf '  \033[1;31m✘\033[0m %s\n' "$1" >&2; exit 1; }

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Required command '$1' not found. Please install it and try again."
    fi
}

fetch() {
    # fetch URL [OUTPUT_FILE]
    # Without OUTPUT_FILE, prints to stdout. With OUTPUT_FILE, saves to file.
    if command -v curl >/dev/null 2>&1; then
        if [ $# -eq 2 ]; then
            curl -fsSL "$1" -o "$2"
        else
            curl -fsSL "$1"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if [ $# -eq 2 ]; then
            wget -q "$1" -O "$2"
        else
            wget -qO- "$1"
        fi
    else
        err "Neither curl nor wget found. Please install one and try again."
    fi
}

detect_platform() {
    OS="$(uname -s)"
    case "$OS" in
        Darwin) OS_LABEL="macos" ;;
        Linux)  OS_LABEL="linux" ;;
        *)      err "Unsupported operating system: $OS" ;;
    esac

    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64)  ARCH_LABEL="x64" ;;
        arm64|aarch64) ARCH_LABEL="arm64" ;;
        *)             err "Unsupported architecture: $ARCH" ;;
    esac
}

check_requirements() {
    if [ "$OS_LABEL" = "macos" ]; then
        MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo "0")"
        MACOS_MAJOR="$(echo "$MACOS_VERSION" | cut -d. -f1)"
        if [ "$MACOS_MAJOR" -lt 15 ] 2>/dev/null; then
            err "macOS 15 or later is required (found ${MACOS_VERSION}). The Apple Container runtime requires macOS 15+."
        fi
        info "Detected macOS ${MACOS_VERSION} (${ARCH_LABEL})"
    elif [ "$OS_LABEL" = "linux" ]; then
        info "Detected Linux (${ARCH_LABEL})"
    fi
}

find_release() {
    API_BASE="https://api.github.com/repos/${REPO}/releases"
    TAG=""
    IS_PRERELEASE=false

    # Try latest stable release first
    RESPONSE="$(fetch "${API_BASE}/latest" 2>/dev/null)" || true
    if [ -n "$RESPONSE" ]; then
        TAG="$(echo "$RESPONSE" | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -1)"
    fi

    if [ -z "$TAG" ]; then
        # No stable release — get all releases and pick the first (latest) one
        RESPONSE="$(fetch "${API_BASE}?per_page=1" 2>/dev/null)" || err "Failed to fetch releases from GitHub."
        TAG="$(echo "$RESPONSE" | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -1)"
        IS_PRERELEASE=true
    fi

    if [ -z "$TAG" ]; then
        err "No releases found for ${REPO}."
    fi

    if [ "$IS_PRERELEASE" = true ]; then
        warn "No stable release found. Installing pre-release ${TAG}."
        warn "This is pre-release software and may be unstable."
    fi
}

build_download_url() {
    if [ "$OS_LABEL" = "linux" ]; then
        # Use static build on Linux for broadest compatibility
        ASSET="agentc-${ARCH_LABEL}-${OS_LABEL}-static.tar.gz"
    else
        ASSET="agentc-${ARCH_LABEL}-${OS_LABEL}.tar.gz"
    fi
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

    # Bootstrap binary is always the Linux static build (runs inside containers).
    BOOTSTRAP_ASSET="agentc-bootstrap-${ARCH_LABEL}-linux-static.tar.gz"
    BOOTSTRAP_URL="https://github.com/${REPO}/releases/download/${TAG}/${BOOTSTRAP_ASSET}"
}

install_binary() {
    info "Downloading agentc ${TAG} (${ARCH_LABEL}-${OS_LABEL})..."

    TMPDIR_DL="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_DL"' EXIT

    fetch "$DOWNLOAD_URL" "${TMPDIR_DL}/${ASSET}" || err "Download failed. Check that the release asset exists: ${DOWNLOAD_URL}"

    tar xzf "${TMPDIR_DL}/${ASSET}" -C "$TMPDIR_DL" || err "Failed to extract archive."

    mkdir -p "$INSTALL_DIR"
    mv "${TMPDIR_DL}/agentc" "${INSTALL_DIR}/agentc"
    chmod +x "${INSTALL_DIR}/agentc"

    mkdir -p "$LINK_DIR"
    ln -sf "${INSTALL_DIR}/agentc" "${LINK_DIR}/agentc"

    info "Installed agentc to ${INSTALL_DIR}/agentc"
    info "Linked to ${LINK_DIR}/agentc"
}

install_bootstrap() {
    info "Downloading bootstrap binary..."

    fetch "$BOOTSTRAP_URL" "${TMPDIR_DL}/${BOOTSTRAP_ASSET}" 2>/dev/null || {
        warn "Bootstrap binary not found in release. It will be downloaded on first run."
        return 0
    }

    tar xzf "${TMPDIR_DL}/${BOOTSTRAP_ASSET}" -C "$TMPDIR_DL" || {
        warn "Failed to extract bootstrap archive. It will be downloaded on first run."
        return 0
    }

    mv "${TMPDIR_DL}/agentc-bootstrap" "${INSTALL_DIR}/bootstrap"
    chmod +x "${INSTALL_DIR}/bootstrap"

    info "Installed bootstrap to ${INSTALL_DIR}/bootstrap"
}

check_path() {
    case ":${PATH}:" in
        *":${LINK_DIR}:"*)
            ;;
        *)
            echo ""
            warn "${LINK_DIR} is not in your PATH."
            echo "  Add it by running one of:"
            echo ""
            echo "    # bash"
            echo "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
            echo ""
            echo "    # zsh"
            echo "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
            echo ""
            echo "    # fish"
            echo "    fish_add_path ~/.local/bin"
            echo ""
            echo "  Then restart your shell or run:"
            echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
            ;;
    esac
}

print_post_install() {
    echo ""
    if [ "$OS_LABEL" = "linux" ]; then
        warn "A Docker or Docker Engine API v1.44+ compatible container runtime"
        warn "must be installed to use agentc."
        echo ""
    fi
    info "Done! Run 'agentc --help' to get started."
}

main() {
    echo ""
    echo "  \033[1magentc installer\033[0m"
    echo ""

    detect_platform
    check_requirements
    find_release
    build_download_url
    install_binary
    install_bootstrap
    check_path
    print_post_install
}

main
