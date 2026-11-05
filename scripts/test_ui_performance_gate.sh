#!/bin/sh
# Release gate for UI responsiveness and the app's memory budget (1.5.1).
#
# 1.5.0 shipped two regressions no test caught: switching pages stalled the
# main thread for up to 0.8 s, and the app grew to 150-210 MB because rolling
# digits on once-a-second values filled the CoreGraphics glyph cache. The
# XCUITest responsiveness gate stopped its clock when SwiftUI first rendered a
# page (before AppKit laid it out) and ran against a fixture whose numbers
# never changed, so it saw neither.
#
# This gate builds the Release UI-review app with the responsiveness probe,
# runs it inside the headless Tart VM's GUI session (default: `vm:macos27`, so
# this Mac's screen, focus, and tunnel are never touched), and has the app
# switch pages on its own with live, once-a-second telemetry. Each switch is
# timed from the selection until the main thread has laid out and committed the
# page. The physical footprint (Activity Monitor's "Memory") is sampled
# throughout.
#
# usage: scripts/test_ui_performance_gate.sh /absolute/evidence-directory
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-}
VM_NAME=${AETHERROUTE_VM_NAME:-macos27}
VM_USER=${AETHERROUTE_VM_USER:-chenxu}
SSH_KEY=${AETHERROUTE_VM_SSH_KEY:-$HOME/.ssh/id_ed25519}
REMOTE=${AETHERROUTE_PERF_REMOTE:-vm:$VM_NAME}
SECONDS_PER_PROFILE=${AETHERROUTE_PERF_SECONDS:-300}
# The fixtures: "showcase" is everyday use (a dozen flows), "large" a heavy
# profile (500 nodes, 10,000 rules, 2,000 flows).
PROFILES=${AETHERROUTE_PERF_PROFILES:-showcase large}

# Budgets, set from 1.5.1 with about 20% headroom: page
# switch p95 152-153 ms and slowest 188-201 ms on both profiles; footprint
# median 67-70 MB, peak 74 MB, growth +0-2 MB. 1.5.0 measured p95 226-414 ms,
# slowest 805 ms and grew to 212 MB, so it fails every one of them. Loosen a
# budget only with the reason in CHANGELOG.md.
# Page switches, in milliseconds from selection to settled layout.
SHOWCASE_P95_MS=${AETHERROUTE_PERF_SHOWCASE_P95_MS:-180}
SHOWCASE_MAX_MS=${AETHERROUTE_PERF_SHOWCASE_MAX_MS:-300}
LARGE_P95_MS=${AETHERROUTE_PERF_LARGE_P95_MS:-180}
LARGE_MAX_MS=${AETHERROUTE_PERF_LARGE_MAX_MS:-300}
# Physical footprint of the app with its main window open, in MB.
MEMORY_MEDIAN_MB=${AETHERROUTE_PERF_MEMORY_MEDIAN_MB:-90}
MEMORY_MAX_MB=${AETHERROUTE_PERF_MEMORY_MAX_MB:-110}
# Growth between the second and the last quarter of a run, in MB. A budget
# can be met by a slow leak for five minutes; a rising tail cannot hide.
MEMORY_GROWTH_MB=${AETHERROUTE_PERF_MEMORY_GROWTH_MB:-8}

if [ -z "$OUTPUT" ]; then
  echo "usage: $0 /absolute/evidence-directory" >&2
  exit 64
