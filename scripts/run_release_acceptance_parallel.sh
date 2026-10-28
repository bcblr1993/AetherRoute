#!/bin/sh
set -eu

# Parallel Release Acceptance Orchestrator
#
# Concurrently drives the heavy verification stages of AetherRoute:
# 1. Tart VM Acceptance Matrix (6-dimension engine x routing tests in isolated VM,
#    including transparent UDP, LAN bypass, raw traffic, burst concurrency, SNI recovery,
#    idle keep-alive reuse, and large upload checks), then the remote arm64
#    source gate on the same VM (AETHERROUTE_REMOTE_GATE_HOST=vm, the default).
# 2. UI Performance & Memory Budget Gate in the Mac mini's live GUI session
#    (preceded by the remote arm64 gate when AETHERROUTE_REMOTE_GATE_HOST names
#    a host instead of the VM).
# 3. The notarized stable candidate DMG on this Mac.
# Afterwards, with the Mac mini free again, the TUN and Transparent Proxy
# runtime receipts are collected on that DMG and verified against it.
#
# The tracks run concurrently on separate machines, slashing the total
# qualification time without lowering any quality gates or mutating the host.
# AETHERROUTE_ACCEPTANCE_PLAN_ONLY=1 prints the plan and exits before any
# build, SSH, or VM operation.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=${1:-}
BUILD_NUMBER=${2:-}
OUTPUT_DIR=${3:-}
SIGNING_CONFIG=${AETHERROUTE_SIGNING_CONFIG:-"$ROOT/Config/Signing.json"}
VM_NAME=${AETHERROUTE_VM_NAME:-macos27}
REMOTE_HOST=${AETHERROUTE_REMOTE_HOST:-chenxu@100.64.0.3}
REMOTE_GATE_HOST=${AETHERROUTE_REMOTE_GATE_HOST:-vm}
VM_USER=${AETHERROUTE_VM_USER:-chenxu}
NOTARY_PROFILE=${AETHERROUTE_NOTARY_PROFILE:-AetherRoute-Notary}
PERF_SECONDS=${AETHERROUTE_PERF_SECONDS:-300}
export AETHERROUTE_IDLE_REUSE_HOST=${AETHERROUTE_IDLE_REUSE_HOST:-httpbin.org}

# Reject diagnostic shortcuts before any build, SSH, or VM operation. They
# remain available on the individual diagnostic scripts, not this release gate.
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/verify_parallel_acceptance.py" settings

usage() {
  echo "usage: $0 [version] [build-number] [/absolute/output-directory]" >&2
  echo "  Defaults: version and build parsed from project.yml, output into outputs/acceptance-<timestamp>" >&2
}

if [ -z "$VERSION" ]; then
  VERSION=$(grep -m1 'MARKETING_VERSION:' "$ROOT/project.yml" | awk -F'"' '{print $2}')
fi
if [ -z "$BUILD_NUMBER" ]; then
  BUILD_NUMBER=$(grep -m1 'CURRENT_PROJECT_VERSION:' "$ROOT/project.yml" | awk -F'"' '{print $2}')
fi

if [ "$REMOTE_GATE_HOST" = vm ]; then
  track1_plan="vm-matrix $VM_NAME -> remote-arm64 vm fast"
  track2_plan="ui-perf $REMOTE_HOST ${PERF_SECONDS}s"
else
  track1_plan="vm-matrix $VM_NAME"
  track2_plan="remote-arm64 $REMOTE_GATE_HOST fast -> ui-perf $REMOTE_HOST ${PERF_SECONDS}s"
fi
if [ "${AETHERROUTE_ACCEPTANCE_PLAN_ONLY:-}" = 1 ]; then
  echo "plan track1: $track1_plan"
  echo "plan track2: $track2_plan"
  echo "plan track3: notarized-candidate stable $NOTARY_PROFILE"
  echo "plan then: physical-runtime $REMOTE_HOST tun transparent"
  echo "plan then: verify-physical-evidence"
  exit 0
fi

