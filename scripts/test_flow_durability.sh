#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROUNDS=${AETHERROUTE_FLOW_DURABILITY_ROUNDS:-1000}
ROUND_TIMEOUT=${AETHERROUTE_FLOW_DURABILITY_TIMEOUT_SECONDS:-30}
RSS_BUDGET=${AETHERROUTE_FLOW_DURABILITY_RSS_BUDGET_BYTES:-67108864}
OUTPUT=${1:-}

if [ "${AETHERROUTE_ALLOW_FLOW_DURABILITY:-NO}" != YES ]; then
  echo "Set AETHERROUTE_ALLOW_FLOW_DURABILITY=YES to run this isolated gate." >&2
  exit 64
fi
for VALUE in "$ROUNDS" "$ROUND_TIMEOUT" "$RSS_BUDGET"; do
  case "$VALUE" in
    ''|*[!0-9]*) echo "Durability limits must be integers" >&2; exit 64 ;;
  esac
done
if [ "$ROUNDS" -lt 1 ] || [ "$ROUNDS" -gt 100000 ]; then
  echo "AETHERROUTE_FLOW_DURABILITY_ROUNDS must be between 1 and 100000" >&2
  exit 64
fi
if [ "$ROUND_TIMEOUT" -lt 10 ] || [ "$ROUND_TIMEOUT" -gt 600 ]; then
  echo "AETHERROUTE_FLOW_DURABILITY_TIMEOUT_SECONDS must be between 10 and 600" >&2
  exit 64
fi
if [ "$RSS_BUDGET" -lt 1048576 ]; then
  echo "AETHERROUTE_FLOW_DURABILITY_RSS_BUDGET_BYTES is too small" >&2
  exit 64
fi
if [ -z "$OUTPUT" ]; then
  echo "usage: test_flow_durability.sh /new/output/directory" >&2
  exit 64
fi
case "$OUTPUT" in
  /*) ;;
  *) OUTPUT="$ROOT/$OUTPUT" ;;
esac
if [ -e "$OUTPUT" ]; then
  echo "Refusing to overwrite existing durability output: $OUTPUT" >&2
  exit 1
fi
if [ "$(uname -m)" != arm64 ]; then
  echo "The FlowOnly durability gate requires Apple silicon" >&2
  exit 1
fi

TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-flow-durability.XXXXXX")
CURRENT_PID=
cleanup() {
  if [ -n "$CURRENT_PID" ] && kill -0 "$CURRENT_PID" 2>/dev/null; then
    kill -TERM "$CURRENT_PID" 2>/dev/null || true
    wait "$CURRENT_PID" 2>/dev/null || true
  fi
  find "$TEMP" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$OUTPUT" "$TEMP/runtime"
BINARY="$TEMP/flow-core-smoke"
clang \
  -std=c17 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/flow_core_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" \
  -framework Security -framework SystemConfiguration \
  -framework CoreFoundation -framework CoreServices -lresolv \
  -o "$BINARY"
file "$BINARY" | grep -q arm64

SUMMARY="$OUTPUT/rounds.tsv"
printf 'round\tcompleted_utc\twall_seconds\tmax_rss_bytes\tresult_sha256\n' >"$SUMMARY"
{
  printf 'schema=1\n'
  printf 'started_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'requested_rounds=%s\n' "$ROUNDS"
  printf 'cycles_per_round=500\n'
  printf 'udp_probe_datagrams=3\n'
  printf 'failure_diagnostics=callback-and-echo-server\n'
  printf 'round_timeout_seconds=%s\n' "$ROUND_TIMEOUT"
  printf 'rss_budget_bytes=%s\n' "$RSS_BUDGET"
  printf 'machine=%s\n' "$(uname -m)"
  printf 'os=%s\n' "$(sw_vers -productVersion)"
  printf 'harness_sha256=%s\n' "$(shasum -a 256 "$ROOT/Tests/CoreSmoke/flow_core_smoke.c" | awk '{print $1}')"
  printf 'artifact_sha256=%s\n' "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" | awk '{print $1}')"
  printf 'network_extension=disabled\n'
  printf 'system_network_settings=unchanged\n'
} >"$OUTPUT/metadata.txt"

round=0
peak=0
while [ "$round" -lt "$ROUNDS" ]; do
  round=$((round + 1))
  log="$OUTPUT/latest.log"
  started=$(date +%s)
  /usr/bin/time -lp "$BINARY" "$TEMP/runtime" >"$log" 2>&1 &
  CURRENT_PID=$!
  while kill -0 "$CURRENT_PID" 2>/dev/null; do
    if [ "$(($(date +%s) - started))" -ge "$ROUND_TIMEOUT" ]; then
      kill -TERM "$CURRENT_PID" 2>/dev/null || true
      wait "$CURRENT_PID" 2>/dev/null || true
      CURRENT_PID=
      cp "$log" "$OUTPUT/failure-round-$round.log"
      echo "FlowOnly durability round $round timed out" >&2
      exit 124
    fi
    sleep 1
  done
  set +e
  wait "$CURRENT_PID"
  status=$?
  set -e
  CURRENT_PID=
  if [ "$status" -ne 0 ]; then
    cp "$log" "$OUTPUT/failure-round-$round.log"
    echo "FlowOnly durability round $round failed with status $status" >&2
    exit "$status"
  fi
  rss=$(awk '/maximum resident set size/ {print $1}' "$log" | tail -1)
  case "$rss" in
    ''|*[!0-9]*) echo "FlowOnly round $round has no RSS evidence" >&2; exit 1 ;;
  esac
  if [ "$rss" -gt "$RSS_BUDGET" ]; then
    cp "$log" "$OUTPUT/failure-round-$round.log"
    echo "FlowOnly round $round exceeded RSS budget" >&2
    exit 1
  fi
  if [ "$rss" -gt "$peak" ]; then peak=$rss; fi
  hash=$(shasum -a 256 "$log" | awk '{print $1}')
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$round" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$(($(date +%s) - started))" "$rss" "$hash" >>"$SUMMARY"
  if [ $((round % 100)) -eq 0 ]; then
    printf 'FlowOnly durability heartbeat: round=%s cycles=%s\n' \
      "$round" "$((round * 500))"
  fi
done

if find "$TEMP/runtime" -type f -print -quit | grep -q .; then
  echo "FlowOnly core unexpectedly persisted runtime data" >&2
  exit 1
fi
{
  printf 'completed_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'rounds=%s\n' "$round"
  printf 'lifecycle_cycles=%s\n' "$((round * 500))"
  printf 'peak_rss_bytes=%s\n' "$peak"
  printf 'status=passed\n'
} >"$OUTPUT/result.txt"
shasum -a 256 "$OUTPUT/metadata.txt" "$SUMMARY" "$OUTPUT/result.txt" \
  >"$OUTPUT/SHA256SUMS"
printf 'FlowOnly durability passed: rounds=%s cycles=%s peak_rss=%s output=%s\n' \
  "$round" "$((round * 500))" "$peak" "$OUTPUT"
