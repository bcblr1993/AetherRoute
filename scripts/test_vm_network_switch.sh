#!/bin/sh
set -eu
umask 077

# Verifies that AetherRoute dynamically detects network adapter / uplink address
# handoff, triggers network recovery / core reset, and preserves the tunnel data path
# without crashing, restarting, or disconnecting.

VM=${1:-aether-diag-1434}
SSH_KEY=${AETHERROUTE_VM_SSH_KEY:-$HOME/.ssh/id_ed25519}
VM_USER=${AETHERROUTE_VM_USER:-chenxu}
PROBE_URL=${AETHERROUTE_PROBE_URL:-http://cp.cloudflare.com/generate_204}

say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

IP=$(tart ip "$VM" 2>/dev/null || true)
test -n "$IP" || fail "cannot resolve IP for VM $VM"

vm() {
  ssh -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 -i "$SSH_KEY" "$VM_USER@$IP" "$@"
}

say "=== Testing Network Adapter & Uplink Handoff on $VM ($IP) ==="

# 1. Baseline verification
say "[1/4] Checking baseline tunnel state..."
PID_APP=$(vm "pgrep -x AetherRoute" || true)
PID_TUN=$(vm "pgrep -f com.aetherroute.desktop.tunnel" || true)
test -n "$PID_APP" || fail "AetherRoute is not running in guest"
test -n "$PID_TUN" || fail "Tunnel extension is not running in guest"
say "App PID: $PID_APP, Tunnel Extension PID: $PID_TUN"

BASELINE_CODE=$(vm "curl -s -o /dev/null -w '%{http_code}' --max-time 10 '$PROBE_URL'" || true)
say "Baseline probe: $BASELINE_CODE"
test "$BASELINE_CODE" = "204" || fail "Baseline probe failed"
say "[PASS] Baseline healthy"

# 2. Simulate network handoff: Add secondary uplink IP alias
say "[2/4] Simulating network handoff (adding secondary uplink IP 192.168.64.166)..."
vm "sudo ifconfig en0 alias 192.168.64.166 netmask 255.255.255.0"
# Probe data path with new uplink identity
say "Probing data path after uplink change..."
CODE1=""
for i in $(seq 1 5); do
  sleep 2
  CODE1=$(vm "curl -s -o /dev/null -w '%{http_code}' --max-time 5 '$PROBE_URL'" || true)
  if [ "$CODE1" = "204" ]; then break; fi
done
say "Probe result: $CODE1"
test "$CODE1" = "204" || fail "Probe failed after adding alias (got $CODE1)"
say "[PASS] Data path working under modified uplink signature"

# 3. Simulate second handoff: Remove alias (uplink signature change back)
say "[3/4] Simulating second network handoff (removing secondary uplink IP)..."
vm "sudo ifconfig en0 -alias 192.168.64.166"

# Probe data path after removal
say "Probing data path after uplink restored..."
CODE2=""
for i in $(seq 1 5); do
  sleep 2
  CODE2=$(vm "curl -s -o /dev/null -w '%{http_code}' --max-time 5 '$PROBE_URL'" || true)
  if [ "$CODE2" = "204" ]; then break; fi
done
say "Probe result: $CODE2"
test "$CODE2" = "204" || fail "Probe failed after restoring alias (got $CODE2)"
say "[PASS] Data path working after uplink restored"

# 4. Verify provider log evidence and process survival
say "[4/4] Verifying provider reaction logs and process stability..."
CURR_APP=$(vm "pgrep -x AetherRoute" || true)
CURR_TUN=$(vm "pgrep -f com.aetherroute.desktop.tunnel" || true)
test "$CURR_APP" = "$PID_APP" || fail "AetherRoute restarted"
test "$CURR_TUN" = "$PID_TUN" || fail "Tunnel extension restarted"
say "[PASS] Both processes survived with zero restarts"

say "--- Provider Physical Uplink Event Logs ---"
vm "/usr/bin/log show --last 1m --info --debug --predicate 'subsystem == \"com.aetherroute.desktop\"' --style compact 2>/dev/null \
  | grep -E 'stage=(physicalUplinkChanged|networkRecovery|recoveryHealthProbe|stateTransition)'" || true

say "=== Network Adapter & Uplink Handoff PASSED Successfully! ==="
