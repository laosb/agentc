#!/bin/sh
# Standalone macOS validation: real lwIP + engine, deterministic SOCKS transport
# double. Does not require building the container runtime or editing Package.swift.
set -eu
cd "$(dirname "$0")/.."
# Standalone Swift toolchains do not infer Xcode's SDK for clang.
sdk="$(xcrun --sdk macosx --show-sdk-path)"
build=.build/packet-engine-tests
harness=Tests/PacketEngineHarness/PacketEngineHarness.swift
if [ "${1-}" = "--readiness" ]; then
  harness=Tests/PacketEngineHarness/ReadinessHarness.swift
  shift
fi
mkdir -p "$build/objects" "$build/CSOCKSNetwork"
cat > "$build/CSOCKSNetwork/module.modulemap" <<EOF
module CSOCKSNetwork {
  header "$(pwd)/Sources/CSOCKSNetwork/include/CSOCKSNetwork.h"
  export *
}
EOF
vendor=Sources/CSOCKSNetwork/vendor/lwip
for file in Sources/CSOCKSNetwork/network.c \
  "$vendor"/src/core/init.c "$vendor"/src/core/def.c \
  "$vendor"/src/core/inet_chksum.c "$vendor"/src/core/ip.c \
  "$vendor"/src/core/mem.c "$vendor"/src/core/memp.c \
  "$vendor"/src/core/netif.c "$vendor"/src/core/pbuf.c \
  "$vendor"/src/core/stats.c "$vendor"/src/core/sys.c \
  "$vendor"/src/core/tcp.c "$vendor"/src/core/tcp_in.c \
  "$vendor"/src/core/tcp_out.c "$vendor"/src/core/timeouts.c \
  "$vendor"/src/core/ipv4/etharp.c \
  "$vendor"/src/core/ipv4/ip4.c "$vendor"/src/core/ipv4/ip4_addr.c \
  "$vendor"/src/netif/ethernet.c
do
  clang -g -O1 -Wall -Wextra -Werror ${SANITIZE:+-fsanitize=$SANITIZE} \
    -isysroot "$sdk" \
    -I Sources/CSOCKSNetwork/include -I Sources/CSOCKSNetwork/port \
    -I "$vendor/src/include" -c "$file" -o "$build/objects/$(basename "$file").o"
done
swiftc -sdk "$sdk" -swift-version 6 -strict-concurrency=complete \
  -emit-module -emit-library -module-name AgentIsolation \
  Sources/AgentIsolation/SOCKS5Proxy.swift Sources/AgentIsolation/SOCKS5DNS.swift \
  -o "$build/libAgentIsolation.dylib" \
  -emit-module-path "$build/AgentIsolation.swiftmodule"
swiftc -sdk "$sdk" -g -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  ${SANITIZE:+-sanitize=$SANITIZE} -parse-as-library \
  -I "$build" -I "$build/CSOCKSNetwork" -L "$build" -lAgentIsolation \
  -Xlinker -rpath -Xlinker "$(pwd)/$build" \
  Sources/SOCKSNetwork/Packet.swift Sources/SOCKSNetwork/LWIPOutput.swift \
  Sources/SOCKSNetwork/SOCKSNetworkEngine.swift \
  Tests/PacketEngineHarness/MockSOCKS5Connection.swift \
  "$harness" "$build"/objects/*.o \
  -o "$build/packet-engine-tests"
"$build/packet-engine-tests" "$@"
