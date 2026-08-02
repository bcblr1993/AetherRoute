#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-udp-integrity.XXXXXX")
cleanup() {
  find "$TEMP" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
REQUESTED_OUTPUT=${1:-}
if [ -n "$REQUESTED_OUTPUT" ]; then
  case "$REQUESTED_OUTPUT" in
    /*) OUTPUT=$REQUESTED_OUTPUT ;;
    *) echo "UDP integrity output path must be absolute" >&2; exit 64 ;;
  esac
  if [ -e "$OUTPUT" ]; then
    echo "Refusing to overwrite UDP integrity output: $OUTPUT" >&2
    exit 1
  fi
else
  OUTPUT="$TEMP/output"
fi

if [ "$(uname -m)" != arm64 ]; then
  echo "UDP integrity gate requires Apple silicon" >&2
  exit 1
fi
for command in clang file shasum sw_vers; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "UDP integrity gate requires $command" >&2
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

flow_binary="$TEMP/flow-udp-integrity"
packet_binary="$TEMP/packet-udp-integrity"
compile "$ROOT/Tests/CoreSmoke/flow_udp_integrity.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" "$flow_binary"
compile "$ROOT/Tests/CoreSmoke/packet_udp_integrity.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" "$packet_binary"

env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  /usr/bin/time -lp "$flow_binary" "$TEMP/flow-runtime" \
  >"$OUTPUT/flow.log" 2>&1
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  /usr/bin/time -lp "$packet_binary" "$TEMP/packet-runtime" \
  >"$OUTPUT/packet.log" 2>&1

grep -F \
  'flow_udp_integrity=pass warmup=32 datagrams=10000 missing=0 duplicates=0' \
  "$OUTPUT/flow.log" >/dev/null
grep -F \
  'packet_udp_integrity=pass warmup=32 datagrams=10000 missing=0 duplicates=0' \
  "$OUTPUT/packet.log" >/dev/null
if find "$TEMP/flow-runtime" -type f -print -quit | grep -q .; then
  echo "FlowOnly UDP integrity gate persisted runtime data" >&2
  exit 1
fi
if find "$TEMP/packet-runtime" -type f ! -name existing-sentinel -print -quit \
  | grep -q .; then
  echo "PacketFlow UDP integrity gate persisted runtime data" >&2
  exit 1
fi

flow_rss=$(awk '/maximum resident set size/ {print $1}' "$OUTPUT/flow.log" | tail -1)
packet_rss=$(awk '/maximum resident set size/ {print $1}' "$OUTPUT/packet.log" | tail -1)
{
  printf 'schema=1\n'
  printf 'completed_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'machine=%s\n' "$(uname -m)"
  printf 'os=%s\n' "$(sw_vers -productVersion)"
  printf 'warmup_datagrams=32\n'
  printf 'test_datagrams_per_engine=10000\n'
  printf 'flow_missing=0\nflow_duplicates=0\n'
  printf 'packet_missing=0\npacket_duplicates=0\n'
  printf 'flow_max_rss_bytes=%s\n' "$flow_rss"
  printf 'packet_max_rss_bytes=%s\n' "$packet_rss"
  printf 'flow_harness_sha256=%s\n' \
    "$(shasum -a 256 "$ROOT/Tests/CoreSmoke/flow_udp_integrity.c" | awk '{print $1}')"
  printf 'packet_harness_sha256=%s\n' \
    "$(shasum -a 256 "$ROOT/Tests/CoreSmoke/packet_udp_integrity.c" | awk '{print $1}')"
  printf 'flow_artifact_sha256=%s\n' \
    "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" | awk '{print $1}')"
  printf 'packet_artifact_sha256=%s\n' \
    "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" | awk '{print $1}')"
  printf 'network_extension=disabled\n'
  printf 'system_network_settings=unchanged\n'
  printf 'status=passed\n'
} >"$OUTPUT/result.txt"
(
  cd "$OUTPUT"
  shasum -a 256 flow.log packet.log result.txt >SHA256SUMS
)

"$ROOT/scripts/verify_udp_integrity_result.sh" "$OUTPUT"

cat "$OUTPUT/result.txt"
echo "UDP integrity gate passed: output=$OUTPUT"