fi
case "$OUTPUT" in
  /*) ;;
  *) echo "UI performance evidence path must be absolute" >&2; exit 64 ;;
esac
if [ -e "$OUTPUT" ]; then
  echo "Refusing to overwrite UI performance evidence: $OUTPUT" >&2
  exit 1
fi
for value in "$SECONDS_PER_PROFILE" "$SHOWCASE_P95_MS" "$SHOWCASE_MAX_MS" \
  "$LARGE_P95_MS" "$LARGE_MAX_MS" "$MEMORY_MEDIAN_MB" "$MEMORY_MAX_MB" \
  "$MEMORY_GROWTH_MB"; do
  case "$value" in
    ''|*[!0-9]*) echo "UI performance budgets must be whole numbers" >&2; exit 64 ;;
  esac
done
for profile in $PROFILES; do
  case "$profile" in
    showcase|large) ;;
    *) echo "AETHERROUTE_PERF_PROFILES accepts showcase and large" >&2; exit 64 ;;
  esac
done
for command in python3 rsync ssh; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "UI performance gate requires $command" >&2
    exit 1
  }
done

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
if [ -f "$SSH_KEY" ]; then
  SSH_OPTS="$SSH_OPTS -o IdentitiesOnly=yes -i $SSH_KEY"
fi
SSH="ssh $SSH_OPTS"
SCP="scp -q $SSH_OPTS"
# The probe writes only under an isolated HOME named like the UI test homes.
REMOTE_DIR=/tmp/aetherroute-ui-tests.performance
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-ui-performance.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

case "$REMOTE" in
  vm|vm:*)
    TARGET_VM=${REMOTE#vm:}
    [ "$TARGET_VM" != vm ] || TARGET_VM=$VM_NAME
    state=$(tart list 2>/dev/null | awk -v v="$TARGET_VM" '$2 == v {print $NF}')
    test -n "$state" || { echo "UI performance gate: unknown Tart VM $TARGET_VM" >&2; exit 1; }
    if [ "$state" != running ]; then
      nohup tart run "$TARGET_VM" --no-graphics >/dev/null 2>&1 &
    fi
    vm_ip=""
    for _ in $(seq 1 30); do
      vm_ip=$(tart ip "$TARGET_VM" 2>/dev/null || true)
      if [ -n "$vm_ip" ] && $SSH "$VM_USER@$vm_ip" true 2>/dev/null; then
        break
      fi
      vm_ip=""
      sleep 2
    done
    test -n "$vm_ip" || { echo "UI performance gate cannot reach Tart VM $TARGET_VM" >&2; exit 1; }
    REMOTE="$VM_USER@$vm_ip"
    ;;
esac

$SSH "$REMOTE" 'pgrep -x Dock >/dev/null' || {
  echo "UI performance gate cannot reach a logged-in GUI session on $REMOTE" >&2
  exit 1
}
mkdir -p "$OUTPUT"
"$ROOT/scripts/source_manifest.sh" >"$OUTPUT/source-manifest.txt"

echo "==> Building the Release review app with the responsiveness probe"
if ! AETHERROUTE_UI_TEST_CONFIGURATION=Release \
  AETHERROUTE_RUN_UI_RESPONSIVENESS=YES \
  AETHERROUTE_UI_TEST_EXPORT_PRODUCTS="$TEMP/products" \
  "$ROOT/scripts/test_ui.sh" >"$OUTPUT/build.log" 2>&1; then
  tail -40 "$OUTPUT/build.log" >&2
  echo "UI performance gate could not build the review app" >&2
  exit 1
fi
APP=$(find "$TEMP/products" -maxdepth 4 -name AetherRoute.app -type d | head -1)
[ -n "$APP" ] || { echo "The export has no AetherRoute.app" >&2; exit 1; }

echo "==> Packaging review app for transfer to $REMOTE"
APP_ZIP="$TEMP/AetherRouteReview.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
$SSH "$REMOTE" "pkill -f '$REMOTE_DIR' 2>/dev/null; find '$REMOTE_DIR' -depth -delete 2>/dev/null; mkdir -p '$REMOTE_DIR'"
$SCP "$APP_ZIP" "$REMOTE:$REMOTE_DIR/app.zip"
$SSH "$REMOTE" "ditto -x -k '$REMOTE_DIR/app.zip' '$REMOTE_DIR/' && rm -f '$REMOTE_DIR/app.zip'"

run_profile() {
  profile=$1
  evidence="$OUTPUT/$profile"
  mkdir -p "$evidence"
  echo "==> $profile: switching pages for $SECONDS_PER_PROFILE s on $REMOTE"
  $SSH "$REMOTE" "pkill -f '$REMOTE_DIR/AetherRoute.app' 2>/dev/null; find '$REMOTE_DIR/Home' -depth -delete 2>/dev/null; rm -f '$REMOTE_DIR/footprint.txt' '$REMOTE_DIR/app.log'; mkdir -p '$REMOTE_DIR/Home/tmp'"
  # `open` starts the app in the logged-in GUI session; cfprefsd ignores
  # HOME, so the review bundle's defaults are cleared before and after.
  $SSH "$REMOTE" "defaults delete com.aetherroute.desktop.ui-review >/dev/null 2>&1; \
    defaults write com.aetherroute.desktop.ui-review SUEnableAutomaticChecks -bool NO; \
    defaults write com.aetherroute.desktop.ui-review AetherRouteMenuBarTrafficEnabled -bool YES; \
    open -n -F --stdout '$REMOTE_DIR/app.log' --stderr '$REMOTE_DIR/app.log' \
      --env HOME='$REMOTE_DIR/Home' --env CFFIXED_USER_HOME='$REMOTE_DIR/Home' \
      --env TMPDIR='$REMOTE_DIR/Home/tmp' \
      --env AETHERROUTE_UI_TEST_ISOLATED_HOME='$REMOTE_DIR/Home' \
      --env AETHERROUTE_UI_RESPONSIVENESS_APP_OUTPUT='$REMOTE_DIR/Home/samples.csv' \
      --env AETHERROUTE_UI_RESPONSIVENESS_AUTOCYCLE_SECONDS='$SECONDS_PER_PROFILE' \
      --env AETHERROUTE_UI_REVIEW=connected --env AETHERROUTE_UI_REVIEW_PROFILE='$profile' \
      --env AETHERROUTE_UI_REVIEW_LIVE=1 \
      --env AETHERROUTE_UI_REVIEW_LANGUAGE=zh-Hans --env AETHERROUTE_UI_REVIEW_APPEARANCE=light \
      --env AETHERROUTE_UI_REVIEW_WINDOW=1050x700 --env AETHERROUTE_UI_REVIEW_SETTINGS_TAB=- \
      '$REMOTE_DIR/AetherRoute.app' --args -ApplePersistenceIgnoreState YES; \
    sleep 6; python3 -c \"
import ctypes, os, subprocess, time
l = ctypes.CDLL('/usr/lib/libproc.dylib')
b = (ctypes.c_uint64 * 64)()
out = subprocess.run(['pgrep', '-f', '$REMOTE_DIR/AetherRoute.app/Contents/MacOS/AetherRoute'], capture_output=True, text=True).stdout.split()
pid = int(out[0]) if out else 0
waited, limit = 0, $SECONDS_PER_PROFILE + 90
while pid > 0:
    try:
        os.kill(pid, 0)
    except OSError:
        break
    if l.proc_pid_rusage(pid, 4, ctypes.byref(b)) == 0:
        with open('$REMOTE_DIR/footprint.txt', 'a') as f:
            f.write(f'{round(b[9] / 1048576)}\\n')
    time.sleep(5)
    waited += 5
    if waited > limit:
        try: os.kill(pid, 9)
        except OSError: pass
        with open('$REMOTE_DIR/app.log', 'a') as f:
            f.write('timed out\\n')
        break
\"; true"
  rsync -a -e "$SSH" "$REMOTE:$REMOTE_DIR/Home/samples.csv" \
    "$REMOTE:$REMOTE_DIR/footprint.txt" "$REMOTE:$REMOTE_DIR/app.log" \
    "$evidence/" 2>/dev/null || true
  $SSH "$REMOTE" "find '$REMOTE_DIR/Home' -depth -delete 2>/dev/null; rm -f '$REMOTE_DIR/footprint.txt' '$REMOTE_DIR/app.log'; defaults delete com.aetherroute.desktop.ui-review >/dev/null 2>&1; true"
}

for profile in $PROFILES; do
  run_profile "$profile"
done

$SSH "$REMOTE" "pkill -f '$REMOTE_DIR/AetherRoute.app' 2>/dev/null; find '$REMOTE_DIR' -depth -delete 2>/dev/null; true"

python3 -I - "$OUTPUT" "$PROFILES" \
  "$SHOWCASE_P95_MS" "$SHOWCASE_MAX_MS" "$LARGE_P95_MS" "$LARGE_MAX_MS" \
  "$MEMORY_MEDIAN_MB" "$MEMORY_MAX_MB" "$MEMORY_GROWTH_MB" <<'PY'
import csv, statistics, sys

output, profiles = sys.argv[1], sys.argv[2].split()
budgets = {
    "showcase": (float(sys.argv[3]), float(sys.argv[4])),
    "large": (float(sys.argv[5]), float(sys.argv[6])),
}
memory_median, memory_max, memory_growth = map(float, sys.argv[7:10])
lines, failures = [], []

def percentile(values, fraction):
    values = sorted(values)
    index = max(0, -(-len(values) * fraction // 1) - 1)
    return values[min(len(values) - 1, int(index))]

for profile in profiles:
    evidence = f"{output}/{profile}"
    try:
        rows = list(csv.DictReader(open(f"{evidence}/samples.csv")))
    except OSError:
        failures.append(f"{profile}: the app recorded no page switches")
        continue
    by_page = {}
    for row in rows:
        by_page.setdefault(row["action"], []).append(float(row["duration_ms"]))
    all_values = [v for values in by_page.values() for v in values]
    if len(by_page) < 6 or min(len(v) for v in by_page.values()) < 5:
        failures.append(f"{profile}: too few switches per page ({len(all_values)} in all)")
    p95_budget, max_budget = budgets[profile]
    lines.append(f"[{profile}] page              n     p50     p95     max")
    for page in sorted(by_page):
        values = by_page[page]
        lines.append(f"[{profile}] {page:16s} {len(values):3d} {statistics.median(values):7.1f} "
                     f"{percentile(values, .95):7.1f} {max(values):7.1f}")
    p95, worst = percentile(all_values, .95), max(all_values)
    lines.append(f"[{profile}] all              {len(all_values):3d} {statistics.median(all_values):7.1f} "
                 f"{p95:7.1f} {worst:7.1f}   budget p95<={p95_budget:.0f} max<={max_budget:.0f}")
    if p95 > p95_budget:
        failures.append(f"{profile}: page switch p95 {p95:.0f} ms exceeds {p95_budget:.0f} ms")
    if worst > max_budget:
        failures.append(f"{profile}: slowest page switch {worst:.0f} ms exceeds {max_budget:.0f} ms")
    try:
        footprint = [float(x) for x in open(f"{evidence}/footprint.txt").read().split()]
    except OSError:
        footprint = []
    if len(footprint) < 8:
        failures.append(f"{profile}: too few footprint samples ({len(footprint)})")
        continue
    quarter = len(footprint) // 4
    growth = statistics.median(footprint[-quarter:]) - statistics.median(footprint[quarter:2 * quarter])
    median = statistics.median(footprint)
    lines.append(f"[{profile}] footprint MB: median {median:.0f} max {max(footprint):.0f} "
                 f"growth {growth:+.0f}   budget median<={memory_median:.0f} max<={memory_max:.0f} "
                 f"growth<={memory_growth:.0f}")
    if median > memory_median:
        failures.append(f"{profile}: median footprint {median:.0f} MB exceeds {memory_median:.0f} MB")
    if max(footprint) > memory_max:
        failures.append(f"{profile}: peak footprint {max(footprint):.0f} MB exceeds {memory_max:.0f} MB")
    if growth > memory_growth:
        failures.append(f"{profile}: footprint grew {growth:.0f} MB over the run (limit {memory_growth:.0f} MB)")

status = "passed" if not failures else "failed"
report = "\n".join(lines + [f"status={status}"] + [f"failure={f}" for f in failures]) + "\n"
open(f"{output}/result.txt", "w").write(report)
sys.stdout.write(report)
sys.exit(0 if not failures else 1)
PY
