#!/bin/sh
# agentc installer
# Usage: curl -fsSL https://raw.githubusercontent.com/laosb/agentc/main/install.sh | sh
#        curl -fsSL https://raw.githubusercontent.com/laosb/agentc/main/install.sh | sh -s -- --beta
set -eu

REPO="laosb/agentc"
INSTALL_DIR="${HOME}/.agentc/bin"
LINK_DIR="${HOME}/.local/bin"

# Release selection, set by parse_args().
CHANNEL="stable"
REQUESTED_VERSION=""

info()  { printf '  \033[1;32m✔\033[0m %s\n' "$1"; }
warn()  { printf '  \033[1;33m⚠\033[0m %s\n' "$1"; }
err()   { printf '  \033[1;31m✘\033[0m %s\n' "$1" >&2; exit 1; }

usage() {
    cat <<'USAGE'
  agentc installer

  Usage:
    install.sh [OPTIONS]
    curl -fsSL https://raw.githubusercontent.com/laosb/agentc/main/install.sh | sh -s -- [OPTIONS]

  Options:
    --beta               Install the latest beta release, or the latest stable
                         release if that one is newer.
    --alpha              Install the latest alpha release, or the latest beta or
                         stable release if one of those is newer.
    -v, --version <ver>  Install a specific release, e.g. '1.4.0' or
                         '1.4.0-beta.0'.
    -h, --help           Show this help.

  Without options, the latest stable release is installed.
USAGE
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Required command '$1' not found. Please install it and try again."
    fi
}

select_channel() {
    if [ "$CHANNEL" != "stable" ] || [ -n "$REQUESTED_VERSION" ]; then
        err "--beta, --alpha and --version are mutually exclusive."
    fi
    CHANNEL="$1"
}

select_version() {
    if [ "$CHANNEL" != "stable" ] || [ -n "$REQUESTED_VERSION" ]; then
        err "--beta, --alpha and --version are mutually exclusive."
    fi
    [ -n "$1" ] || err "--version requires a version, e.g. --version 1.4.0"

    # Tags carry a leading 'v'; accept the version with or without it.
    case "$1" in
        v*) REQUESTED_VERSION="$1" ;;
        *)  REQUESTED_VERSION="v$1" ;;
    esac
    case "$REQUESTED_VERSION" in
        v[0-9]*) ;;
        *) err "Invalid version '$1'. Expected something like '1.4.0' or '1.4.0-beta.0'." ;;
    esac
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --beta)  select_channel "beta" ;;
            --alpha) select_channel "alpha" ;;
            -v|--version)
                [ $# -ge 2 ] || err "--version requires a version, e.g. --version 1.4.0"
                select_version "$2"
                shift
                ;;
            --version=*) select_version "${1#--version=}" ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; err "Unknown option: $1" ;;
        esac
        shift
    done
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

release_tags() {
    # Print the tag_name of every release in the given API response, in the
    # order GitHub returned them (newest first). Splitting on commas keeps at
    # most one tag per line for both pretty-printed and compact JSON.
    printf '%s' "$1" | tr ',' '\n' |
        sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p'
}

tag_channel() {
    # agentc releases are tagged 'vX.Y.Z', optionally with an '-alpha.N' or
    # '-beta.N' suffix. The repo also publishes independently versioned
    # 'toolkit-vN' releases, which belong to no channel and are never installed.
    case "$1" in
        v[0-9]*-alpha*) echo "alpha" ;;
        v[0-9]*-beta*)  echo "beta" ;;
        v[0-9]*-*)      echo "prerelease" ;;
        v[0-9]*)        echo "stable" ;;
        *)              echo "none" ;;
    esac
}

tag_in_channel() {
    # tag_in_channel TAG CHANNEL — each channel also includes the more stable
    # ones, so --beta never installs something older than the latest stable.
    TAG_CHANNEL="$(tag_channel "$1")"
    case "$2" in
        stable) [ "$TAG_CHANNEL" = "stable" ] ;;
        beta)   [ "$TAG_CHANNEL" = "stable" ] || [ "$TAG_CHANNEL" = "beta" ] ;;
        alpha)  [ "$TAG_CHANNEL" != "none" ] ;;
        *)      false ;;
    esac
}

pick_tag() {
    # pick_tag RESPONSE CHANNEL — the newest tag in RESPONSE on CHANNEL, if any.
    for CANDIDATE in $(release_tags "$1"); do
        if tag_in_channel "$CANDIDATE" "$2"; then
            printf '%s\n' "$CANDIDATE"
            return 0
        fi
    done
}

find_release() {
    API_BASE="https://api.github.com/repos/${REPO}/releases"
    TAG=""
    RESPONSE=""

    if [ -n "$REQUESTED_VERSION" ]; then
        RESPONSE="$(fetch "${API_BASE}/tags/${REQUESTED_VERSION}" 2>/dev/null)" || true
        TAG="$(release_tags "$RESPONSE" | head -1)"
        [ -n "$TAG" ] || err "Release ${REQUESTED_VERSION} not found. See https://github.com/${REPO}/releases for the available versions."
    else
        if [ "$CHANNEL" = "stable" ]; then
            RESPONSE="$(fetch "${API_BASE}/latest" 2>/dev/null)" || true
            LATEST_TAG="$(release_tags "$RESPONSE" | head -1)"
            # 'latest' may well be a toolkit release, so only take an agentc one.
            if [ -n "$LATEST_TAG" ] && tag_in_channel "$LATEST_TAG" "stable"; then
                TAG="$LATEST_TAG"
            fi
        fi

        if [ -z "$TAG" ]; then
            RESPONSE="$(fetch "${API_BASE}?per_page=100" 2>/dev/null)" || err "Failed to fetch releases from GitHub."
            TAG="$(pick_tag "$RESPONSE" "$CHANNEL")"
        fi

        if [ -z "$TAG" ] && [ "$CHANNEL" = "stable" ]; then
            # No stable release yet — fall back to the newest pre-release.
            TAG="$(pick_tag "$RESPONSE" "alpha")"
            [ -z "$TAG" ] || warn "No stable release found."
        fi

        [ -n "$TAG" ] || err "No ${CHANNEL} release found for ${REPO}."
    fi

    if ! tag_in_channel "$TAG" "stable"; then
        warn "${TAG} is a pre-release and may be unstable."
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
    parse_args "$@"

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

main "$@"
