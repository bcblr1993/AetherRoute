#!/bin/sh
set -eu
umask 077

# Real node failover against a throwaway clone of a Tart VM (1.6.0).
#
# Two independent proxy fixtures run on this Mac, bound to the VM bridge: A
# (the preferred node) and B. A profile in the VM routes everything through
# one select group listing A then B. For each engine:
#
# 1. Failover mode connects through A.
# 2. A is frozen (SIGSTOP, a node that stops answering without closing its
#    connections). Traffic must reach B within the switch budget, and a
#    long download that was running through A must be closed rather than
#    left hanging.
# 3. A resumes. Traffic must return to A within the return budget.
# 4. Manual mode pinned to A: freezing A must never move traffic to B.
#
# The base VM is never modified: everything runs in a copy-on-write clone
# that is deleted afterwards. The candidate must be a QA build
# (AETHERROUTE_QA_AUTOMATION=1) so the app connects and sets the group mode
# without a person clicking.
#
# usage: test_failover_e2e.sh /absolute/qa-candidate.zip [base-vm] /absolute/new-report-dir

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CANDIDATE=${1:-}
BASE_VM=${2:-macos27}
REPORT_DIR=${3:-}
SSH_KEY=${AETHERROUTE_VM_SSH_KEY:-$HOME/.ssh/id_ed25519}
VM_USER=${AETHERROUTE_VM_USER:-chenxu}
ENGINES=${AETHERROUTE_FAILOVER_ENGINES:-tun transparent}
SWITCH_BUDGET=${AETHERROUTE_FAILOVER_SWITCH_SECONDS:-45}
CLOSE_BUDGET=${AETHERROUTE_FAILOVER_CLOSE_SECONDS:-60}
RETURN_BUDGET=${AETHERROUTE_FAILOVER_RETURN_SECONDS:-240}
PINNED_SECONDS=${AETHERROUTE_FAILOVER_PINNED_SECONDS:-45}
BRIDGE_ADDRESS=${AETHERROUTE_FAILOVER_BRIDGE:-192.168.64.1}
PORT_A=59231
PORT_B=59232
MIHOMO_GZ=$ROOT/build/interop-tools/mihomo-darwin-arm64-v1.19.29.gz
PROBE_URL=https://www.apple.com/library/test/success.html
SLOW_URL='https://httpbin.org/drip?duration=150&numbytes=150&code=200&delay=0'

