#!/usr/bin/env bash
# Exercise build.sh without a Swift toolchain. Output paths deliberately differ
# from SDK identifiers and contain spaces so inferred or unquoted paths fail.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/bin" "$TEMP/project/Sources/agentc"
cp "$ROOT/build.sh" "$TEMP/project/build.sh"
cp "$ROOT/Sources/agentc/BuildInfo.swift" "$TEMP/project/Sources/agentc/BuildInfo.swift"

cat > "$TEMP/bin/swift" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${!#}" == "--show-bin-path" ]]; then
    # The path query must use exactly the build's options.
    printf '%s\n' "${@:1:$#-1}" > "$MOCK_DIR/query-args"
    cmp "$MOCK_DIR/build-args" "$MOCK_DIR/query-args"
    printf '%s\n' "$MOCK_DIR/actual output"
else
    printf '%s\n' "$@" > "$MOCK_DIR/build-args"
    mkdir -p "$MOCK_DIR/actual output"
    printf 'binary for %s\n' "$*" > "$MOCK_DIR/actual output/agentc"
fi
MOCK
chmod +x "$TEMP/bin/swift"
export PATH="$TEMP/bin:$PATH"
export MOCK_DIR="$TEMP"
export BUILD_VERSION=dev BUILD_GIT_SHA=unknown

cd "$TEMP/project"
for sdk in native x86_64-swift-linux-musl aarch64-swift-linux-musl; do
    for config in release debug; do
        args=(--runtimes docker)
        if [[ "$sdk" != native ]]; then args+=(--swift-sdk "$sdk"); fi
        if [[ "$config" == debug ]]; then args+=(--debug); fi
        bash build.sh "${args[@]}"
        cmp agentc "$MOCK_DIR/actual output/agentc"
        cmp Sources/agentc/BuildInfo.swift "$ROOT/Sources/agentc/BuildInfo.swift"
        echo "PASS: $sdk $config"
    done
done
