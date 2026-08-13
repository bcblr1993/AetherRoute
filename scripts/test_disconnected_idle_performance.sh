#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SIGNING_IDENTITY=$(
  "$ROOT/scripts/resolve_development_signing_identity.sh"
)
TEMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
LOCK_DIRECTORY="$TEMP_BASE/aetherroute-ui-tests.lock"
if ! mkdir "$LOCK_DIRECTORY" 2>/dev/null; then
  echo "Another isolated AetherRoute UI session is already running." >&2
  exit 75
fi
TEMP=$(mktemp -d "$TEMP_BASE/aetherroute-idle-performance.XXXXXX") || {
  rmdir "$LOCK_DIRECTORY" 2>/dev/null || true
  exit 1
}
CURRENT_PID=
TRACE_PID=
BUILD_PID=
cleanup() {
  if [ -n "$BUILD_PID" ] && kill -0 "$BUILD_PID" 2>/dev/null; then
    kill -TERM "$BUILD_PID" 2>/dev/null || true
    wait "$BUILD_PID" 2>/dev/null || true
  fi
  if [ -n "$TRACE_PID" ] && kill -0 "$TRACE_PID" 2>/dev/null; then
    kill -TERM "$TRACE_PID" 2>/dev/null || true
    wait "$TRACE_PID" 2>/dev/null || true
  fi
  if [ -n "$CURRENT_PID" ] && kill -0 "$CURRENT_PID" 2>/dev/null; then
    kill -TERM "$CURRENT_PID" 2>/dev/null || true
    wait "$CURRENT_PID" 2>/dev/null || true
  fi
  PERFORMANCE_APP="$TEMP/DerivedData/Build/Products/Release/AetherRoute.app"
  if [ -d "$PERFORMANCE_APP" ]; then
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
      -u "$PERFORMANCE_APP" >/dev/null 2>&1 || true
  fi
  if [ -d /Applications/AetherRoute.app ]; then
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
      -f /Applications/AetherRoute.app >/dev/null 2>&1 || true
  fi
  find "$TEMP" -depth -delete 2>/dev/null || true
  rmdir "$LOCK_DIRECTORY" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

REQUESTED_OUTPUT=${1:-}
if [ -n "$REQUESTED_OUTPUT" ]; then
  case "$REQUESTED_OUTPUT" in
    /*) OUTPUT=$REQUESTED_OUTPUT ;;
    *) echo "Idle performance output path must be absolute" >&2; exit 64 ;;
  esac
  if [ -e "$OUTPUT" ]; then
    echo "Refusing to overwrite idle performance output: $OUTPUT" >&2
    exit 1
  fi
else
  OUTPUT="$TEMP/output"
fi

if [ "$(uname -m)" != arm64 ]; then
  echo "Disconnected idle performance gate requires Apple silicon" >&2
  exit 1
fi
for command in awk codesign file lsof ps sample shasum sort sw_vers xcodebuild xcrun; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Disconnected idle performance gate requires $command" >&2
    exit 1
  }
done

PROFILER=xctrace
if [ "${AETHERROUTE_IDLE_USE_SAMPLE:-NO}" = YES ]; then
  PROFILER=sample
else
  DEVELOPER_TOOLS_STATUS=$(
    /usr/sbin/DevToolsSecurity -status 2>&1 || true
  )
  if ! printf '%s\n' "$DEVELOPER_TOOLS_STATUS" \
    | grep -Fq 'Developer mode is currently enabled.'; then
    echo "Xcode automation authorization is required to finalize xctrace evidence." >&2
    echo "Enable Developer Tools Security once, then rerun:" >&2
    echo "  sudo /usr/sbin/DevToolsSecurity -enable" >&2
    exit 77
  fi
fi

WARMUP_SECONDS=${AETHERROUTE_IDLE_WARMUP_SECONDS:-300}
SAMPLE_SECONDS=${AETHERROUTE_IDLE_SAMPLE_SECONDS:-600}
SAMPLE_INTERVAL_SECONDS=${AETHERROUTE_IDLE_SAMPLE_INTERVAL_SECONDS:-1}
STATUS=passed
case "$WARMUP_SECONDS:$SAMPLE_SECONDS:$SAMPLE_INTERVAL_SECONDS" in
  *[!0-9:]*|*::*|:*)
    echo "Idle measurement durations must be positive integers" >&2
    exit 64
    ;;
esac
if [ "$WARMUP_SECONDS" -le 0 ] || [ "$SAMPLE_SECONDS" -le 0 ] || \
   [ "$SAMPLE_INTERVAL_SECONDS" -le 0 ]; then
  echo "Idle measurement durations must be positive integers" >&2
  exit 64
fi
if [ "$WARMUP_SECONDS" -lt 300 ] || [ "$SAMPLE_SECONDS" -lt 600 ]; then
  if [ "${AETHERROUTE_IDLE_SMOKE:-NO}" != YES ]; then
    echo "Short idle measurements require AETHERROUTE_IDLE_SMOKE=YES" >&2
    exit 64
  fi
  STATUS=smoke
fi
if [ "$STATUS" = passed ] && [ "$PROFILER" = sample ]; then
  STATUS=provisional
fi

mkdir -p "$OUTPUT" "$TEMP/Home/tmp" "$TEMP/Run"
"$ROOT/scripts/source_manifest.sh" >"$OUTPUT/source-manifest.txt"
"$ROOT/scripts/bootstrap.sh"
xcodebuild \
  -project "$ROOT/AetherRoute.xcodeproj" \
  -scheme AetherRoute \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$TEMP/DerivedData" \
  AETHERROUTE_ALLOW_ISOLATED_RELEASE_TEST_BUILD=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_ENTITLEMENTS= \
  "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY" \
  AD_HOC_CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) AETHERROUTE_INDEPENDENT AETHERROUTE_PERFORMANCE_MEASUREMENT' \
  build >"$OUTPUT/build.log" 2>&1 &
BUILD_PID=$!
while kill -0 "$BUILD_PID" 2>/dev/null; do
  sleep 10
  if kill -0 "$BUILD_PID" 2>/dev/null; then
    echo "idle performance build heartbeat"
  fi
done
set +e
wait "$BUILD_PID"
build_status=$?
set -e
BUILD_PID=
if [ "$build_status" -ne 0 ]; then
  tail -160 "$OUTPUT/build.log" >&2
  exit 1
fi

APP="$TEMP/DerivedData/Build/Products/Release/AetherRoute.app"
EXECUTABLE="$APP/Contents/MacOS/AetherRoute"
test -x "$EXECUTABLE"
file "$EXECUTABLE" | grep -q 'arm64'
codesign --verify --deep --strict "$APP" >>"$OUTPUT/build.log" 2>&1
codesign -dv --verbose=4 "$APP" 2>&1 \
  | grep -Fq 'Authority=Apple Development:'
APP_SHA256=$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')
RUNNER_SHA256=$(shasum -a 256 "$ROOT/scripts/test_disconnected_idle_performance.sh" | awk '{print $1}')
VERIFIER_SHA256=$(shasum -a 256 "$ROOT/scripts/verify_disconnected_idle_performance_result.sh" | awk '{print $1}')
SOURCE_MANIFEST_SHA256=$(awk '$1 == "MANIFEST_SHA256" {print $2}' "$OUTPUT/source-manifest.txt")
test -n "$SOURCE_MANIFEST_SHA256"
scutil --proxy >"$OUTPUT/system-proxy-before.txt"

percentile() {
  file_path=$1
  column=$2
  percentile_value=$3
  awk -F, -v column="$column" 'NR > 1 {print $column}' "$file_path" \
    | sort -n \
    | awk -v percentile_value="$percentile_value" '
        { values[NR] = $1 }
        END {
          if (NR == 0) exit 1
          position = int((NR * percentile_value) + 0.999999)
          if (position < 1) position = 1
          if (position > NR) position = NR
          printf "%.3f\n", values[position]
        }
      '
}

maximum() {
  file_path=$1
  column=$2
  awk -F, -v column="$column" '
    NR > 1 && ($column + 0) > maximum { maximum = $column + 0 }
    END { if (NR <= 1) exit 1; printf "%.0f\n", maximum }
  ' "$file_path"
}

wait_with_heartbeat() {
  heartbeat_phase=$1
  heartbeat_duration=$2
  started=$(date +%s)
  deadline=$((started + heartbeat_duration))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    now=$(date +%s)
    remaining=$((deadline - now))
    interval=10
    if [ "$remaining" -lt "$interval" ]; then
      interval=$remaining
    fi
    sleep "$interval"
    elapsed=$(($(date +%s) - started))
    echo "idle performance heartbeat: phase=$heartbeat_phase elapsed_seconds=$elapsed"
  done
}

record_phase() {
  phase=$1
  surface=$2
  phase_home="$TEMP/Home/$phase"
  phase_tmp="$phase_home/tmp"
  csv="$OUTPUT/$phase-samples.csv"
  trace="$OUTPUT/$phase.trace"
  profiler_log="$OUTPUT/$phase-profiler.log"
  app_log="$OUTPUT/$phase-app.log"
  network_log="$OUTPUT/$phase-network-sockets.txt"
  mkdir -p "$phase_tmp"

  (
    cd "$TEMP/Run"
    exec env \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      HOME="$phase_home" \
      CFFIXED_USER_HOME="$phase_home" \
      TMPDIR="$phase_tmp" \
      AETHERROUTE_PERFORMANCE_MEASUREMENT=1 \
      AETHERROUTE_PERFORMANCE_MEASUREMENT_SURFACE="$surface" \
      "$EXECUTABLE" \
        -AppleLanguages '(en)' \
        -AppleLocale en_US \
        -ApplePersistenceIgnoreState YES \
        -NSQuitAlwaysKeepsWindows NO \
        >"$app_log" 2>&1
  ) &
  CURRENT_PID=$!

  attempts=0
  while [ "$attempts" -lt 100 ]; do
    if kill -0 "$CURRENT_PID" 2>/dev/null; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  kill -0 "$CURRENT_PID" 2>/dev/null || {
    echo "AetherRoute exited before $phase idle measurement" >&2
    exit 1
  }

  wait_with_heartbeat "$phase-warmup" "$WARMUP_SECONDS"
  if lsof -nP -a -p "$CURRENT_PID" -i >"$network_log" 2>&1; then
    echo "AetherRoute opened a network socket during isolated $phase idle measurement" >&2
    exit 1
  fi
  : >"$network_log"

  if [ "$PROFILER" = xctrace ]; then
    xcrun xctrace record \
      --template 'Time Profiler' \
      --attach "$CURRENT_PID" \
      --time-limit "${SAMPLE_SECONDS}s" \
      --output "$trace" \
      --no-prompt >"$profiler_log" 2>&1 &
  else
    sample "$CURRENT_PID" "$SAMPLE_SECONDS" 1 \
      -file "$OUTPUT/$phase.sample.txt" >"$profiler_log" 2>&1 &
  fi
  TRACE_PID=$!

  printf 'elapsed_seconds,cpu_percent,rss_bytes\n' >"$csv"
  started=$(date +%s)
  deadline=$((started + SAMPLE_SECONDS))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    kill -0 "$CURRENT_PID" 2>/dev/null || {
      echo "AetherRoute exited during $phase idle measurement" >&2
      exit 1
    }
    sample=$(ps -p "$CURRENT_PID" -o %cpu= -o rss= | awk 'NF == 2 {print $1 "," ($2 * 1024)}')
    test -n "$sample"
    now=$(date +%s)
    elapsed=$((now - started))
    printf '%s,%s\n' "$elapsed" "$sample" >>"$csv"
    if [ $((elapsed % 20)) -eq 0 ]; then
      echo "idle performance heartbeat: phase=$phase-sample elapsed_seconds=$elapsed"
    fi
    sleep "$SAMPLE_INTERVAL_SECONDS"
  done
  wait "$TRACE_PID"
  TRACE_PID=
  if [ "$PROFILER" = xctrace ]; then
    test -d "$trace"
    test -n "$(find "$trace" -type f -print -quit)"
  else
    test -s "$OUTPUT/$phase.sample.txt"
  fi

  if lsof -nP -a -p "$CURRENT_PID" -i >>"$network_log" 2>&1; then
    echo "AetherRoute opened a network socket during isolated $phase idle measurement" >&2
    exit 1
  fi
  kill -TERM "$CURRENT_PID" 2>/dev/null || true
  wait "$CURRENT_PID" 2>/dev/null || true
  CURRENT_PID=

  percentile "$csv" 2 0.50 >"$OUTPUT/$phase-cpu-median.txt"
  percentile "$csv" 2 0.95 >"$OUTPUT/$phase-cpu-p95.txt"
  maximum "$csv" 3 >"$OUTPUT/$phase-rss-maximum.txt"
  if [ "$PROFILER" = xctrace ]; then
    find "$trace" -type f -print | LC_ALL=C sort | while IFS= read -r trace_file; do
      relative_path=${trace_file#"$OUTPUT/"}
      shasum -a 256 "$trace_file" | awk -v relative_path="$relative_path" \
        '{print $1 "  " relative_path}'
    done >"$OUTPUT/$phase-trace-manifest.txt"
  fi
}

record_phase window-open window
record_phase menu-bar-only menu-bar
scutil --proxy >"$OUTPUT/system-proxy-after.txt"
cmp -s "$OUTPUT/system-proxy-before.txt" "$OUTPUT/system-proxy-after.txt" || {
  echo "System proxy state changed during idle measurement" >&2
  exit 1
}
"$ROOT/scripts/source_manifest.sh" >"$TEMP/source-manifest-after.txt"
cmp -s "$OUTPUT/source-manifest.txt" "$TEMP/source-manifest-after.txt" || {
  echo "Source tree changed during disconnected idle measurement" >&2
  exit 1
}

window_cpu_median=$(cat "$OUTPUT/window-open-cpu-median.txt")
window_cpu_p95=$(cat "$OUTPUT/window-open-cpu-p95.txt")
window_rss_max=$(cat "$OUTPUT/window-open-rss-maximum.txt")
menu_cpu_median=$(cat "$OUTPUT/menu-bar-only-cpu-median.txt")
menu_cpu_p95=$(cat "$OUTPUT/menu-bar-only-cpu-p95.txt")
menu_rss_max=$(cat "$OUTPUT/menu-bar-only-rss-maximum.txt")

if [ "$STATUS" = passed ]; then
  for metric in "$window_cpu_median" "$menu_cpu_median"; do
    awk -v value="$metric" 'BEGIN { exit !(value + 0 <= 0.5) }' || {
      echo "Disconnected idle median CPU exceeds 0.5%: $metric" >&2
      exit 1
    }
  done
  for metric in "$window_cpu_p95" "$menu_cpu_p95"; do
    awk -v value="$metric" 'BEGIN { exit !(value + 0 <= 1.5) }' || {
      echo "Disconnected idle p95 CPU exceeds 1.5%: $metric" >&2
      exit 1
    }
  done
  for metric in "$window_rss_max" "$menu_rss_max"; do
    awk -v value="$metric" 'BEGIN { exit !(value + 0 <= 134217728) }' || {
      echo "Disconnected idle RSS exceeds 128 MiB: $metric" >&2
      exit 1
    }
  done
fi

{
  printf 'schema=1\n'
  printf 'completed_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'machine=%s\n' "$(uname -m)"
  printf 'os=%s\n' "$(sw_vers -productVersion)"
  printf 'configuration=Release\n'
  printf 'measurement_fixture=AETHERROUTE_PERFORMANCE_MEASUREMENT\n'
  printf 'profiler=%s\n' "$PROFILER"
  printf 'warmup_seconds=%s\n' "$WARMUP_SECONDS"
  printf 'sample_seconds=%s\n' "$SAMPLE_SECONDS"
  printf 'sample_interval_seconds=%s\n' "$SAMPLE_INTERVAL_SECONDS"
  printf 'maximum_median_cpu_percent=0.5\n'
  printf 'maximum_p95_cpu_percent=1.5\n'
  printf 'maximum_rss_bytes=134217728\n'
  printf 'window_open_cpu_median_percent=%s\n' "$window_cpu_median"
  printf 'window_open_cpu_p95_percent=%s\n' "$window_cpu_p95"
  printf 'window_open_max_rss_bytes=%s\n' "$window_rss_max"
  printf 'menu_bar_only_cpu_median_percent=%s\n' "$menu_cpu_median"
  printf 'menu_bar_only_cpu_p95_percent=%s\n' "$menu_cpu_p95"
  printf 'menu_bar_only_max_rss_bytes=%s\n' "$menu_rss_max"
  printf 'app_executable_sha256=%s\n' "$APP_SHA256"
  printf 'runner_sha256=%s\n' "$RUNNER_SHA256"
  printf 'verifier_sha256=%s\n' "$VERIFIER_SHA256"
  printf 'source_manifest_sha256=%s\n' "$SOURCE_MANIFEST_SHA256"
  printf 'network_extension=disabled\n'
  printf 'network_sockets=none\n'
  printf 'system_proxy_state=unchanged\n'
  printf 'status=%s\n' "$STATUS"
} >"$OUTPUT/result.txt"

(
  cd "$OUTPUT"
  shasum -a 256 \
    build.log \
    window-open-app.log window-open-profiler.log window-open-samples.csv \
    window-open-network-sockets.txt \
    menu-bar-only-app.log menu-bar-only-profiler.log menu-bar-only-samples.csv \
    menu-bar-only-network-sockets.txt \
    system-proxy-before.txt system-proxy-after.txt source-manifest.txt \
    result.txt >SHA256SUMS
  if [ "$PROFILER" = xctrace ]; then
    shasum -a 256 \
      window-open-trace-manifest.txt menu-bar-only-trace-manifest.txt \
      >>SHA256SUMS
  else
    shasum -a 256 window-open.sample.txt menu-bar-only.sample.txt \
      >>SHA256SUMS
  fi
)

if [ "$STATUS" = smoke ]; then
  "$ROOT/scripts/verify_disconnected_idle_performance_result.sh" --smoke "$OUTPUT"
elif [ "$STATUS" = provisional ]; then
  "$ROOT/scripts/verify_disconnected_idle_performance_result.sh" --provisional "$OUTPUT"
else
  "$ROOT/scripts/verify_disconnected_idle_performance_result.sh" "$OUTPUT"
fi
cat "$OUTPUT/result.txt"
echo "Disconnected idle performance gate passed: output=$OUTPUT"
