#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EXPECTED_STATUS=passed
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-idle-verifier.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
if [ "${1:-}" = --smoke ]; then
  EXPECTED_STATUS=smoke
  shift
elif [ "${1:-}" = --provisional ]; then
  EXPECTED_STATUS=provisional
  shift
fi
OUTPUT=${1:-}
if [ -z "$OUTPUT" ] || [ ! -d "$OUTPUT" ]; then
  echo "usage: $0 [--smoke|--provisional] /absolute/idle-performance-output" >&2
  exit 64
fi
case "$OUTPUT" in
  /*) ;;
  *) echo "Idle performance output path must be absolute" >&2; exit 64 ;;
esac

for file in \
  build.log \
  window-open-app.log window-open-profiler.log window-open-samples.csv \
  window-open-network-sockets.txt \
  menu-bar-only-app.log menu-bar-only-profiler.log menu-bar-only-samples.csv \
  menu-bar-only-network-sockets.txt \
  system-proxy-before.txt system-proxy-after.txt source-manifest.txt \
  result.txt SHA256SUMS
do
  test -f "$OUTPUT/$file" || {
    echo "Missing idle performance evidence: $file" >&2
    exit 1
  }
done
(
  cd "$OUTPUT"
  shasum -a 256 -c SHA256SUMS >/dev/null
)

value() {
  key=$1
  awk -F= -v wanted="$key" \
    '$1 == wanted {print substr($0, length($1) + 2); exit}' \
    "$OUTPUT/result.txt"
}
require_equal() {
  key=$1
  expected=$2
  actual=$(value "$key")
  if [ "$actual" != "$expected" ]; then
    echo "Invalid idle performance $key: expected $expected, got $actual" >&2
    exit 1
  fi
}
require_number_at_most() {
  key=$1
  maximum=$2
  actual=$(value "$key")
  awk -v actual="$actual" -v maximum="$maximum" \
    'BEGIN { exit !(actual ~ /^[0-9]+([.][0-9]+)?$/ && actual + 0 <= maximum + 0) }' || {
      echo "Idle performance $key above $maximum: $actual" >&2
      exit 1
    }
}
require_number_at_least() {
  key=$1
  minimum=$2
  actual=$(value "$key")
  awk -v actual="$actual" -v minimum="$minimum" \
    'BEGIN { exit !(actual ~ /^[0-9]+$/ && actual + 0 >= minimum + 0) }' || {
      echo "Idle performance $key below $minimum: $actual" >&2
      exit 1
    }
}

require_equal schema 1
require_equal machine arm64
require_equal configuration Release
require_equal measurement_fixture AETHERROUTE_PERFORMANCE_MEASUREMENT
require_equal maximum_median_cpu_percent 0.5
require_equal maximum_p95_cpu_percent 1.5
require_equal maximum_rss_bytes 134217728
require_equal network_extension disabled
require_equal network_sockets none
require_equal system_proxy_state unchanged
require_equal status "$EXPECTED_STATUS"
require_number_at_least sample_interval_seconds 1
cmp -s "$OUTPUT/system-proxy-before.txt" "$OUTPUT/system-proxy-after.txt"
require_equal runner_sha256 \
  "$(shasum -a 256 "$ROOT/scripts/test_disconnected_idle_performance.sh" | awk '{print $1}')"
require_equal verifier_sha256 \
  "$(shasum -a 256 "$ROOT/scripts/verify_disconnected_idle_performance_result.sh" | awk '{print $1}')"
require_equal source_manifest_sha256 \
  "$(awk '$1 == "MANIFEST_SHA256" {print $2}' "$OUTPUT/source-manifest.txt")"
"$ROOT/scripts/source_manifest.sh" >"$TEMP/current-source-manifest.txt"
cmp -s "$OUTPUT/source-manifest.txt" "$TEMP/current-source-manifest.txt" || {
  echo "Idle performance evidence does not match the current source tree" >&2
  exit 1
}

profiler=$(value profiler)
case "$profiler" in
  xctrace)
    for trace in window-open.trace menu-bar-only.trace; do
      test -d "$OUTPUT/$trace" || {
        echo "Missing idle performance trace: $trace" >&2
        exit 1
      }
      test -n "$(find "$OUTPUT/$trace" -type f -print -quit)" || {
        echo "Empty idle performance trace: $trace" >&2
        exit 1
      }
    done
    (
      cd "$OUTPUT"
      shasum -a 256 -c window-open-trace-manifest.txt >/dev/null
      shasum -a 256 -c menu-bar-only-trace-manifest.txt >/dev/null
    )
    for phase in window-open menu-bar-only; do
      profiler_log="$OUTPUT/$phase-profiler.log"
      if grep -F 'Run Completed' "$profiler_log" >/dev/null; then
        continue
      fi
      grep -F 'Recording completed. Saving output file...' \
        "$profiler_log" >/dev/null
      grep -F "Output file saved as: $phase.trace" \
        "$profiler_log" >/dev/null
    done
    ;;
  sample)
    test "$EXPECTED_STATUS" != passed || {
      echo "macOS sample evidence cannot satisfy the final xctrace gate" >&2
      exit 1
    }
    test -s "$OUTPUT/window-open.sample.txt"
    test -s "$OUTPUT/menu-bar-only.sample.txt"
    grep -F 'Sampling process' "$OUTPUT/window-open-profiler.log" >/dev/null
    grep -F 'Sampling process' "$OUTPUT/menu-bar-only-profiler.log" >/dev/null
    ;;
  *)
    echo "Unsupported idle profiler: $profiler" >&2
    exit 1
    ;;
esac

if [ "$EXPECTED_STATUS" != smoke ]; then
  require_number_at_least warmup_seconds 300
  require_number_at_least sample_seconds 600
  require_number_at_most window_open_cpu_median_percent 0.5
  require_number_at_most window_open_cpu_p95_percent 1.5
  require_number_at_most window_open_max_rss_bytes 134217728
  require_number_at_most menu_bar_only_cpu_median_percent 0.5
  require_number_at_most menu_bar_only_cpu_p95_percent 1.5
  require_number_at_most menu_bar_only_max_rss_bytes 134217728
fi

test -n "$(value app_executable_sha256)"
grep -F 'AETHERROUTE_PERFORMANCE_MEASUREMENT' "$OUTPUT/build.log" >/dev/null

echo "Disconnected idle performance evidence verified: $OUTPUT"
