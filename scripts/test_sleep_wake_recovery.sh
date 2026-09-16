#!/bin/sh
set -eu
umask 077

# Verifies that a connected tunnel regains a working data path on its own after
# the host has been suspended long enough for every upstream connection to die.
#
# Why this is not the screen-lock test
# ------------------------------------
# `test_vm_sleep_wake_recovery.sh` posts `com.apple.screenIsLocked` /
# `screenIsUnlocked` and waits five seconds. Nothing sleeps, so no socket dies,
# the physical link never drops, and `NEProvider.sleep()` / `wake()` are never
# delivered. It passes on a build that cannot recover at all, which is how the
# "TUN stays up but carries no traffic after the lid was closed" defect reached
# a release. That script is still useful for the host's notification plumbing;
# it is not evidence of sleep/wake recovery.
#
# This script suspends the VM's virtual machine monitor with SIGSTOP. The guest
# stops executing while wall-clock time passes, so peers time out and tear down
# their side exactly as they do across a real laptop sleep. SIGCONT resumes it.
# Because a save/restore is transparent to the guest, the host's wake
# handlers are then invoked through an opt-in QA-only notification bridge.
# This tests recovery across a VM suspension, not physical macOS sleep delivery.
#
# Prerequisites
# -------------
# * A running Tart VM with AetherRoute installed and *connected*. Autoconnect
#   needs a QA candidate, built with AETHERROUTE_QA_AUTOMATION=1; a release
#   build leaves `connectForQAAutomationIfRequested` compiled out and the run
#   below stops with a clear message.
# * The QA app must be launched
#   with AETHERROUTE_QA_POWER_EVENTS=1; production builds omit this bridge.
# * The VM started with `tart run <name> --no-graphics`. A windowed VMM that is
#   frozen for minutes trips macOS's hung-application detection, and the system
#   reclaims it on resume — observed once at a 300s freeze, taking the guest
#   down with it and making the run inconclusive.

VM=${1:-aether-diag-1434}
FREEZE_SECONDS=${AETHERROUTE_FREEZE_SECONDS:-300}
RECOVERY_DEADLINE_SECONDS=${AETHERROUTE_RECOVERY_DEADLINE_SECONDS:-120}
SSH_KEY=${AETHERROUTE_VM_SSH_KEY:-$HOME/.ssh/id_ed25519}
VM_USER=${AETHERROUTE_VM_USER:-chenxu}
PROBE_URL=${AETHERROUTE_PROBE_URL:-http://cp.cloudflare.com/generate_204}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-power-recovery.XXXXXX")
VMM_SUSPENDED=0
cleanup() {
  if [ "$VMM_SUSPENDED" -eq 1 ]; then kill -CONT "$VMM_PID" 2>/dev/null || true; fi
  find "$TEST_TEMP" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

IP=$(tart ip "$VM" 2>/dev/null || true)
test -n "$IP" || fail "cannot resolve an IP for VM $VM; is it running?"

vm() {
  ssh -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 -i "$SSH_KEY" "$VM_USER@$IP" "$@"
}

VMM_PID=$(pgrep -f "tart run $VM" | head -1 || true)
test -n "$VMM_PID" || fail "cannot find the 'tart run $VM' process to suspend"
say "VM $VM at $IP, monitor pid $VMM_PID"
swiftc "$ROOT/scripts/post_runtime_notification.swift" -o "$TEST_TEMP/post_notification"
scp -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  -i "$SSH_KEY" "$TEST_TEMP/post_notification" "$VM_USER@$IP:/tmp/post_notification"

# The guest has to be carrying traffic before the freeze, otherwise a pass after
# it proves nothing.
ENGINE=$(vm "defaults read \$HOME/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences/com.aetherroute.desktop AetherRoute.NetworkEngineMode 2>/dev/null" || true)
say "engine mode: ${ENGINE:-unknown}"
BASELINE=$(vm "curl -s -o /dev/null -w '%{http_code}' --max-time 10 '$PROBE_URL'" || true)
test "$BASELINE" = "204" \
  || fail "baseline probe returned '$BASELINE'; connect the tunnel in the guest first (a release build cannot autoconnect)"
if [ "${ENGINE:-}" = "tun" ]; then
  ROUTE_IF=$(vm "route -n get default 2>/dev/null | awk '/interface:/{print \$2;exit}'" || true)
  case "$ROUTE_IF" in
    utun*) say "default route via $ROUTE_IF" ;;
    *) fail "engine is tun but the default route is '$ROUTE_IF', so the tunnel is not carrying traffic" ;;
  esac
