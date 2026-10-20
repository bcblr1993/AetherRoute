#!/bin/sh
set -eu

# Parallel Release Acceptance Orchestrator
#
# Concurrently drives the two heavy verification stages of AetherRoute:
# 1. Tart VM Acceptance Matrix (6-dimension engine x routing tests in isolated VM,
#    including transparent UDP, LAN bypass, raw traffic, burst concurrency, SNI recovery,
#    idle keep-alive reuse, and large upload checks).
# 2. Remote Physical Mac mini Gate (source tree integrity & zero network mutation verification)
#    followed by UI Performance & Memory Budget Gate in live GUI session.
#
# Both tracks run concurrently on separate target machines, slashing the total
# qualification time without lowering any quality gates or mutating the host.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=${1:-}
BUILD_NUMBER=${2:-}
OUTPUT_DIR=${3:-}
SIGNING_CONFIG=${AETHERROUTE_SIGNING_CONFIG:-"$ROOT/Config/Signing.json"}
VM_NAME=${AETHERROUTE_VM_NAME:-macos27}
REMOTE_HOST=${AETHERROUTE_REMOTE_HOST:-chenxu@100.64.0.3}
PERF_SECONDS=${AETHERROUTE_PERF_SECONDS:-300}
export AETHERROUTE_IDLE_REUSE_HOST=${AETHERROUTE_IDLE_REUSE_HOST:-httpbin.org}

# Reject diagnostic shortcuts before any build, SSH, or VM operation. They
# remain available on the individual diagnostic scripts, not this release gate.
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/verify_parallel_acceptance.py" settings

usage() {
  echo "usage: $0 [version] [build-number] [/absolute/output-directory]" >&2
  echo "  Defaults: version and build parsed from project.yml, output into outputs/acceptance-<timestamp>" >&2
  echo "  AETHERROUTE_ACCEPTANCE_CANDIDATE_ZIP=/abs/candidate.zip reuses that archive instead of building." >&2
}

if [ -z "$VERSION" ]; then
  VERSION=$(grep -m1 'MARKETING_VERSION:' "$ROOT/project.yml" | awk -F'"' '{print $2}')
fi
if [ -z "$BUILD_NUMBER" ]; then
  BUILD_NUMBER=$(grep -m1 'CURRENT_PROJECT_VERSION:' "$ROOT/project.yml" | awk -F'"' '{print $2}')
fi

if [ -z "$OUTPUT_DIR" ]; then
  STAMP=$(date '+%Y%m%d-%H%M%S')
  OUTPUT_DIR="$ROOT/outputs/acceptance-$VERSION-$BUILD_NUMBER-$STAMP"
fi

