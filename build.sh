#!/usr/bin/env bash
# Build and (on macOS with Apple Container support) sign the claudec binary.
#
# Usage:
#   ./build.sh [--debug] [--runtimes apple-container,docker] [--swift-sdk SDK]
#
# Options:
#   --debug           Build in debug mode (default: release)
#   --runtimes LIST   Comma-separated list of runtimes to build in.
#                     Valid values: apple-container, docker
#                     Default on macOS: apple-container,docker
#                     Default on Linux: docker
#   --swift-sdk SDK   Build using the specified Swift SDK (e.g.
#                     x86_64-swift-linux-musl, aarch64-swift-linux-musl).
#                     Used for producing statically linked Linux binaries.
#
# On macOS, if apple-container runtime is included and no Swift SDK is
# specified, the binary is ad-hoc code-signed with the virtualization
# entitlement.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS="${SCRIPT_DIR}/signing/claudec.entitlements"

CONFIG="release"
RUNTIMES=""
SWIFT_SDK=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)
            CONFIG="debug"
            shift
            ;;
        --runtimes)
            RUNTIMES="$2"
            shift 2
            ;;
        --runtimes=*)
            RUNTIMES="${1#*=}"
            shift
            ;;
        --swift-sdk)
            SWIFT_SDK="$2"
            shift 2
            ;;
        --swift-sdk=*)
            SWIFT_SDK="${1#*=}"
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Default runtimes based on platform
if [[ -z "${RUNTIMES}" ]]; then
    case "$(uname -s)" in
        Darwin)
            RUNTIMES="apple-container,docker"
            ;;
        *)
            RUNTIMES="docker"
            ;;
    esac
fi

# Convert runtime names to trait names
TRAITS=""
NEED_SIGN=false
IFS=',' read -ra RT_ARRAY <<< "${RUNTIMES}"
for rt in "${RT_ARRAY[@]}"; do
    rt="$(echo "${rt}" | xargs)"  # trim whitespace
    case "${rt}" in
        apple-container)
            if [[ "$(uname -s)" != "Darwin" ]]; then
                echo "Error: apple-container runtime is only supported on macOS" >&2
                exit 1
            fi
            if [[ -n "${TRAITS}" ]]; then TRAITS="${TRAITS},"; fi
            TRAITS="${TRAITS}ContainerRuntimeAppleContainer"
            NEED_SIGN=true
            ;;
        docker)
            if [[ -n "${TRAITS}" ]]; then TRAITS="${TRAITS},"; fi
            TRAITS="${TRAITS}ContainerRuntimeDocker"
            ;;
        *)
            echo "Unknown runtime: ${rt}" >&2
            echo "Valid runtimes: apple-container, docker" >&2
            exit 1
            ;;
    esac
done

if [[ -z "${TRAITS}" ]]; then
    echo "Error: at least one runtime must be specified" >&2
    exit 1
fi

echo "Building claudec (${CONFIG}) with runtimes: ${RUNTIMES}..."
echo "  Traits: ${TRAITS}"
if [[ -n "${SWIFT_SDK}" ]]; then
    echo "  Swift SDK: ${SWIFT_SDK}"
fi

BUILD_ARGS=(-c "${CONFIG}" --disable-default-traits --traits "${TRAITS}")
if [[ -n "${SWIFT_SDK}" ]]; then
    BUILD_ARGS+=(--swift-sdk "${SWIFT_SDK}")
fi
swift build "${BUILD_ARGS[@]}"

if [[ -n "${SWIFT_SDK}" ]]; then
    BUILT_BINARY="${SCRIPT_DIR}/.build/${SWIFT_SDK}/${CONFIG}/claudec"
else
    BUILT_BINARY="${SCRIPT_DIR}/.build/${CONFIG}/claudec"
fi
OUTPUT_BINARY="${SCRIPT_DIR}/claudec"

if [[ "${NEED_SIGN}" == true ]] && [[ "$(uname -s)" == "Darwin" ]] && [[ -z "${SWIFT_SDK}" ]]; then
    echo "Signing with virtualization entitlement..."
    codesign --sign - --entitlements "${ENTITLEMENTS}" --force "${BUILT_BINARY}"
fi

cp "${BUILT_BINARY}" "${OUTPUT_BINARY}"
echo "Done → ${OUTPUT_BINARY}"
