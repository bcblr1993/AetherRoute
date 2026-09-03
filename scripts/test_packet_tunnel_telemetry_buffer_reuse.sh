#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE="$ROOT/Sources/AetherRoutePacketTunnel/CoreBridge.swift"

fail() {
  echo "packet tunnel telemetry buffer reuse guard failed: $*" >&2
  exit 1
}

test -f "$CORE" || fail "CoreBridge.swift missing"

grep -Fq 'private var telemetryOutputBuffer = Data(' "$CORE" \
  || fail "bridge-lifetime telemetry output buffer missing"
grep -Fq 'count: NetworkTelemetryCodec.maximumMessageBytes' "$CORE" \
  || fail "telemetry buffer must cover the complete trust boundary"

method=$(sed -n '/    func telemetrySnapshot(/,/    fileprivate func writePacket(/p' "$CORE")
call_count=$(printf '%s\n' "$method" \
  | grep -F -c 'clash_packet_telemetry_snapshot_v1(')
test "$call_count" -eq 1 \
  || fail "each telemetry poll must create exactly one Rust snapshot"
printf '%s\n' "$method" | grep -Fq 'telemetryOutputBuffer.withUnsafeMutableBytes' \
  || fail "telemetry FFI call must write into the reusable buffer"
printf '%s\n' "$method" | grep -Fq 'telemetryOutputBuffer.prefix(requiredLength)' \
  || fail "decoder must be bounded to the returned payload length"
if printf '%s\n' "$method" | grep -Fq 'for _ in 0..<2'; then
  fail "query/copy retry loop must not return"
fi
if printf '%s\n' "$method" | grep -Eq 'clash_packet_telemetry_snapshot_v1\([^)]*nil'; then
  fail "size-query snapshot must not return"
fi

echo "Packet tunnel telemetry buffer reuse guard passed."
