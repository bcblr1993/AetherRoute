#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-}
case "$OUTPUT" in
  /*) ;;
  *) echo "usage: $0 /absolute/udp-integrity-output" >&2; exit 64 ;;
esac
test -d "$OUTPUT" || {
  echo "UDP integrity evidence directory is missing: $OUTPUT" >&2
  exit 1
}
for file in flow.log packet.log result.txt SHA256SUMS; do
  test -f "$OUTPUT/$file" || {
    echo "UDP integrity evidence is missing $file" >&2
    exit 1
  }
done
(
  cd "$OUTPUT"
  shasum -a 256 -c SHA256SUMS >/dev/null
)

value() {
  key=$1
  awk -F= -v key="$key" '
    $1 == key { count += 1; value = substr($0, index($0, "=") + 1) }
    END { if (count != 1) exit 1; print value }
  ' "$OUTPUT/result.txt"
}

test "$(value schema)" = 1
test "$(value machine)" = arm64
test "$(value warmup_datagrams)" = 32
test "$(value test_datagrams_per_engine)" = 10000
test "$(value flow_missing)" = 0
test "$(value flow_duplicates)" = 0
test "$(value packet_missing)" = 0
test "$(value packet_duplicates)" = 0
test "$(value network_extension)" = disabled
test "$(value system_network_settings)" = unchanged
test "$(value status)" = passed

flow_rss=$(value flow_max_rss_bytes)
packet_rss=$(value packet_max_rss_bytes)
case "$flow_rss:$packet_rss" in
  *[!0-9:]*) echo "UDP integrity RSS evidence is not numeric" >&2; exit 1 ;;
esac
test "$flow_rss" -gt 0
test "$flow_rss" -le 67108864
test "$packet_rss" -gt 0
test "$packet_rss" -le 33554432

test "$(value flow_harness_sha256)" = \
  "$(shasum -a 256 "$ROOT/Tests/CoreSmoke/flow_udp_integrity.c" | awk '{print $1}')"
test "$(value packet_harness_sha256)" = \
  "$(shasum -a 256 "$ROOT/Tests/CoreSmoke/packet_udp_integrity.c" | awk '{print $1}')"
test "$(value flow_artifact_sha256)" = \
  "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" | awk '{print $1}')"
test "$(value packet_artifact_sha256)" = \
  "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" | awk '{print $1}')"

grep -Fx \
  'flow_udp_integrity=pass warmup=32 datagrams=10000 missing=0 duplicates=0' \
  "$OUTPUT/flow.log" >/dev/null
grep -Fx \
  'packet_udp_integrity=pass warmup=32 datagrams=10000 missing=0 duplicates=0' \
  "$OUTPUT/packet.log" >/dev/null

echo "UDP integrity evidence verified: $OUTPUT"
