#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DURATION=${AETHERROUTE_SOAK_DURATION_SECONDS:-86400}
PACKET_CYCLES=${AETHERROUTE_SOAK_PACKET_CYCLES:-1000}
ROUND_TIMEOUT=${AETHERROUTE_SOAK_ROUND_TIMEOUT_SECONDS:-600}
FLOW_RSS_BUDGET=${AETHERROUTE_SOAK_FLOW_RSS_BUDGET_BYTES:-67108864}
PACKET_RSS_BUDGET=${AETHERROUTE_SOAK_PACKET_RSS_BUDGET_BYTES:-33554432}
FD_GROWTH_BUDGET=${AETHERROUTE_SOAK_FD_GROWTH_BUDGET:-4}
OUTPUT=${1:-}

if [ "${AETHERROUTE_ALLOW_ISOLATED_SOAK:-NO}" != YES ]; then
  echo "Set AETHERROUTE_ALLOW_ISOLATED_SOAK=YES to run the isolated soak." >&2
  exit 64
fi
case "$DURATION" in
  ''|*[!0-9]*) echo "AETHERROUTE_SOAK_DURATION_SECONDS must be an integer" >&2; exit 64 ;;
esac
case "$PACKET_CYCLES" in
  ''|*[!0-9]*) echo "AETHERROUTE_SOAK_PACKET_CYCLES must be an integer" >&2; exit 64 ;;
esac
case "$ROUND_TIMEOUT" in
  ''|*[!0-9]*) echo "AETHERROUTE_SOAK_ROUND_TIMEOUT_SECONDS must be an integer" >&2; exit 64 ;;
esac
case "$FLOW_RSS_BUDGET" in
  ''|*[!0-9]*) echo "AETHERROUTE_SOAK_FLOW_RSS_BUDGET_BYTES must be an integer" >&2; exit 64 ;;
esac
case "$PACKET_RSS_BUDGET" in
  ''|*[!0-9]*) echo "AETHERROUTE_SOAK_PACKET_RSS_BUDGET_BYTES must be an integer" >&2; exit 64 ;;
esac
case "$FD_GROWTH_BUDGET" in
  ''|*[!0-9]*) echo "AETHERROUTE_SOAK_FD_GROWTH_BUDGET must be an integer" >&2; exit 64 ;;
esac
if [ "$DURATION" -lt 60 ] || [ "$DURATION" -gt 93600 ]; then
  echo "AETHERROUTE_SOAK_DURATION_SECONDS must be between 60 and 93600" >&2
  exit 64
fi
if [ "$PACKET_CYCLES" -lt 1 ] || [ "$PACKET_CYCLES" -gt 1000 ]; then
  echo "AETHERROUTE_SOAK_PACKET_CYCLES must be between 1 and 1000" >&2
  exit 64
fi
if [ "$ROUND_TIMEOUT" -lt 30 ] || [ "$ROUND_TIMEOUT" -gt 1800 ]; then
  echo "AETHERROUTE_SOAK_ROUND_TIMEOUT_SECONDS must be between 30 and 1800" >&2
  exit 64
fi
if [ "$FLOW_RSS_BUDGET" -lt 1048576 ] || \
   [ "$PACKET_RSS_BUDGET" -lt 1048576 ]; then
  echo "RSS budgets must be at least 1048576 bytes" >&2
  exit 64
fi
if [ "$FD_GROWTH_BUDGET" -gt 64 ]; then
  echo "AETHERROUTE_SOAK_FD_GROWTH_BUDGET must be at most 64" >&2
  exit 64
fi
if [ -z "$OUTPUT" ]; then
  echo "usage: test_isolated_soak.sh /new/output/directory" >&2
  exit 64
