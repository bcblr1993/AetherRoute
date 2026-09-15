#!/bin/sh
set -eu
umask 077

# Verifies that AetherRoute in a Tart VM cleanly recovers from physical uplink
# disconnect and reconnect without dropping the tunnel or restarting the app.

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

say "=== Testing Network Disconnect & Reconnect Recovery on $VM ($IP) ==="

# 1. Baseline verification
say "[1/5] Verifying baseline tunnel health..."
PID_APP=$(vm "pgrep -x AetherRoute" || true)
PID_TUN=$(vm "pgrep -f com.aetherroute.desktop.tunnel" || true)
test -n "$PID_APP" || fail "AetherRoute is not running in guest"
test -n "$PID_TUN" || fail "Tunnel extension is not running in guest"
say "App PID: $PID_APP, Tunnel Extension PID: $PID_TUN"

STATUS=$(vm "scutil --nc status AetherRoute 2>/dev/null | head -1" || true)
say "Tunnel status: $STATUS"
test "$STATUS" = "Connected" || fail "Tunnel is not Connected"

BASELINE_CODE=$(vm "curl -s -o /dev/null -w '%{http_code}' --max-time 10 '$PROBE_URL'" || true)
say "Baseline probe: $BASELINE_CODE"
test "$BASELINE_CODE" = "204" || fail "Baseline probe failed (got $BASELINE_CODE)"
say "[PASS] Baseline data path healthy"

# 2. Prepare in-guest disconnection simulator
say "[2/5] Preparing in-guest disconnection simulator..."
vm 'cat << "INNER_EOF" > /tmp/sim_disconnect.sh
#!/bin/sh
LOG=/tmp/disconnect_test.log
exec > "$LOG" 2>&1
echo "=== SIMULATING PHYSICAL LINK DISCONNECT ==="
date "+%H:%M:%S"

echo "Taking en0 down..."
sudo ifconfig en0 down
sleep 8

echo "Restoring en0..."
sudo ifconfig en0 192.168.64.6 netmask 255.255.255.0 up
sudo route add default 192.168.64.1 2>/dev/null || sudo route change default 192.168.64.1 2>/dev/null || true
sleep 4

echo "=== DISCONNECT & RECONNECT SCRIPT COMPLETE ==="
date "+%H:%M:%S"
INNER_EOF
chmod +x /tmp/sim_disconnect.sh'

# 3. Trigger disconnect in background
say "[3/5] Triggering link disconnection (en0 down for 8s)..."
DISCONNECT_START=$(date +%s)
# Trigger in background via nohup so SSH session drop does not interrupt execution
vm 'nohup /tmp/sim_disconnect.sh >/dev/null 2>&1 &' || true

say "Waiting for network interruption and restoration..."
sleep 12

# Wait for SSH to become responsive again
say "Waiting for SSH restoration..."
SSH_UP=0
for i in $(seq 1 30); do
  if ssh -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=2 \
    -i "$SSH_KEY" "$VM_USER@$IP" true 2>/dev/null; then
    SSH_UP=1
    break
  fi
  sleep 1
done
test "$SSH_UP" -eq 1 || fail "Guest network did not come back online after 30s"
say "[PASS] Guest SSH restored in $(( $(date +%s) - DISCONNECT_START ))s"

# 4. Verify data path recovery
say "[4/5] Probing data path recovery..."
RECOVERED=0
for i in $(seq 1 20); do
  CODE=$(vm "curl -s -o /dev/null -w '%{http_code}' --max-time 5 '$PROBE_URL'" 2>/dev/null || true)
  if [ "$CODE" = "204" ]; then
    RECOVERED=1
    say "[PASS] Data path successfully resumed probe HTTP 204"
    break
  fi
  sleep 2
done
test "$RECOVERED" -eq 1 || fail "Data path failed to recover within 40s after link restoration"

# 5. Verify process survival and provider log evidence
say "[5/5] Checking process survival and provider evidence..."
CURR_APP=$(vm "pgrep -x AetherRoute" || true)
CURR_TUN=$(vm "pgrep -f com.aetherroute.desktop.tunnel" || true)
test "$CURR_APP" = "$PID_APP" || fail "AetherRoute restarted (was $PID_APP, now $CURR_APP)"
test "$CURR_TUN" = "$PID_TUN" || fail "Tunnel extension restarted (was $PID_TUN, now $CURR_TUN)"
say "[PASS] Both App and Tunnel Extension survived without restart (PIDs $PID_APP, $PID_TUN)"

say "--- Provider Recovery Logs ---"
vm "/usr/bin/log show --last 2m --info --debug --predicate 'subsystem == \"com.aetherroute.desktop\"' --style compact 2>/dev/null \
  | grep -E 'stage=(networkRecovery|physicalUplinkChanged|recoveryHealthProbe|stateTransition)'" || true

say "--- Disconnection Simulator Log ---"
vm "cat /tmp/disconnect_test.log" || true

say "=== Network Disconnect & Reconnect Recovery PASSED Successfully! ==="