if [ -z "$OUTPUT_DIR" ]; then
  STAMP=$(date '+%Y%m%d-%H%M%S')
  OUTPUT_DIR="$ROOT/outputs/acceptance-$VERSION-$BUILD_NUMBER-$STAMP"
fi

case "$OUTPUT_DIR" in
  /*) ;;
  *) OUTPUT_DIR="$ROOT/$OUTPUT_DIR" ;;
esac

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
log " Track 1: $track1_plan"
log " Track 2: $track2_plan"
log " Track 3: notarized-candidate stable $NOTARY_PROFILE"
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

# ----------------------------------------------------- Parallel Verification ---
VM_REPORT_DIR="$OUTPUT_DIR/vm-acceptance"
REMOTE_LOG="$OUTPUT_DIR/remote_arm64.log"
UI_PERF_DIR="$OUTPUT_DIR/ui-perf"
UI_PERF_LOG="$OUTPUT_DIR/ui_perf.log"
VM_LOG="$OUTPUT_DIR/vm_matrix.log"
RUN_REMOTE_ARM64=${AETHERROUTE_RUN_REMOTE_ARM64:-YES}

NOTARIZED_DIR="$OUTPUT_DIR/notarized-candidate"
NOTARIZED_LOG="$OUTPUT_DIR/notarized_candidate.log"
VM_REMOTE_LOG="$OUTPUT_DIR/remote_arm64_vm.log"

VM_PID=
REMOTE_PID=
NOTARIZED_PID=

cleanup_subprocesses() {
  for pid in $VM_PID $REMOTE_PID $NOTARIZED_PID; do
    if kill -0 "$pid" 2>/dev/null; then
      log "Terminating track process ($pid)..."
      kill "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup_subprocesses EXIT HUP INT TERM

log ""
log "[Dispatch] Launching parallel execution tracks..."
START_TIME=$(date +%s)

# Track 1: Tart VM Acceptance Matrix, then the remote arm64 gate on the VM.
# The gate runs after the matrix so the two never share the VM.
log "  -> [Track 1] $track1_plan"
(
  set -e
  "$ROOT/scripts/test_vm_acceptance_matrix.sh" \
    "$CANDIDATE_ZIP" "$VM_NAME" "$VM_REPORT_DIR" \
    >"$VM_LOG" 2>&1
  log "[Track 1] VM matrix passed."
  if [ "$REMOTE_GATE_HOST" = vm ] && [ "$RUN_REMOTE_ARM64" = YES ]; then
    gate_ip=$(tart ip "$VM_NAME")
    log "[Track 1] Starting remote arm64 gate on $VM_USER@$gate_ip..."
    AETHERROUTE_ALLOW_REMOTE_GATE=YES \
      "$ROOT/scripts/test_remote_arm64.sh" "$VM_USER@$gate_ip" fast \
      >"$VM_REMOTE_LOG" 2>&1
    log "[Track 1] Remote arm64 gate passed on the VM."
  fi
) &
VM_PID=$!

# Track 2: Mac mini UI Performance Gate (after the remote gate when it runs there)
log "  -> [Track 2] $track2_plan"
(
  set -e
  if [ "$REMOTE_GATE_HOST" != vm ] && [ "$RUN_REMOTE_ARM64" = YES ]; then
    log "[Track 2] Starting remote arm64 gate on $REMOTE_GATE_HOST..."
    AETHERROUTE_ALLOW_REMOTE_GATE=YES \
      "$ROOT/scripts/test_remote_arm64.sh" "$REMOTE_GATE_HOST" fast \
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

# Track 3: notarized stable candidate. Its before/after network snapshot
# ignores the Tart VM's bridge, so it can build while the VM runs.
log "  -> [Track 3] notarized-candidate stable $NOTARY_PROFILE"
AETHERROUTE_CANDIDATE_CHANNEL=stable AETHERROUTE_TEST_CORE_VARIANT=normal \
  "$ROOT/scripts/build_notarized_test_candidate.sh" \
  "$SIGNING_CONFIG" "$NOTARY_PROFILE" "$VERSION" "$BUILD_NUMBER" "$NOTARIZED_DIR" \
  >"$NOTARIZED_LOG" 2>&1 &
NOTARIZED_PID=$!

log "[Dispatch] All tracks running concurrently. Awaiting completion..."

vm_status=0
wait "$VM_PID" || vm_status=$?
VM_PID=
log "[Monitor] Track 1 (Tart VM) exited with status $vm_status"

remote_status=0
wait "$REMOTE_PID" || remote_status=$?
REMOTE_PID=
log "[Monitor] Track 2 (Mac mini) exited with status $remote_status"

notarized_status=0
wait "$NOTARIZED_PID" || notarized_status=$?
NOTARIZED_PID=
log "[Monitor] Track 3 (notarized candidate) exited with status $notarized_status"

# The Mac mini is free once track 2 is done; interface switching would have
# disturbed the UI performance gate, so the receipts are collected only now.
physical_status=1
PHYSICAL_DIR="$OUTPUT_DIR/physical-runtime"
PHYSICAL_LOG="$OUTPUT_DIR/physical_runtime.log"
CANDIDATE_DMG=
if [ "$vm_status" -eq 0 ] && [ "$remote_status" -eq 0 ] && [ "$notarized_status" -eq 0 ]; then
  CANDIDATE_DMG=$(find "$NOTARIZED_DIR" -maxdepth 1 -name '*.dmg' | head -n 1)
  if [ -n "$CANDIDATE_DMG" ]; then
    log "[Physical] Collecting TUN and Transparent Proxy receipts on $REMOTE_HOST..."
    physical_status=0
    AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES \
      "$ROOT/scripts/collect_physical_runtime_pair.sh" "$CANDIDATE_DMG" "$PHYSICAL_DIR" \
      >"$PHYSICAL_LOG" 2>&1 || physical_status=$?
    if [ "$physical_status" -eq 0 ]; then
      candidate_sha=$(shasum -a 256 "$CANDIDATE_DMG" | awk '{print $1}')
      PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/verify_parallel_acceptance.py" evidence \
        "$PHYSICAL_DIR" "$BUILD_NUMBER" "$REMOTE_HOST" "$candidate_sha" \
        >>"$PHYSICAL_LOG" 2>&1 || physical_status=$?
    fi
  else
    log "[Physical] No notarized candidate DMG in $NOTARIZED_DIR"
  fi
fi
log "[Monitor] Physical runtime evidence exited with status $physical_status"

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
  if [ -f "$VM_REMOTE_LOG" ]; then
    log "  Tail of VM remote arm64 gate log ($VM_REMOTE_LOG):"
    tail -n 25 "$VM_REMOTE_LOG" | sed 's/^/    /'
  fi
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
log "Track 3: Notarized stable candidate"
if [ "$notarized_status" -eq 0 ]; then
  log "  Result: PASS ($CANDIDATE_DMG)"
else
  log "  Result: FAIL (Exit $notarized_status)"
  tail -n 25 "$NOTARIZED_LOG" | sed 's/^/    /'
  OVERALL_SUCCESS=0
fi

log ""
log "Physical runtime evidence (TUN / Transparent Proxy on the notarized DMG)"
if [ "$physical_status" -eq 0 ]; then
  log "  Result: PASS ($PHYSICAL_DIR)"
else
  log "  Result: FAIL or not run (Exit $physical_status)"
  if [ -f "$PHYSICAL_LOG" ]; then
    tail -n 25 "$PHYSICAL_LOG" | sed 's/^/    /'
  fi
  OVERALL_SUCCESS=0
fi

log ""
log "================================================================================"
if [ "$OVERALL_SUCCESS" -eq 1 ]; then
  log " Acceptance Decision: ACCEPTANCE GATES PASSED (signing, interop and publication gates remain separate)"
  # package_release_dmg.sh re-verifies these receipts against the DMG.
  log " Package with: AETHERROUTE_PHYSICAL_RUNTIME_EVIDENCE=$PHYSICAL_DIR package_release_dmg.sh $CANDIDATE_DMG ..."
  log "================================================================================"
  exit 0
else
  log " Acceptance Decision: GATES BLOCKED (Review logs in $OUTPUT_DIR)"
  log "================================================================================"
  exit 1
fi