fi
case "$OUTPUT" in
  /*) ;;
  *) OUTPUT="$ROOT/$OUTPUT" ;;
esac
if [ -e "$OUTPUT" ]; then
  echo "Refusing to overwrite existing soak output: $OUTPUT" >&2
  exit 1
fi

if [ "$(uname -m)" != arm64 ]; then
  echo "The isolated soak requires an Apple-silicon Mac" >&2
  exit 1
fi

TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-isolated-soak.XXXXXX")
CURRENT_PID=
CAFFEINATE_PID=
cleanup() {
  if [ -n "$CURRENT_PID" ] && kill -0 "$CURRENT_PID" 2>/dev/null; then
    kill -TERM "$CURRENT_PID" 2>/dev/null || true
    wait "$CURRENT_PID" 2>/dev/null || true
  fi
  if [ -n "$CAFFEINATE_PID" ] && kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
    kill -TERM "$CAFFEINATE_PID" 2>/dev/null || true
    wait "$CAFFEINATE_PID" 2>/dev/null || true
  fi
  find "$TEMP" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

SOURCE_MANIFEST_BEFORE="$TEMP/source-before.txt"
SOURCE_MANIFEST_AFTER="$TEMP/source-after.txt"
"$ROOT/scripts/source_manifest.sh" >"$SOURCE_MANIFEST_BEFORE"
SOURCE_MANIFEST_SHA256=$(awk \
  '$1 == "MANIFEST_SHA256" {print $2}' "$SOURCE_MANIFEST_BEFORE")
printf '%s\n' "$SOURCE_MANIFEST_SHA256" | grep -Eq '^[0-9a-f]{64}$' || {
  echo "Could not resolve the soak source manifest" >&2
  exit 1
}
GIT_COMMIT=$(git -C "$ROOT" rev-parse HEAD)
printf '%s\n' "$GIT_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || {
  echo "Could not resolve the soak source commit" >&2
  exit 1
}

diagnostic_manifest() {
  for diagnostic_directory in \
    "$HOME/Library/Logs/DiagnosticReports" \
    /Library/Logs/DiagnosticReports
  do
    if [ -d "$diagnostic_directory" ]; then
      find "$diagnostic_directory" -maxdepth 1 -type f \
        \( -name 'flow-core-smoke*' -o -name 'packet-core-smoke*' \) \
        -print 2>/dev/null || true
    fi
  done | awk -F/ '{print $NF}' | sort -u
}

mkdir -p "$OUTPUT" "$TEMP/flow-runtime" "$TEMP/packet-runtime"
touch "$TEMP/packet-runtime/existing-sentinel"
FLOW_BINARY="$TEMP/flow-core-smoke"
PACKET_BINARY="$TEMP/packet-core-smoke"
diagnostic_manifest >"$TEMP/diagnostics-before.txt"

clang \
  -std=c17 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/flow_core_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" \
  -framework Security -framework SystemConfiguration \
  -framework CoreFoundation -framework CoreServices -lresolv \
  -o "$FLOW_BINARY"
clang \
  -std=c17 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/packet_tunnel_core_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" \
  -framework Security -framework SystemConfiguration \
  -framework CoreFoundation -framework CoreServices -lresolv \
  -o "$PACKET_BINARY"
file "$FLOW_BINARY" | grep -q 'arm64'
file "$PACKET_BINARY" | grep -q 'arm64'

START_EPOCH=$(date +%s)
START_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
DEADLINE=$((START_EPOCH + DURATION))
SUMMARY="$OUTPUT/rounds.tsv"
printf 'round\tengine\tcompleted_utc\twall_seconds\tcycles\tmax_rss_bytes\tresult_sha256\tfd_growth\n' >"$SUMMARY"
{
  printf 'schema=2\n'
  printf 'started_utc=%s\n' "$START_UTC"
  printf 'requested_duration_seconds=%s\n' "$DURATION"
  printf 'packet_cycles_per_round=%s\n' "$PACKET_CYCLES"
  printf 'flow_udp_probe_datagrams=3\n'
  printf 'round_timeout_seconds=%s\n' "$ROUND_TIMEOUT"
  printf 'flow_rss_budget_bytes=%s\n' "$FLOW_RSS_BUDGET"
  printf 'packet_rss_budget_bytes=%s\n' "$PACKET_RSS_BUDGET"
  printf 'fd_growth_budget=%s\n' "$FD_GROWTH_BUDGET"
  printf 'machine=%s\n' "$(uname -m)"
  printf 'os=%s\n' "$(sw_vers -productVersion)"
  printf 'git_commit=%s\n' "$GIT_COMMIT"
  printf 'source_manifest_sha256=%s\n' "$SOURCE_MANIFEST_SHA256"
  printf 'runner_sha256=%s\n' "$(shasum -a 256 "$ROOT/scripts/test_isolated_soak.sh" | awk '{print $1}')"
  printf 'flow_harness_sha256=%s\n' "$(shasum -a 256 "$ROOT/Tests/CoreSmoke/flow_core_smoke.c" | awk '{print $1}')"
  printf 'packet_harness_sha256=%s\n' "$(shasum -a 256 "$ROOT/Tests/CoreSmoke/packet_tunnel_core_smoke.c" | awk '{print $1}')"
  printf 'flow_artifact_sha256=%s\n' "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" | awk '{print $1}')"
  printf 'packet_artifact_sha256=%s\n' "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" | awk '{print $1}')"
  printf 'diagnostic_report_scan=exact-process-basename\n'
  printf 'orphan_process_scan=exact-binary-path\n'
  printf 'network_extension=disabled\n'
  printf 'system_network_settings=unchanged\n'
} >"$OUTPUT/metadata.txt"

caffeinate -i -m -s -w "$$" &
CAFFEINATE_PID=$!

run_with_watchdog() {
  engine=$1
  round=$2
  log="$OUTPUT/latest-$engine.log"
  started=$(date +%s)

  if [ "$engine" = flow ]; then
    /usr/bin/time -lp env \
      AETHER_SMOKE_FD_GROWTH_BUDGET="$FD_GROWTH_BUDGET" \
      "$FLOW_BINARY" "$TEMP/flow-runtime" >"$log" 2>&1 &
  else
    /usr/bin/time -lp env \
      AETHER_SMOKE_CYCLES="$PACKET_CYCLES" \
      AETHER_SMOKE_RSS_BUDGET_BYTES="$PACKET_RSS_BUDGET" \
      AETHER_SMOKE_FD_GROWTH_BUDGET="$FD_GROWTH_BUDGET" \
      "$PACKET_BINARY" \
        "$TEMP/packet-runtime" "$TEMP/ignored.log" >"$log" 2>&1 &
  fi
  CURRENT_PID=$!

  while kill -0 "$CURRENT_PID" 2>/dev/null; do
    now=$(date +%s)
    if [ $((now - started)) -ge "$ROUND_TIMEOUT" ]; then
      kill -TERM "$CURRENT_PID" 2>/dev/null || true
      attempt=0
      while kill -0 "$CURRENT_PID" 2>/dev/null && [ "$attempt" -lt 50 ]; do
        attempt=$((attempt + 1))
        sleep 0.1
      done
      if kill -0 "$CURRENT_PID" 2>/dev/null; then
        kill -KILL "$CURRENT_PID" 2>/dev/null || true
      fi
      wait "$CURRENT_PID" 2>/dev/null || true
      CURRENT_PID=
      cp "$log" "$OUTPUT/failure-$engine-round-$round.log"
      echo "$engine round $round exceeded ${ROUND_TIMEOUT}s" >&2
      return 124
    fi
    sleep 1
  done

  set +e
  wait "$CURRENT_PID"
  status=$?
  set -e
  CURRENT_PID=
  if [ "$status" -ne 0 ]; then
    cp "$log" "$OUTPUT/failure-$engine-round-$round.log"
    echo "$engine round $round failed with status $status" >&2
    return "$status"
  fi

  ended=$(date +%s)
  wall=$((ended - started))
  rss=$(awk '/maximum resident set size/ {print $1}' "$log" | tail -1)
  case "$rss" in
    ''|*[!0-9]*)
      cp "$log" "$OUTPUT/failure-$engine-round-$round.log"
      echo "$engine round $round did not report maximum RSS" >&2
      return 1
      ;;
  esac
  if [ "$engine" = flow ]; then
    cycles=$(awk -F'[ =]' '/^flow_cycles=/ {print $2}' "$log" | tail -1)
    budget=$FLOW_RSS_BUDGET
  else
    cycles=$PACKET_CYCLES
    budget=$PACKET_RSS_BUDGET
  fi
  if [ "$rss" -gt "$budget" ]; then
    cp "$log" "$OUTPUT/failure-$engine-round-$round.log"
    echo "$engine round $round exceeded RSS budget: $rss > $budget" >&2
    return 1
  fi
  fd_growth=$(awk '{
    for (field_index = 1; field_index <= NF; field_index++) {
      if ($field_index ~ /^fd_growth=-?[0-9]+$/) {
        split($field_index, parts, "=")
        value=parts[2]
      }
    }
  }
  END {if (value != "") print value}' "$log")
  if ! printf '%s\n' "$fd_growth" | grep -Eq '^-?[0-9]+$'; then
    cp "$log" "$OUTPUT/failure-$engine-round-$round.log"
    echo "$engine round $round did not report valid FD growth" >&2
    return 1
  fi
  if [ "$fd_growth" -gt "$FD_GROWTH_BUDGET" ]; then
    cp "$log" "$OUTPUT/failure-$engine-round-$round.log"
    echo "$engine round $round exceeded FD growth budget" >&2
    return 1
  fi
  result_hash=$(shasum -a 256 "$log" | awk '{print $1}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$round" "$engine" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$wall" "$cycles" "$rss" "$result_hash" "$fd_growth" >>"$SUMMARY"
}

round=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  round=$((round + 1))
  run_with_watchdog flow "$round"
  run_with_watchdog packet "$round"
  printf 'soak heartbeat: round=%s elapsed_seconds=%s\n' \
    "$round" "$(($(date +%s) - START_EPOCH))"
done

if find "$TEMP/flow-runtime" -type f -print -quit | grep -q .; then
  echo "FlowOnly core unexpectedly persisted runtime data" >&2
  exit 1
fi
if [ -e "$TEMP/ignored.log" ]; then
  echo "Packet core unexpectedly opened the compatibility log path" >&2
  exit 1
fi
if find "$TEMP/packet-runtime" -type f ! -name existing-sentinel -print -quit |
  grep -q .; then
  echo "Packet core unexpectedly persisted runtime data" >&2
  exit 1
fi

orphan_file="$TEMP/orphan-processes.txt"
: >"$orphan_file"
pgrep -f "$FLOW_BINARY" >>"$orphan_file" 2>/dev/null || true
pgrep -f "$PACKET_BINARY" >>"$orphan_file" 2>/dev/null || true
if [ -s "$orphan_file" ]; then
  cp "$orphan_file" "$OUTPUT/failure-orphan-processes.txt"
  echo "Isolated soak left a core harness process running" >&2
  exit 1
fi

diagnostic_manifest >"$TEMP/diagnostics-after.txt"
new_diagnostics="$TEMP/new-diagnostic-reports.txt"
comm -13 "$TEMP/diagnostics-before.txt" "$TEMP/diagnostics-after.txt" \
  >"$new_diagnostics"
if [ -s "$new_diagnostics" ]; then
  cp "$new_diagnostics" "$OUTPUT/failure-diagnostic-reports.txt"
  echo "Isolated soak generated a core crash, hang, or spin report" >&2
  exit 1
fi

"$ROOT/scripts/source_manifest.sh" >"$SOURCE_MANIFEST_AFTER"
cmp -s "$SOURCE_MANIFEST_BEFORE" "$SOURCE_MANIFEST_AFTER" || {
  echo "Source tree changed during the isolated soak" >&2
  exit 1
}
test "$(git -C "$ROOT" rev-parse HEAD)" = "$GIT_COMMIT" || {
  echo "Git commit changed during the isolated soak" >&2
  exit 1
}

END_EPOCH=$(date +%s)
END_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
FLOW_PEAK=$(awk -F'\t' '$2 == "flow" && $6 > peak {peak=$6} END {print peak+0}' "$SUMMARY")
PACKET_PEAK=$(awk -F'\t' '$2 == "packet" && $6 > peak {peak=$6} END {print peak+0}' "$SUMMARY")
FLOW_FD_PEAK=$(awk -F'\t' '$2 == "flow" && $8 > peak {peak=$8} END {print peak+0}' "$SUMMARY")
PACKET_FD_PEAK=$(awk -F'\t' '$2 == "packet" && $8 > peak {peak=$8} END {print peak+0}' "$SUMMARY")
{
  printf 'completed_utc=%s\n' "$END_UTC"
  printf 'actual_duration_seconds=%s\n' "$((END_EPOCH - START_EPOCH))"
  printf 'rounds=%s\n' "$round"
  printf 'flow_lifecycle_cycles=%s\n' "$((round * 500))"
  printf 'packet_lifecycle_cycles=%s\n' "$((round * PACKET_CYCLES))"
  printf 'flow_peak_rss_bytes=%s\n' "$FLOW_PEAK"
  printf 'packet_peak_rss_bytes=%s\n' "$PACKET_PEAK"
  printf 'flow_peak_fd_growth=%s\n' "$FLOW_FD_PEAK"
  printf 'packet_peak_fd_growth=%s\n' "$PACKET_FD_PEAK"
  printf 'new_diagnostic_reports=0\n'
  printf 'orphan_processes=0\n'
  printf 'status=passed\n'
} >"$OUTPUT/result.txt"
shasum -a 256 \
  "$OUTPUT/metadata.txt" "$OUTPUT/rounds.tsv" "$OUTPUT/result.txt" \
  >"$OUTPUT/SHA256SUMS"
printf 'Isolated soak passed: duration=%ss rounds=%s flow_cycles=%s packet_cycles=%s output=%s\n' \
  "$((END_EPOCH - START_EPOCH))" "$round" "$((round * 500))" \
  "$((round * PACKET_CYCLES))" "$OUTPUT"
