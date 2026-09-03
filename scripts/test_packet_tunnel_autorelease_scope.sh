#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE="$ROOT/Sources/AetherRoutePacketTunnel/CoreBridge.swift"
PROVIDER="$ROOT/Sources/AetherRoutePacketTunnel/PacketTunnelProvider.swift"

fail() {
  echo "packet tunnel autorelease scope guard failed: $*" >&2
  exit 1
}

test -f "$CORE" || fail "CoreBridge.swift missing"
test -f "$PROVIDER" || fail "PacketTunnelProvider.swift missing"

core_work_item_count=$(grep -F -c 'autoreleaseFrequency: .workItem' "$CORE")
provider_work_item_count=$(grep -F -c 'autoreleaseFrequency: .workItem' "$PROVIDER")
core_pool_count=$(grep -F -c 'autoreleasepool {' "$CORE")

test "$core_work_item_count" -ge 1 \
  || fail "packet output queue must drain autoreleased objects per work item"
test "$provider_work_item_count" -ge 1 \
  || fail "provider message queue must drain autoreleased objects per work item"
test "$core_pool_count" -ge 2 \
  || fail "packet input and output paths must keep local autorelease pools"

grep -Fq 'packetFlow.writePackets(' "$CORE" \
  || fail "packet output bridge missing"
grep -Fq 'packetFlow.readPackets {' "$CORE" \
  || fail "packet input bridge missing"

echo "Packet tunnel autorelease scope guard passed."