usage() {
  echo "usage: $0 /absolute/qa-candidate.zip [base-vm] /absolute/new-report-dir" >&2
  exit 64
}
case "$CANDIDATE" in /*.zip) ;; *) usage ;; esac
case "$REPORT_DIR" in /*) ;; *) usage ;; esac
test -f "$CANDIDATE" || { echo "candidate not found: $CANDIDATE" >&2; exit 66; }
test ! -e "$REPORT_DIR" || { echo "refusing to overwrite reports: $REPORT_DIR" >&2; exit 1; }
for engine in $ENGINES; do
  case "$engine" in tun|transparent) ;; *) echo "invalid engine: $engine" >&2; exit 64 ;; esac
done
for value in "$SWITCH_BUDGET" "$CLOSE_BUDGET" "$RETURN_BUDGET" "$PINNED_SECONDS"; do
  case "$value" in ''|*[!0-9]*) echo "invalid budget: $value" >&2; exit 64 ;; esac
done
command -v tart >/dev/null || { echo "tart is required" >&2; exit 69; }
test -f "$MIHOMO_GZ" || {
  echo "fixture proxy missing; run ./scripts/fetch_interop_tools.sh first" >&2
  exit 66
}
tart list 2>/dev/null | awk -v v="$BASE_VM" '$2 == v {found=1} END {exit !found}' \
  || { echo "unknown VM: $BASE_VM" >&2; exit 66; }
test "$(tart list 2>/dev/null | awk -v v="$BASE_VM" '$2 == v {print $NF}')" = stopped \
  || { echo "stop $BASE_VM first; it is cloned, never changed" >&2; exit 1; }

mkdir -m 700 -p "$REPORT_DIR"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-failover.XXXXXX")
CLONE=aetherroute-failover-$$
CLONED=0
FAILURES=0
STAGE=preflight

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$REPORT_DIR/run.txt"; }
fail() { log "FAIL $*"; FAILURES=$((FAILURES + 1)); }
pass() { log "PASS $*"; }

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  for name in a b; do
    if [ -f "$WORK/fixture-$name.pid" ]; then
      pid=$(cat "$WORK/fixture-$name.pid")
      kill -CONT "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
    fi
    if [ -f "$WORK/fixture-$name.log" ]; then
      cp "$WORK/fixture-$name.log" "$REPORT_DIR/fixture-$name.log" 2>/dev/null || true
    fi
  done
  if [ "$CLONED" -eq 1 ]; then
    tart stop "$CLONE" >/dev/null 2>&1 || true
    tart delete "$CLONE" >/dev/null 2>&1 || {
      echo "could not delete VM clone $CLONE" >&2; status=1;
    }
  fi
  find "$WORK" -depth -delete 2>/dev/null || true
  if [ "$status" -eq 0 ] && [ "$FAILURES" -gt 0 ]; then status=1; fi
  printf 'stage=%s\nfailures=%s\nexit_status=%s\n' "$STAGE" "$FAILURES" "$status" \
    >"$REPORT_DIR/result.txt"
  echo "reports: $REPORT_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ------------------------------------------------------------------- clone ---
STAGE=clone
log "cloning $BASE_VM to $CLONE (copy-on-write)"
tart clone "$BASE_VM" "$CLONE"
CLONED=1
nohup tart run "$CLONE" --no-graphics >/dev/null 2>&1 &
IP=""
i=0
while [ "$i" -lt 40 ]; do
  IP=$(tart ip "$CLONE" 2>/dev/null || true)
  if [ -n "$IP" ] && ssh -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 -i "$SSH_KEY" "$VM_USER@$IP" true 2>/dev/null; then
    break
  fi
  IP=""
  i=$((i + 1))
  sleep 10
done
test -n "$IP" || { echo "VM clone never became reachable over SSH" >&2; exit 1; }
log "clone reachable at $IP"

vm() {
  ssh -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 \
    -i "$SSH_KEY" "$VM_USER@$IP" "$@"
}
send() {
  scp -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -i "$SSH_KEY" "$1" "$VM_USER@$IP:$2" >/dev/null
}

# ---------------------------------------------------------------- fixtures ---
STAGE=fixtures
ifconfig 2>/dev/null | grep -q "inet $BRIDGE_ADDRESS " \
  || { echo "no host interface at $BRIDGE_ADDRESS (is the VM bridge up?)" >&2; exit 1; }
gunzip -c "$MIHOMO_GZ" >"$WORK/mihomo"
chmod 700 "$WORK/mihomo"
start_fixture() {
  name=$1
  port=$2
  mkdir -p "$WORK/home-$name"
  cat >"$WORK/home-$name/config.yaml" <<EOF
mixed-port: $port
allow-lan: true
bind-address: $BRIDGE_ADDRESS
mode: direct
log-level: info
ipv6: false
EOF
  "$WORK/mihomo" -d "$WORK/home-$name" >"$WORK/fixture-$name.log" 2>&1 &
  echo $! >"$WORK/fixture-$name.pid"
  attempt=0
  until nc -z "$BRIDGE_ADDRESS" "$port" 2>/dev/null; do
    attempt=$((attempt + 1))
    test "$attempt" -lt 30 || { echo "fixture $name did not listen" >&2; exit 1; }
    sleep 1
  done
}
start_fixture a "$PORT_A"
start_fixture b "$PORT_B"
PID_A=$(cat "$WORK/fixture-a.pid")
log "fixtures listening: A=$BRIDGE_ADDRESS:$PORT_A B=$BRIDGE_ADDRESS:$PORT_B"

# Connections a fixture carried, leaving out the app's own health probes
# (Google 204), which reach every node during scans.
hits() {
  grep -- '-->' "$WORK/fixture-$1.log" 2>/dev/null | grep -vc 'google' || true
}

# ----------------------------------------------------------------- install ---
STAGE=install
REMOTE=$(vm 'mktemp -d /tmp/aetherroute-failover.XXXXXXXX')
printf '%s\n' "$REMOTE" | grep -Eq '^/tmp/aetherroute-failover\.[A-Za-z0-9]+$' || exit 1
send "$CANDIDATE" "$REMOTE/candidate.zip"
vm "set -e
  osascript -e 'tell application \"AetherRoute\" to quit' 2>/dev/null || true
  for i in \$(seq 1 30); do pgrep -x AetherRoute >/dev/null || break; sleep 1; done
  pkill -9 -x AetherRoute 2>/dev/null || true
  sudo killall -9 com.aetherroute.desktop.tunnel com.aetherroute.desktop.transparent-proxy 2>/dev/null || true
  cd '$REMOTE'
  ditto -x -k candidate.zip extract
  if [ -d /Applications/AetherRoute.app ]; then find /Applications/AetherRoute.app -depth -delete; fi
  ditto extract/AetherRoute.app /Applications/AetherRoute.app
  codesign --verify --deep --strict /Applications/AetherRoute.app
  find extract candidate.zip -depth -delete"
BUILD=$(vm '/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" /Applications/AetherRoute.app/Contents/Info.plist')
vm 'grep -aq "qaAutomation selectionMode" /Applications/AetherRoute.app/Contents/MacOS/AetherRoute' || {
  echo "candidate lacks the QA selection-mode hook; build it with AETHERROUTE_QA_AUTOMATION=1" >&2
  exit 1
}
log "installed build $BUILD"

PREF='$HOME/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences/com.aetherroute.desktop'
SUPPORT='$HOME/Library/Group Containers/group.com.aetherroute.desktop/Library/Application Support/AetherRoute'

quit_app() {
  vm "osascript -e 'tell application \"AetherRoute\" to quit' 2>/dev/null || true
    for i in \$(seq 1 30); do pgrep -x AetherRoute >/dev/null || exit 0; sleep 1; done
    pkill -9 -x AetherRoute 2>/dev/null || true; sleep 2"
}

# Activates the candidate's extension for an engine before anything is scored.
prime_engine() {
  engine=$1
  case "$engine" in
    tun) identifier=com.aetherroute.desktop.tunnel ;;
    transparent) identifier=com.aetherroute.desktop.transparent-proxy ;;
  esac
  quit_app
  vm "defaults write \"$PREF\" AetherRoute.NetworkEngineMode -string $engine
    open -a /Applications/AetherRoute.app --env AETHERROUTE_QA_AUTOCONNECT=0
    for i in \$(seq 1 45); do
      systemextensionsctl list | grep -v 'waiting to uninstall' \
        | grep '$identifier' | grep \"/$BUILD)\" | grep -q 'activated enabled' && exit 0
      sleep 2
    done
    exit 1" || { echo "extension $identifier $BUILD never activated" >&2; exit 1; }
}

# ----------------------------------------------------------------- profile ---
STAGE=profile
cat >"$WORK/failover.yaml" <<EOF
mode: rule
log-level: warning
ipv6: false
proxies:
  - {name: Fixture A, type: socks5, server: $BRIDGE_ADDRESS, port: $PORT_A, udp: false}
  - {name: Fixture B, type: socks5, server: $BRIDGE_ADDRESS, port: $PORT_B, udp: false}
proxy-groups:
  - {name: Proxy, type: select, proxies: [Fixture A, Fixture B]}
rules:
  - MATCH,Proxy
EOF
send "$WORK/failover.yaml" "$REMOTE/failover.yaml"
first_engine=$(printf '%s\n' $ENGINES | head -1)
prime_engine "$first_engine"
quit_app
vm "set -e
  mkdir -p \"$SUPPORT\"
  cp '$REMOTE/failover.yaml' \"$SUPPORT/failover-e2e.yaml\"
  open -a /Applications/AetherRoute.app --env AETHERROUTE_QA_AUTOCONNECT=0 \
    --env AETHERROUTE_QA_PROFILE_PATH=\"$SUPPORT/failover-e2e.yaml\"
  sleep 10"
quit_app
log "fixture profile imported"

probe() {
  code=$(vm "curl -sS -o /dev/null -m 8 -w '%{http_code}' '$PROBE_URL' 2>/dev/null" || true)
  test "$code" = 200
}

connect() {
  engine=$1
  mode=$2
  quit_app
  vm "defaults write \"$PREF\" AetherRoute.NetworkEngineMode -string $engine
    open -a /Applications/AetherRoute.app --env AETHERROUTE_QA_AUTOCONNECT=1 \
      --env AETHERROUTE_QA_SELECTION_MODE=Proxy=$mode"
  start_hits=$(hits a)
  waited=0
  while [ "$waited" -lt 150 ]; do
    sleep 5
    waited=$((waited + 5))
    if probe && [ "$(hits a)" -gt "$start_hits" ]; then
      return 0
    fi
  done
  return 1
}

# -------------------------------------------------------------------- runs ---
for engine in $ENGINES; do
  STAGE=$engine-failover
  log "=== $engine: failover mode ==="
  prime_engine "$engine"
  if ! connect "$engine" failover; then
    fail "$engine: never connected through the preferred node A"
    quit_app
    continue
  fi
  pass "$engine: connected through preferred node A"

  # A long download through A, to see whether it is closed or left hanging.
  slow_pid=$(vm "nohup curl -sS -o /dev/null -m 200 '$SLOW_URL' >/dev/null 2>&1 & echo \$!")
  sleep 4
  if ! vm "kill -0 $slow_pid" 2>/dev/null; then
    fail "$engine: the long download through A did not start"
  fi

  b_before=$(hits b)
  kill -STOP "$PID_A"
  frozen_at=$(date +%s)
  log "$engine: froze A"
  switched=0
  closed_after=""
  while [ $(( $(date +%s) - frozen_at )) -lt "$SWITCH_BUDGET" ]; do
    if [ -z "$closed_after" ] && ! vm "kill -0 $slow_pid" 2>/dev/null; then
      closed_after=$(( $(date +%s) - frozen_at ))
    fi
    if probe && [ "$(hits b)" -gt "$b_before" ]; then
      switched=$(( $(date +%s) - frozen_at ))
      break
    fi
    sleep 2
  done
  if [ "$switched" -gt 0 ]; then
    pass "$engine: traffic moved to B ${switched}s after A stopped answering (budget ${SWITCH_BUDGET}s)"
  else
    fail "$engine: traffic did not reach B within ${SWITCH_BUDGET}s"
  fi
  while [ -z "$closed_after" ] && [ $(( $(date +%s) - frozen_at )) -lt "$CLOSE_BUDGET" ]; do
    if ! vm "kill -0 $slow_pid" 2>/dev/null; then
      closed_after=$(( $(date +%s) - frozen_at ))
    fi
    sleep 2
  done
  if [ -n "$closed_after" ]; then
    pass "$engine: the download stuck on A was closed ${closed_after}s after A stopped answering"
  else
    fail "$engine: the download stuck on A was still open after ${CLOSE_BUDGET}s"
    vm "kill $slow_pid" 2>/dev/null || true
  fi

  a_before=$(hits a)
  kill -CONT "$PID_A"
  resumed_at=$(date +%s)
  log "$engine: resumed A"
  returned=0
  while [ $(( $(date +%s) - resumed_at )) -lt "$RETURN_BUDGET" ]; do
    sleep 10
    if probe && [ "$(hits a)" -gt "$a_before" ]; then
      returned=$(( $(date +%s) - resumed_at ))
      break
    fi
  done
  if [ "$returned" -gt 0 ]; then
    pass "$engine: traffic returned to A ${returned}s after it answered again (budget ${RETURN_BUDGET}s)"
  else
    fail "$engine: traffic did not return to A within ${RETURN_BUDGET}s"
  fi

  STAGE=$engine-manual
  log "=== $engine: manual mode pinned to A ==="
  if ! connect "$engine" manual; then
    fail "$engine: manual mode never connected through A"
    quit_app
    continue
  fi
  b_before=$(hits b)
  kill -STOP "$PID_A"
  pinned_at=$(date +%s)
  leaked=0
  while [ $(( $(date +%s) - pinned_at )) -lt "$PINNED_SECONDS" ]; do
    probe || true
    if [ "$(hits b)" -gt "$b_before" ]; then leaked=1; break; fi
    sleep 3
  done
  kill -CONT "$PID_A"
  if [ "$leaked" -eq 0 ]; then
    pass "$engine: manual mode stayed on A for ${PINNED_SECONDS}s and never used B"
  else
    fail "$engine: manual mode moved traffic to B"
  fi
  quit_app
done

STAGE=done
vm "find '$REMOTE' -depth -delete" >/dev/null 2>&1 || true
log "failures=$FAILURES"
test "$FAILURES" -eq 0
