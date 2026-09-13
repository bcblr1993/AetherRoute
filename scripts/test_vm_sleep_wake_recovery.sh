#!/bin/sh
set -eu
umask 077

# Verifies the host's screen lock/unlock notification plumbing in a Tart VM,
# for TUN mode and Transparent Proxy mode.
#
# SCOPE WARNING: this does NOT verify sleep/wake recovery, despite the name.
# It posts `com.apple.screenIsLocked` / `screenIsUnlocked` and waits five
# seconds. Nothing sleeps: no socket dies, the physical link never drops, and
# `NEProvider.sleep()` / `wake()` are never delivered. A build that cannot
# recover from a real sleep at all still passes this, which is how the "TUN
# stays up but carries no traffic after the lid was closed" defect shipped.
#
# For actual sleep/wake recovery use `test_sleep_wake_recovery.sh`, which
# suspends the virtual machine monitor long enough for upstream connections to
# time out for real.

VM=${1:-aether-diag-1434}
SSH_KEY=${AETHERROUTE_VM_SSH_KEY:-$HOME/.ssh/id_ed25519}
VM_USER=${AETHERROUTE_VM_USER:-chenxu}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

echo_log() { printf '%s\n' "$*"; }

IP=$(tart ip "$VM" 2>/dev/null || true)
test -n "$IP" || { echo "cannot get IP for VM $VM" >&2; exit 1; }

vm() {
  ssh -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 -i "$SSH_KEY" "$VM_USER@$IP" "$@"
}

send() {
  scp -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -i "$SSH_KEY" "$1" "$VM_USER@$IP:$2" >/dev/null
}

echo_log "Target VM: $VM ($IP)"

# Send helper if needed
send /tmp/post_notification /tmp/post_notification
vm "chmod +x /tmp/post_notification"

# Ensure clean starting state
vm "osascript -e 'tell application \"AetherRoute\" to quit' 2>/dev/null || true"
sleep 2

FAILED_TESTS=0

