#!/bin/sh
set -eu
umask 077

# TUN interface-address-change test. This is not a default-route handoff or
# physical sleep test. Require a proxy-only HTTPS canary returning 204.
VM=${1:-aether-diag-1434}
SSH_KEY=${AETHERROUTE_VM_SSH_KEY:-$HOME/.ssh/id_ed25519}
VM_USER=${AETHERROUTE_VM_USER:-chenxu}
PROBE_URL=${AETHERROUTE_SWITCH_PROXY_CANARY_URL:-}
case "$PROBE_URL" in https://*) ;; *) echo 'Set AETHERROUTE_SWITCH_PROXY_CANARY_URL to a proxy-only HTTPS 204 endpoint' >&2; exit 1 ;; esac
# Values are placed in a single-quoted remote shell argument.
case "$PROBE_URL" in *"'"*|*" "*|*"
"*) echo 'Invalid canary URL' >&2; exit 1 ;; esac
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
IP=$(tart ip "$VM" 2>/dev/null || true)
test -n "$IP" || fail 'cannot resolve VM IP'
vm() {
  ssh -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 -i "$SSH_KEY" "$VM_USER@$IP" "$@"
}
ALIAS_ADDED=0
cleanup() {
  if [ "$ALIAS_ADDED" -eq 1 ]; then
    vm 'sudo ifconfig en0 -alias 192.168.64.166' >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT HUP INT TERM
PID_APP=$(vm 'pgrep -x AetherRoute')
PID_TUN=$(vm 'pgrep -f com.aetherroute.desktop.tunnel')
case "$PID_TUN" in ''|*[!0-9]*) fail 'expected exactly one packet provider PID' ;; esac
case "$PID_APP" in ''|*[!0-9]*) fail 'expected exactly one app PID' ;; esac
# Refuse to remove an address that was present before this test.
if vm 'ifconfig en0' | grep -Fq 'inet 192.168.64.166 '; then
  fail 'test alias already exists'
fi
probe() {
  vm "curl --noproxy '*' --proto '=https' -s -o /dev/null -w '%{http_code}' --max-time 10 '$PROBE_URL'" || true
}
test "$(probe)" = 204 || fail 'proxy canary baseline failed'
DIRECT_CODE=$(vm "curl --noproxy '*' --interface en0 --proto '=https' -s -o /dev/null -w '%{http_code}' --max-time 10 '$PROBE_URL'" || true)
test "$DIRECT_CODE" != 204 || fail 'canary is reachable directly; cannot prove proxy routing'
verify_recovery() {
  start=$1
  # log query is bound to the current provider and the mutation interval.
  attempt=0
  while [ "$attempt" -lt 20 ]; do
    logs=$(vm "/usr/bin/log show --start '$start' --info --debug --style compact --predicate 'processID == $PID_TUN'" )
    if printf '%s\n' "$logs" | grep -Fq 'stage=physicalUplinkChanged scheduling recovery' &&
       printf '%s\n' "$logs" | grep -Fq 'stage=networkRecovery coreReset success' &&
       test "$(probe)" = 204; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  fail 'missing current-provider uplink/reset evidence or proxy canary recovery'
}
START=$(vm 'date "+%Y-%m-%d %H:%M:%S"')
ALIAS_ADDED=1
vm 'sudo ifconfig en0 alias 192.168.64.166 netmask 255.255.255.0'
verify_recovery "$START"
# Use a new timestamp second so addition evidence cannot satisfy removal.
sleep 2
START=$(vm 'date "+%Y-%m-%d %H:%M:%S"')
vm 'sudo ifconfig en0 -alias 192.168.64.166'
ALIAS_ADDED=0
verify_recovery "$START"
test "$(vm 'pgrep -x AetherRoute')" = "$PID_APP" || fail 'app restarted'
test "$(vm 'pgrep -f com.aetherroute.desktop.tunnel')" = "$PID_TUN" || fail 'provider restarted'
printf '%s\n' 'TUN interface address change: provider reset, proxy-only canary and process continuity passed.'
