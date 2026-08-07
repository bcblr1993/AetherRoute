#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-tcp-performance.XXXXXX")
cleanup() {
  find "$TEMP" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
REQUESTED_OUTPUT=${1:-}
if [ -n "$REQUESTED_OUTPUT" ]; then
  case "$REQUESTED_OUTPUT" in
    /*) OUTPUT=$REQUESTED_OUTPUT ;;
    *) echo "TCP performance output path must be absolute" >&2; exit 64 ;;
  esac
  if [ -e "$OUTPUT" ]; then
    echo "Refusing to overwrite TCP performance output: $OUTPUT" >&2
    exit 1
  fi
else
  OUTPUT="$TEMP/output"
fi

if [ "$(uname -m)" != arm64 ]; then
  echo "TCP performance gate requires Apple silicon" >&2
  exit 1
fi
for command in awk clang file shasum sw_vers; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "TCP performance gate requires $command" >&2
    exit 1
  }
done

mkdir -p "$OUTPUT" "$TEMP/flow-runtime" "$TEMP/packet-runtime"
touch "$TEMP/packet-runtime/existing-sentinel"

compile() {
  source_file=$1
  library=$2
  binary=$3
  clang -O2 -std=c17 -Wall -Wextra -Werror \
    -mmacosx-version-min=14.0 \
    -I "$ROOT/Core/Headers" \
    "$source_file" "$library" \
    -framework Security -framework SystemConfiguration \
    -framework CoreFoundation -framework CoreServices -lresolv \
    -o "$binary"
  file "$binary" | grep -q 'arm64'
}

flow_binary="$TEMP/flow-tcp-performance"
packet_binary="$TEMP/packet-tcp-performance"
compile "$ROOT/Tests/CoreSmoke/flow_tcp_performance.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" "$flow_binary"
compile "$ROOT/Tests/CoreSmoke/packet_tcp_performance.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" "$packet_binary"

env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  /usr/bin/time -lp "$flow_binary" "$TEMP/flow-runtime" \
  >"$OUTPUT/flow.log" 2>&1
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  /usr/bin/time -lp "$packet_binary" "$TEMP/packet-runtime" \
  >"$OUTPUT/packet.log" 2>&1

if find "$TEMP/flow-runtime" -type f -print -quit | grep -q .; then
  echo "FlowOnly TCP performance gate persisted runtime data" >&2
  exit 1
fi
if find "$TEMP/packet-runtime" -type f ! -name existing-sentinel -print -quit \
  | grep -q .; then
  echo "PacketFlow TCP performance gate persisted runtime data" >&2
  exit 1
fi

metric() {
  log=$1
  key=$2
  awk -v wanted="$key" '
    /^flow_tcp_performance / || /^packet_tcp_performance / {
      for (field = 1; field <= NF; field += 1) {
        split($field, pair, "=")
        if (pair[1] == wanted) {
          print pair[2]
          exit
        }
      }
    }
  ' "$log"
}

flow_direct=$(metric "$OUTPUT/flow.log" direct_mibps)
flow_engine=$(metric "$OUTPUT/flow.log" engine_mibps)
flow_ratio=$(metric "$OUTPUT/flow.log" ratio_percent)
flow_added=$(metric "$OUTPUT/flow.log" added_p95_ms)
packet_direct=$(metric "$OUTPUT/packet.log" direct_mibps)
packet_engine=$(metric "$OUTPUT/packet.log" engine_mibps)
packet_ratio=$(metric "$OUTPUT/packet.log" ratio_percent)
packet_added=$(metric "$OUTPUT/packet.log" added_p95_ms)
flow_rss=$(awk '/maximum resident set size/ {print $1}' "$OUTPUT/flow.log" | tail -1)
packet_rss=$(awk '/maximum resident set size/ {print $1}' "$OUTPUT/packet.log" | tail -1)

require_at_least() {
  key=$1
  actual=$2
  minimum=$3
  awk -v actual="$actual" -v minimum="$minimum" '
    BEGIN {
      exit !(actual ~ /^[0-9]+([.][0-9]+)?$/ && actual + 0 >= minimum + 0)
    }
  ' || {
    echo "TCP performance $key below $minimum: $actual" >&2
    return 1
  }
}
require_at_most() {
  key=$1
  actual=$2
  maximum=$3
  awk -v actual="$actual" -v maximum="$maximum" '
    BEGIN {
      exit !(actual ~ /^[0-9]+([.][0-9]+)?$/ && actual + 0 <= maximum + 0)
    }
  ' || {
    echo "TCP performance $key above $maximum: $actual" >&2
    return 1
  }
}

# A failed measurement must never leave a result that says "passed". Keep the
# raw logs for a caller-provided evidence directory, but create result.txt and
# its checksum only after every release threshold is satisfied.
require_at_least flow_engine_mibps "$flow_engine" 1024
require_at_least packet_engine_mibps "$packet_engine" 1024
require_at_most flow_added_p95_ms "$flow_added" 5
require_at_most packet_added_p95_ms "$packet_added" 5
require_at_most flow_max_rss_bytes "$flow_rss" 134217728
require_at_most packet_max_rss_bytes "$packet_rss" 268435456

{
  printf 'schema=1\n'
  printf 'completed_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'machine=%s\n' "$(uname -m)"
  printf 'os=%s\n' "$(sw_vers -productVersion)"
  printf 'repetitions=5\n'
  printf 'payload_bytes_per_repetition=33554432\n'
  printf 'minimum_engine_mibps=1024\n'
  printf 'maximum_added_p95_ms=5\n'
  printf 'flow_direct_mibps=%s\n' "$flow_direct"
  printf 'flow_engine_mibps=%s\n' "$flow_engine"
  printf 'flow_raw_ratio_percent=%s\n' "$flow_ratio"
  printf 'flow_added_p95_ms=%s\n' "$flow_added"
  printf 'packet_direct_mibps=%s\n' "$packet_direct"
  printf 'packet_engine_mibps=%s\n' "$packet_engine"
  printf 'packet_raw_ratio_percent=%s\n' "$packet_ratio"
  printf 'packet_added_p95_ms=%s\n' "$packet_added"
  printf 'flow_max_rss_bytes=%s\n' "$flow_rss"
  printf 'packet_max_rss_bytes=%s\n' "$packet_rss"
  printf 'flow_harness_sha256=%s\n' \
    "$(shasum -a 256 "$ROOT/Tests/CoreSmoke/flow_tcp_performance.c" | awk '{print $1}')"
  printf 'packet_harness_sha256=%s\n' \
    "$(shasum -a 256 "$ROOT/Tests/CoreSmoke/packet_tcp_performance.c" | awk '{print $1}')"
  printf 'flow_artifact_sha256=%s\n' \
    "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" | awk '{print $1}')"
  printf 'packet_artifact_sha256=%s\n' \
    "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" | awk '{print $1}')"
  printf 'flow_transport_surface=flow_abi\n'
  printf 'packet_transport_surface=loopback_socks5\n'
  printf 'network_extension=disabled\n'
  printf 'system_network_settings=unchanged\n'
  printf 'status=passed\n'
} >"$OUTPUT/result.txt"
(
  cd "$OUTPUT"
  shasum -a 256 flow.log packet.log result.txt >SHA256SUMS
)

"$ROOT/scripts/verify_tcp_performance_result.sh" "$OUTPUT"
cat "$OUTPUT/result.txt"
echo "TCP performance gate passed: output=$OUTPUT"