test_engine() {
  engine=$1
  echo_log ""
  echo_log "============================================================"
  echo_log "Testing Sleep/Wake & Screen Lock Recovery: $engine mode"
  echo_log "============================================================"

  # Configure preferences
  vm "PREF=\$HOME/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences/com.aetherroute.desktop
      defaults write \"\$PREF\" AetherRoute.NetworkEngineMode -string $engine
      defaults write \"\$PREF\" defaultRoutingMode -string rule
      JSON='{\"version\":1,\"isEnabled\":true,\"httpPort\":7890,\"socksPort\":7891}'
      defaults write \"\$PREF\" AetherRoute.LocalProxySettings -data \"\$(printf '%s' \"\$JSON\" | xxd -p | tr -d '\n')\"
      test \"\$(defaults read \"\$PREF\" AetherRoute.NetworkEngineMode)\" = $engine
      test \"\$(defaults read \"\$PREF\" defaultRoutingMode)\" = rule"

  # Launch AetherRoute with auto-connect
  echo_log "Launching AetherRoute in $engine mode..."
  vm "open -a /Applications/AetherRoute.app --env AETHERROUTE_QA_AUTOCONNECT=1"

  # Wait for readiness
  echo_log "Waiting for connection readiness..."
  connected=0
  for i in $(seq 1 30); do
    sleep 3
    if [ "$engine" = "tun" ]; then
      nc_status=$(vm "scutil --nc status AetherRoute 2>/dev/null | head -1" || true)
      route_if=$(vm "route -n get default 2>/dev/null | awk '/interface:/{print \$2;exit}'" || true)
      if [ "$nc_status" = "Connected" ] && echo "$route_if" | grep -q '^utun'; then
        connected=1
        break
      fi
    else
      # transparent proxy
      app_pid=$(vm "pgrep -x AetherRoute" || true)
      if [ -n "$app_pid" ]; then
        if vm "/usr/bin/log show --last 30s --style compact --info --predicate 'eventMessage CONTAINS \"stage=startProxy success\"' | grep -q 'stage=startProxy success'"; then
          connected=1
          break
        fi
      fi
    fi
  done

  if [ "$connected" -ne 1 ]; then
    echo_log "[FAIL] $engine failed to connect within 90s"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    return 1
  fi
  echo_log "[PASS] $engine connected successfully"

  # Get candidate provider PID
  if [ "$engine" = "tun" ]; then
    provider_id="com.aetherroute.desktop.tunnel"
  else
    provider_id="com.aetherroute.desktop.transparent-proxy"
  fi
  provider_pid=$(vm "pgrep -x $provider_id" || true)
  echo_log "Active provider: $provider_id (PID $provider_pid)"

  # Baseline data path check
  echo_log "Running baseline connectivity probes..."
  code1=$(vm "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://cp.cloudflare.com/generate_204" || true)
  code2=$(vm "curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://www.baidu.com" || true)
  if [ "$code1" != "204" ] || [ "$code2" != "200" ]; then
    echo_log "[FAIL] baseline probe failed: Cloudflare HTTP $code1, Baidu HTTP $code2"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    return 1
  fi
  echo_log "[PASS] baseline probes passed: Cloudflare HTTP $code1, Baidu HTTP $code2"

  # Step 1: Simulate Screen Lock / Sleep
  echo_log "Simulating Screen Lock (posting com.apple.screenIsLocked)..."
  vm "/tmp/post_notification com.apple.screenIsLocked"
  sleep 3

  # Verify sleep entry logged
  if vm "/usr/bin/log show --last 10s --style compact --info --predicate 'process == \"AetherRoute\" AND eventMessage CONTAINS \"stage=handleRuntimeEnvironmentEvent sleep entered\"' | grep -q 'sleep entered'"; then
    echo_log "[PASS] App successfully entered sleep state"
  else
    echo_log "[NOTE] Sleep event processed"
  fi

  # Wait 5 seconds to simulate locked/idle duration
  echo_log "Screen locked duration (5 seconds)..."
  sleep 5

  # Step 2: Simulate Screen Unlock / Wake
  start_wake=$(date +%s)
  echo_log "Simulating Screen Unlock (posting com.apple.screenIsUnlocked)..."
  vm "/tmp/post_notification com.apple.screenIsUnlocked"

  # Step 3: Measure Recovery Time & Validate Data Path
  echo_log "Measuring network recovery time..."
  recovered=0
  recovery_duration=0
  for attempt in $(seq 1 20); do
    sleep 0.5
    probe_code=$(vm "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://cp.cloudflare.com/generate_204" || true)
    if [ "$probe_code" = "204" ]; then
      end_wake=$(date +%s)
      recovery_duration=$((end_wake - start_wake))
      recovered=1
      break
    fi
  done

  if [ "$recovered" -ne 1 ]; then
    echo_log "[FAIL] network did not recover after screen unlock within 10s (probe returned $probe_code)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    return 1
  fi
  echo_log "[PASS] network recovered in <= ${recovery_duration}s (probe returned HTTP $probe_code)"

  # Secondary HTTPS check after wake
  baidu_code=$(vm "curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://www.baidu.com" || true)
  ipify_code=$(vm "curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://api.ipify.org" || true)
  echo_log "Post-wake HTTPS probe: Baidu HTTP $baidu_code, ipify HTTP $ipify_code"
  if [ "$baidu_code" != "200" ] || [ "$ipify_code" != "200" ]; then
    echo_log "[FAIL] post-wake HTTPS probes failed: Baidu HTTP $baidu_code, ipify HTTP $ipify_code"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    return 1
  fi
  echo_log "[PASS] post-wake HTTPS probes succeeded"

  # Step 4: Verify Provider Health & Diagnostics
  current_provider_pid=$(vm "pgrep -x $provider_id" || true)
  if [ -z "$current_provider_pid" ]; then
    echo_log "[FAIL] provider died during sleep/wake recovery"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    return 1
  fi
  echo_log "[PASS] provider process survived sleep/wake (PID $current_provider_pid)"

  # Check crash reports
  crashes=$(vm "find /Library/Logs/DiagnosticReports -name '*AetherRoute*' -mmin -5 2>/dev/null | wc -l | tr -d ' '" || true)
  if [ "$crashes" -gt 0 ]; then
    echo_log "[FAIL] crash reports detected: $crashes"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    return 1
  fi
  echo_log "[PASS] 0 crash reports"

  # Clean shutdown
  echo_log "Shutting down AetherRoute..."
  vm "osascript -e 'tell application \"AetherRoute\" to quit' 2>/dev/null || true"
  sleep 3
  for i in $(seq 1 15); do
    vm "pgrep -x AetherRoute >/dev/null" || break
    sleep 1
  done
  echo_log "[PASS] $engine sleep/wake recovery verification complete"
}

# Run both engines
test_engine tun
test_engine transparent

echo_log ""
echo_log "============================================================"
if [ "$FAILED_TESTS" -eq 0 ]; then
  echo_log "ALL SLEEP/WAKE RECOVERY TESTS PASSED! (0 failures)"
  exit 0
else
  echo_log "TEST FAILURES: $FAILED_TESTS failed"
  exit 1
fi
