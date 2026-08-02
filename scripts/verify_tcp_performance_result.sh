#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-}
if [ -z "$OUTPUT" ] || [ ! -d "$OUTPUT" ]; then
  echo "usage: $0 /absolute/tcp-performance-output" >&2
  exit 64
fi
case "$OUTPUT" in
  /*) ;;
  *) echo "TCP performance output path must be absolute" >&2; exit 64 ;;
esac
for file in flow.log packet.log result.txt SHA256SUMS; do
  test -f "$OUTPUT/$file" || {
    echo "Missing TCP performance evidence: $file" >&2
    exit 1
  }
done
(
  cd "$OUTPUT"
  shasum -a 256 -c SHA256SUMS >/dev/null
)

value() {
  key=$1
  awk -F= -v wanted="$key" '$1 == wanted {print substr($0, length($1) + 2); exit}' \
    "$OUTPUT/result.txt"
}
require_equal() {
  key=$1
  expected=$2
  actual=$(value "$key")
  if [ "$actual" != "$expected" ]; then
    echo "Invalid TCP performance $key: expected $expected, got $actual" >&2
    exit 1
  fi
}
require_number_at_least() {
  key=$1
  minimum=$2
  actual=$(value "$key")
  awk -v actual="$actual" -v minimum="$minimum" \
    'BEGIN { exit !(actual ~ /^[0-9]+([.][0-9]+)?$/ && actual + 0 >= minimum + 0) }' || {
      echo "TCP performance $key below $minimum: $actual" >&2
      exit 1
    }
}
require_number_at_most() {
  key=$1
  maximum=$2
  actual=$(value "$key")
  awk -v actual="$actual" -v maximum="$maximum" \
    'BEGIN { exit !(actual ~ /^[0-9]+([.][0-9]+)?$/ && actual + 0 <= maximum + 0) }' || {
      echo "TCP performance $key above $maximum: $actual" >&2
      exit 1
    }
}

require_equal schema 1
require_equal machine arm64
require_equal repetitions 5
require_equal payload_bytes_per_repetition 33554432
require_equal minimum_engine_mibps 1024
require_equal maximum_added_p95_ms 5
require_equal flow_transport_surface flow_abi
require_equal packet_transport_surface loopback_socks5
require_equal network_extension disabled
require_equal system_network_settings unchanged
require_equal status passed
require_number_at_least flow_engine_mibps 1024
require_number_at_least packet_engine_mibps 1024
require_number_at_most flow_added_p95_ms 5
require_number_at_most packet_added_p95_ms 5
require_number_at_most flow_max_rss_bytes 134217728
require_number_at_most packet_max_rss_bytes 268435456

require_equal flow_harness_sha256 \
  "$(shasum -a 256 "$ROOT/Tests/CoreSmoke/flow_tcp_performance.c" | awk '{print $1}')"
require_equal packet_harness_sha256 \
  "$(shasum -a 256 "$ROOT/Tests/CoreSmoke/packet_tcp_performance.c" | awk '{print $1}')"
require_equal flow_artifact_sha256 \
  "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" | awk '{print $1}')"
require_equal packet_artifact_sha256 \
  "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" | awk '{print $1}')"

grep -F 'flow_tcp_performance repetitions=5 payload_bytes=33554432' \
  "$OUTPUT/flow.log" >/dev/null
grep -F 'packet_tcp_performance repetitions=5 payload_bytes=33554432' \
  "$OUTPUT/packet.log" >/dev/null

echo "TCP performance evidence verified: $OUTPUT"
