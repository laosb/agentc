#!/usr/bin/env bash
# Build and sign the claudec binary.
# Usage: ./build.sh [--release | --debug]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS="${SCRIPT_DIR}/signing/claudec.entitlements"

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
    CONFIG="debug"
fi

echo "Building claudec (${CONFIG})..."
swiftly run swift build -c "${CONFIG}"

BUILT_BINARY="${SCRIPT_DIR}/.build/${CONFIG}/claudec"
OUTPUT_BINARY="${SCRIPT_DIR}/claudec"

echo "Signing..."
codesign --sign - --entitlements "${ENTITLEMENTS}" --force "${BUILT_BINARY}"

cp "${BUILT_BINARY}" "${OUTPUT_BINARY}"
echo "Done → ${OUTPUT_BINARY}"