case "$OUTPUT_DIR" in
  /*) ;;
  *) OUTPUT_DIR="$ROOT/$OUTPUT_DIR" ;;
esac

# Physical evidence is bound to the candidate's SHA-256 and every build re-signs
# with a new timestamp, so evidence is only ever satisfiable for a reused archive.
# Validate it before any build, SSH, or VM operation.
REUSED_CANDIDATE_ZIP=${AETHERROUTE_ACCEPTANCE_CANDIDATE_ZIP:-}
if [ -n "$REUSED_CANDIDATE_ZIP" ]; then
  PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/verify_parallel_acceptance.py" candidate \
    "$REUSED_CANDIDATE_ZIP" "$BUILD_NUMBER"
fi
# Outside the per-run directory so a rerun with the reused candidate finds it.
PHYSICAL_EVIDENCE=${AETHERROUTE_PHYSICAL_RUNTIME_EVIDENCE:-"$ROOT/outputs/physical-runtime-$VERSION-$BUILD_NUMBER"}

if [ -e "$OUTPUT_DIR" ]; then
  echo "Refusing to overwrite existing output directory: $OUTPUT_DIR" >&2
  exit 1
fi
mkdir -p "$OUTPUT_DIR"

LOG_MAIN="$OUTPUT_DIR/orchestrator.log"
: >"$LOG_MAIN"

log() {
  printf '%s\n' "$*" | tee -a "$LOG_MAIN"
}

log "================================================================================"
log " AetherRoute Parallel Release Acceptance"
log " Version: $VERSION (Build $BUILD_NUMBER)"
log " Output : $OUTPUT_DIR"
log " VM     : $VM_NAME"
log " Remote : $REMOTE_HOST"
log "================================================================================"

# ---------------------------------------------------------------- Preflight ---
log "[Preflight] Checking prerequisites..."
test -f "$SIGNING_CONFIG" || {
  log "Signing configuration missing: $SIGNING_CONFIG" >&2
  exit 66
}

# Verify Tart VM is available and ensure zero stale extension processes
tart list 2>/dev/null | grep -E "^local[[:space:]]+$VM_NAME[[:space:]]" >/dev/null || {
  log "Tart VM '$VM_NAME' not found in tart list" >&2
  exit 1
}

if tart list 2>/dev/null | grep -E "^local[[:space:]]+$VM_NAME[[:space:]].*running" >/dev/null; then
  log "[Preflight] Cycling Tart VM '$VM_NAME' to clear stale provider daemons..."
  tart stop "$VM_NAME" >/dev/null 2>&1 || true
  sleep 1
fi

log "[Preflight] Starting Tart VM '$VM_NAME'..."
tart run "$VM_NAME" --no-graphics >/dev/null 2>&1 &
sleep 5
vm_ip=
for i in $(seq 1 15); do
  vm_ip=$(tart ip "$VM_NAME" 2>/dev/null || true)
  [ -n "$vm_ip" ] && break
  sleep 1
done
if [ -z "$vm_ip" ]; then
  log "Tart VM '$VM_NAME' has no assigned IP after launch." >&2
  exit 1
fi
log "[Preflight] Tart VM '$VM_NAME' reachable at $vm_ip"

# Verify Remote Mac mini
ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" 'uname -m' >/dev/null 2>&1 || {
  log "Remote host '$REMOTE_HOST' unreachable via SSH" >&2
  exit 1
}
log "[Preflight] Remote host '$REMOTE_HOST' reachable via SSH"

# Verify forbidden network mutation commands in scripts
if grep -R -E -n --exclude=test_interface_switch_recovery.sh \
  '^[[:space:]]*((sudo|doas)[[:space:]]+)?((/usr/sbin/)?networksetup[[:space:]]+-(set|create|delete)|(/sbin/)?route[[:space:]]+(add|delete|change)|(/usr/sbin/)?scutil[[:space:]]+--(set|nc))' \
  "$ROOT/scripts" >/dev/null; then
  log "Forbidden system-network mutation command detected in scripts/" >&2
  exit 1
fi
log "[Preflight] Zero Host Mutation verified (no network pollution commands)"

# ----------------------------------------------------------- Candidate Build ---
QA_CANDIDATE_DIR="$OUTPUT_DIR/qa-candidate"
if [ -n "$REUSED_CANDIDATE_ZIP" ]; then
  # Gates and evidence must describe the same bytes; never rebuild here.
  CANDIDATE_ZIP=$REUSED_CANDIDATE_ZIP
  log "[Candidate] Reusing QA candidate: $CANDIDATE_ZIP"
else
  log "[Candidate] Building QA candidate with QA automation and production normal core..."
  AETHERROUTE_QA_AUTOMATION=1 AETHERROUTE_TEST_CORE_VARIANT=normal \
    "$ROOT/scripts/build_signed_local_test_candidate.sh" \
    "$SIGNING_CONFIG" "$VERSION" "$BUILD_NUMBER" "$QA_CANDIDATE_DIR" \
    >"$OUTPUT_DIR/candidate_build.log" 2>&1

  CANDIDATE_ZIP=$(find "$QA_CANDIDATE_DIR" -maxdepth 1 -name "*.zip" | head -n 1)
  test -n "$CANDIDATE_ZIP" && test -f "$CANDIDATE_ZIP" || {
    log "QA candidate archive not found in $QA_CANDIDATE_DIR" >&2
    exit 1
  }
  log "[Candidate] QA candidate packaged: $(basename "$CANDIDATE_ZIP")"
fi

# ----------------------------------------------------- Parallel Verification ---
VM_REPORT_DIR="$OUTPUT_DIR/vm-acceptance"
REMOTE_LOG="$OUTPUT_DIR/remote_arm64.log"
UI_PERF_DIR="$OUTPUT_DIR/ui-perf"
UI_PERF_LOG="$OUTPUT_DIR/ui_perf.log"
VM_LOG="$OUTPUT_DIR/vm_matrix.log"
RUN_REMOTE_ARM64=${AETHERROUTE_RUN_REMOTE_ARM64:-YES}

VM_PID=
REMOTE_PID=

cleanup_subprocesses() {
  if [ -n "$VM_PID" ] && kill -0 "$VM_PID" 2>/dev/null; then
    log "Terminating VM matrix process ($VM_PID)..."
    kill "$VM_PID" 2>/dev/null || true
  fi
  if [ -n "$REMOTE_PID" ] && kill -0 "$REMOTE_PID" 2>/dev/null; then
    log "Terminating remote physical gate process ($REMOTE_PID)..."
    kill "$REMOTE_PID" 2>/dev/null || true
  fi
}
trap cleanup_subprocesses EXIT HUP INT TERM

log ""
log "[Dispatch] Launching parallel execution tracks..."
START_TIME=$(date +%s)

# Track 1: Tart VM Acceptance Matrix
log "  -> [Track 1] Tart VM Acceptance Matrix launched in background..."
"$ROOT/scripts/test_vm_acceptance_matrix.sh" \
  "$CANDIDATE_ZIP" "$VM_NAME" "$VM_REPORT_DIR" \
  >"$VM_LOG" 2>&1 &
VM_PID=$!

# Track 2: Remote Physical Mac mini UI Performance Gate
log "  -> [Track 2] Remote Physical Mac mini UI Performance Gate launched in background..."
(
  set -e
  if [ "$RUN_REMOTE_ARM64" = YES ]; then
    log "[Track 2] Starting remote arm64 gate..."
    AETHERROUTE_ALLOW_REMOTE_GATE=YES \
      "$ROOT/scripts/test_remote_arm64.sh" "$REMOTE_HOST" fast \
      >"$REMOTE_LOG" 2>&1
    log "[Track 2] Remote arm64 gate passed."
  fi
  log "[Track 2] Starting UI performance and memory budget gate on $REMOTE_HOST..."
  AETHERROUTE_PERF_SECONDS="$PERF_SECONDS" \
  AETHERROUTE_PERF_REMOTE="$REMOTE_HOST" \
    "$ROOT/scripts/test_ui_performance_gate.sh" "$UI_PERF_DIR" \
    >"$UI_PERF_LOG" 2>&1
  log "[Track 2] UI performance gate completed successfully."
) &
REMOTE_PID=$!

log "[Dispatch] Both tracks running concurrently. Awaiting completion..."

vm_status=0
wait "$VM_PID" || vm_status=$?
VM_PID=
log "[Monitor] Track 1 (Tart VM Acceptance) exited with status $vm_status"

remote_status=0
wait "$REMOTE_PID" || remote_status=$?
REMOTE_PID=
log "[Monitor] Track 2 (Remote Physical Mac mini) exited with status $remote_status"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

log ""
log "================================================================================"
log " Parallel Release Acceptance Results (Total Time: ${MINUTES}m ${SECONDS}s)"
log "================================================================================"

OVERALL_SUCCESS=1

# Summary Track 1
log "Track 1: Tart VM Acceptance Matrix (6-dimension Engine x Routing)"
if [ "$vm_status" -eq 0 ]; then
  log "  Result: PASS"
  if [ -d "$VM_REPORT_DIR" ]; then
    total_checks=$(grep -R -E '\[(PASS|FAIL|SKIP)\]' "$VM_REPORT_DIR" 2>/dev/null | wc -l | tr -d ' ')
    pass_checks=$(grep -R '\[PASS\]' "$VM_REPORT_DIR" 2>/dev/null | wc -l | tr -d ' ')
    fail_checks=$(grep -R '\[FAIL\]' "$VM_REPORT_DIR" 2>/dev/null | wc -l | tr -d ' ')
    skip_checks=$(grep -R '\[SKIP\]' "$VM_REPORT_DIR" 2>/dev/null | wc -l | tr -d ' ')
    log "  Checks: Total $total_checks | PASS: $pass_checks | FAIL: $fail_checks | SKIP: $skip_checks"
    
    # Specific check for transparent proxy enhanced gates
    log "  Transparent Proxy Enhanced Gates:"
    for gate in "transparent UDP datagram" "transparent LAN bypass" "transparent raw traffic" "transparent burst concurrency" "transparent SNI recovery"; do
      gate_passes=$(grep -R "\[PASS\] $gate" "$VM_REPORT_DIR" 2>/dev/null | wc -l | tr -d ' ')
      log "    - $gate: $gate_passes passed"
    done
  fi
else
  log "  Result: FAIL (Exit $vm_status)"
  log "  Tail of VM Matrix log ($VM_LOG):"
  tail -n 30 "$VM_LOG" | sed 's/^/    /'
  OVERALL_SUCCESS=0
fi

log ""
# Summary Track 2
log "Track 2: Remote Physical Mac mini Validation"
if [ "$remote_status" -eq 0 ]; then
  log "  Result: PASS"
  if [ -f "$UI_PERF_DIR/result.txt" ]; then
    log "  UI Performance & Memory Footprint:"
    sed 's/^/    /' "$UI_PERF_DIR/result.txt"
  fi
else
  log "  Result: FAIL (Exit $remote_status)"
  if [ -f "$REMOTE_LOG" ]; then
    log "  Tail of Remote Gate log ($REMOTE_LOG):"
    tail -n 25 "$REMOTE_LOG" | sed 's/^/    /'
  fi
  if [ -f "$UI_PERF_LOG" ]; then
    log "  Tail of UI Performance log ($UI_PERF_LOG):"
    tail -n 25 "$UI_PERF_LOG" | sed 's/^/    /'
  fi
  OVERALL_SUCCESS=0
fi

log ""
log "================================================================================"
# Hardware source tests and UI fixtures cannot stand in for a connected,
# signed candidate. Require both engines' real runtime evidence separately.
candidate_sha256=$(shasum -a 256 "$CANDIDATE_ZIP" | awk '{print $1}')
if ! PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/verify_parallel_acceptance.py" evidence \
  "$PHYSICAL_EVIDENCE" "$BUILD_NUMBER" "$REMOTE_HOST" "$candidate_sha256" \
  >"$OUTPUT_DIR/physical-runtime-verification.log" 2>&1; then
  log "Physical TUN/Transparent idle reuse, upload, and interface-switch evidence is missing or invalid:"
  sed 's/^/    /' "$OUTPUT_DIR/physical-runtime-verification.log" | tee -a "$LOG_MAIN"
  log "Next steps (this run has finished, so the Mac mini is free; interface switching disrupts it):"
  log "  1. Install $CANDIDATE_ZIP on $REMOTE_HOST and connect in TUN mode, then:"
  log "     AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES python3 scripts/collect_physical_runtime_evidence.py \\"
  log "       '$CANDIDATE_ZIP' $REMOTE_HOST tun '$PHYSICAL_EVIDENCE'"
  log "  2. Reconnect in Transparent Proxy mode and repeat with engine 'transparent'."
  log "  3. Rerun this gate on the same archive:"
  log "     AETHERROUTE_ACCEPTANCE_CANDIDATE_ZIP='$CANDIDATE_ZIP' \\"
  log "     AETHERROUTE_PHYSICAL_RUNTIME_EVIDENCE='$PHYSICAL_EVIDENCE' \\"
  log "       $0 $VERSION $BUILD_NUMBER"
  OVERALL_SUCCESS=0
fi
if [ "$OVERALL_SUCCESS" -eq 1 ]; then
  log " Acceptance Decision: ACCEPTANCE GATES PASSED (signing, interop and publication gates remain separate)"
  log "================================================================================"
  exit 0
else
  log " Acceptance Decision: GATES BLOCKED (Review logs in $OUTPUT_DIR)"
  log "================================================================================"
  exit 1
fi