fi
say "[PASS] baseline data path healthy"

# Tell the opted-in QA host to pause polling before its VM is frozen.
vm "strings /Applications/AetherRoute.app/Contents/MacOS/AetherRoute | grep -q com.aetherroute.qa.systemDidWake" \
  || fail "this candidate does not contain the QA power-event bridge"
vm "/tmp/post_notification com.aetherroute.qa.systemWillSleep"
sleep 1
vm "/usr/bin/log show --last 5s --info --style compact --predicate 'process == \"AetherRoute\" AND eventMessage CONTAINS \"stage=handleRuntimeEnvironmentEvent sleep entered\"' | grep -q 'sleep entered'" \
  || fail "QA power bridge inactive; launch the QA app with AETHERROUTE_QA_POWER_EVENTS=1"
say "suspending the VM for ${FREEZE_SECONDS}s so upstream connections really die"
VMM_SUSPENDED=1
kill -STOP "$VMM_PID"
# Resume even if this script is interrupted; a stopped VM is not a state to
# leave behind.
sleep "$FREEZE_SECONDS"
kill -CONT "$VMM_PID"
VMM_SUSPENDED=0
RESUMED_AT=$(date +%s)
say "resumed"

# Wait for the guest to schedule again before talking to it. A short connect
# timeout keeps this bound predictable: the default would make each failed
# attempt cost fifteen seconds and stretch the loop to several minutes.
SSH_BACK=0
SSH_WAIT_DEADLINE=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$SSH_WAIT_DEADLINE" ]; do
  if ssh -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
    -i "$SSH_KEY" "$VM_USER@$IP" true 2>/dev/null; then
    SSH_BACK=1
    break
  fi
  sleep 2
done
test "$SSH_BACK" -eq 1 || fail "guest did not respond to SSH within 90s after resume; check that the VM survived the suspend (run it with --no-graphics: macOS treats a windowed VMM frozen this long as a hung app and reclaims it)"
say "guest responsive after $(( $(date +%s) - RESUMED_AT ))s"

# Explicit QA power event: screen unlock must not trigger recovery.
vm "/tmp/post_notification com.aetherroute.qa.systemDidWake"
say "posted QA system-wake event"

say "probing for recovery, deadline ${RECOVERY_DEADLINE_SECONDS}s"
RECOVERED=-1
while [ $(( $(date +%s) - RESUMED_AT )) -lt "$RECOVERY_DEADLINE_SECONDS" ]; do
  CODE=$(vm "curl -s -o /dev/null -w '%{http_code}' --max-time 5 '$PROBE_URL'" 2>/dev/null || true)
  if [ "$CODE" = "204" ]; then
    RECOVERED=$(( $(date +%s) - RESUMED_AT ))
    break
  fi
  sleep 3
done

say "collecting provider evidence"
vm "/usr/bin/log show --last 5m --info --debug --predicate 'subsystem == \"com.aetherroute.desktop\"' --style compact 2>/dev/null \
  | grep -E 'stage=(sleep|wake|recoveryRun|recoveryHealthProbe|networkRecovery|reassertNetworkSettings|flowRecovery)'" \
  || say "(no recovery log lines found)"

test "$RECOVERED" -ge 0 \
  || fail "no data path ${RECOVERY_DEADLINE_SECONDS}s after resume; the tunnel did not recover without a reconnect"
say "[PASS] data path recovered ${RECOVERED}s after resume"

# Recovery has to come from the provider converging, not from a reconnect.
vm "/usr/bin/log show --last 5m --info --debug --predicate 'subsystem == \"com.aetherroute.desktop\"' --style compact 2>/dev/null \
  | grep -q 'stage=stateTransition from=connected to=disconnected'" \
  && fail "the tunnel disconnected and reconnected; that is the workaround, not a fix" \
  || say "[PASS] recovered without dropping the tunnel"

say "sleep/wake recovery verification complete"
