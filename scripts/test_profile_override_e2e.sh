#!/bin/sh
set -eu
umask 077

# Profile overrides survive a subscription update (1.7.0), end to end, on a
# throwaway clone of a Tart VM.
#
# Fixtures A and B run on this Mac. Version 1 of the profile has HK 01 (A)
# and JP 01 (B); an override adds "HK Auto" (Hong Kong nodes, Fastest),
# listed first in the main group. Traffic must go through A.
#
# Version 2 replaces the profile text the way a subscription update does:
# HK 01 is renamed (remaining traffic in its name), HK 02 (B) is new and
# JP 01 is gone. Without touching the override again, the group must hold
# both Hong Kong nodes and still pick a working one: freezing the node in
# use must move traffic to the other.
#
# The base VM is never modified: everything runs in a copy-on-write clone
# that is deleted afterwards. The candidate must be a QA build
# (AETHERROUTE_QA_AUTOMATION=1).
#
# usage: test_profile_override_e2e.sh /absolute/qa-candidate.zip [base-vm] /absolute/new-report-dir

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CANDIDATE=${1:-}
BASE_VM=${2:-macos27}
REPORT_DIR=${3:-}
SSH_KEY=${AETHERROUTE_VM_SSH_KEY:-$HOME/.ssh/id_ed25519}
VM_USER=${AETHERROUTE_VM_USER:-chenxu}
ENGINES=${AETHERROUTE_OVERRIDE_E2E_ENGINES:-tun transparent}
SWITCH_BUDGET=${AETHERROUTE_OVERRIDE_E2E_SWITCH_SECONDS:-45}
BRIDGE_ADDRESS=${AETHERROUTE_FAILOVER_BRIDGE:-192.168.64.1}
PORT_A=59241
PORT_B=59242
MIHOMO_GZ=$ROOT/build/interop-tools/mihomo-darwin-arm64-v1.19.29.gz
# Not an Apple or mainland address: those match the built-in direct rules
# and never reach a node.
PROBE_URL=https://cp.cloudflare.com/generate_204

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
case "$SWITCH_BUDGET" in ''|*[!0-9]*) echo "invalid budget" >&2; exit 64 ;; esac
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
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-override.XXXXXX")
CLONE=aetherroute-override-$$
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
  printf 'mixed-port: %s\nallow-lan: true\nbind-address: %s\nmode: direct\nlog-level: info\nipv6: false\n' \
    "$port" "$BRIDGE_ADDRESS" >"$WORK/home-$name/config.yaml"
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
PID_B=$(cat "$WORK/fixture-b.pid")
log "fixtures listening: A=$BRIDGE_ADDRESS:$PORT_A B=$BRIDGE_ADDRESS:$PORT_B"

# Connections a fixture carried, leaving out the app's own health probes
# (Google 204), which reach every node during scans.
hits() {
  grep -- '-->' "$WORK/fixture-$1.log" 2>/dev/null | grep -vc 'google' || true
}

# ----------------------------------------------------------------- install ---
STAGE=install
REMOTE=$(vm 'mktemp -d /tmp/aetherroute-override.XXXXXXXX')
printf '%s\n' "$REMOTE" | grep -Eq '^/tmp/aetherroute-override\.[A-Za-z0-9]+$' || exit 1
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
vm 'grep -aq "qaAutomation profileReplaced" /Applications/AetherRoute.app/Contents/MacOS/AetherRoute' || {
  echo "candidate lacks the QA override hooks; build it with AETHERROUTE_QA_AUTOMATION=1" >&2
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
{
  echo 'mode: rule'
  echo 'ipv6: false'
  echo 'proxies:'
  echo "  - {name: HK 01, type: socks5, server: $BRIDGE_ADDRESS, port: $PORT_A, udp: false}"
  echo "  - {name: JP 01, type: socks5, server: $BRIDGE_ADDRESS, port: $PORT_B, udp: false}"
  echo 'proxy-groups:'
  echo '  - {name: Proxy, type: select, proxies: [JP 01, HK 01]}'
  echo 'rules:'
  echo '  - MATCH,Proxy'
} >"$WORK/v1.yaml"
{
  echo 'mode: rule'
  echo 'ipv6: false'
  echo 'proxies:'
  echo "  - {name: \"HK 01 [10GB left]\", type: socks5, server: $BRIDGE_ADDRESS, port: $PORT_A, udp: false}"
  echo "  - {name: HK 02, type: socks5, server: $BRIDGE_ADDRESS, port: $PORT_B, udp: false}"
  echo 'proxy-groups:'
  echo '  - {name: Proxy, type: select, proxies: ["HK 01 [10GB left]", HK 02]}'
  echo 'rules:'
  echo '  - MATCH,Proxy'
} >"$WORK/v2.yaml"
printf '%s' '{"formatVersion":1,"hiddenNodeKeywords":[],"groups":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"HK Auto","regions":["HK"],"includeKeywords":[],"excludeKeywords":[],"manualNodes":[],"mode":"fastest","parentGroup":"Proxy","position":"top"}]}' \
  >"$WORK/overrides.json"
for file in v1.yaml v2.yaml overrides.json; do send "$WORK/$file" "$REMOTE/$file"; done
first_engine=$(printf '%s\n' $ENGINES | head -1)
prime_engine "$first_engine"
quit_app
vm "set -e
  mkdir -p \"$SUPPORT\"
  for file in v1.yaml v2.yaml overrides.json; do cp '$REMOTE/'\$file \"$SUPPORT/override-e2e-\$file\"; done
  open -a /Applications/AetherRoute.app --env AETHERROUTE_QA_AUTOCONNECT=0 \
    --env AETHERROUTE_QA_PROFILE_PATH=\"$SUPPORT/override-e2e-v1.yaml\"
  sleep 10"
quit_app
log "profile version 1 imported"

probe() {
  code=$(vm "curl -sS -o /dev/null -m 8 -w '%{http_code}' '$PROBE_URL' 2>/dev/null" || true)
  test "$code" = 204
}

# Which fixture carried one probe: the one whose count grew while it ran and
# the other's did not. Prints a, b, mixed (both or neither grew) or none.
probe_route() {
  a0=$(hits a)
  b0=$(hits b)
  if probe; then
    sleep 1
    a1=$(hits a)
    b1=$(hits b)
    if [ "$a1" -gt "$a0" ] && [ "$b1" -eq "$b0" ]; then echo a
    elif [ "$b1" -gt "$b0" ] && [ "$a1" -eq "$a0" ]; then echo b
    else echo mixed; fi
  else
    echo none
  fi
}

# Connects with one QA hook (NAME=file) and waits for traffic.
launch() {
  engine=$1
  hook=$2
  file=$3
  quit_app
  vm "defaults write \"$PREF\" AetherRoute.NetworkEngineMode -string $engine
    defaults write \"$PREF\" defaultRoutingMode -string rule
    open -a /Applications/AetherRoute.app --env AETHERROUTE_QA_AUTOCONNECT=1 \
      --env $hook=\"$SUPPORT/$file\""
  CONNECTED_ROUTE=none
  waited=0
  while [ "$waited" -lt 150 ]; do
    sleep 5
    waited=$((waited + 5))
    CONNECTED_ROUTE=$(probe_route)
    case "$CONNECTED_ROUTE" in a|b) return 0 ;; esac
  done
  return 1
}

# -------------------------------------------------------------------- runs ---
for engine in $ENGINES; do
  STAGE=$engine-v1
  log "=== $engine: version 1 with the override ==="
  prime_engine "$engine"
  if ! launch "$engine" AETHERROUTE_QA_OVERRIDES_PATH override-e2e-overrides.json \
      || [ "$CONNECTED_ROUTE" != a ]; then
    fail "$engine: version 1 did not route through HK Auto (route $CONNECTED_ROUTE)"
    quit_app
    continue
  fi
  pass "$engine: version 1 routes through the custom group HK Auto (HK 01, fixture A)"

  STAGE=$engine-v2
  log "=== $engine: version 2 replaces the profile like a subscription update ==="
  if ! launch "$engine" AETHERROUTE_QA_REPLACE_PROFILE_PATH override-e2e-v2.yaml; then
    fail "$engine: version 2 never connected"
    quit_app
    continue
  fi
  pass "$engine: version 2 connected through fixture $CONNECTED_ROUTE without applying the override again"
  if [ "$CONNECTED_ROUTE" = a ]; then frozen=$PID_A; other=b; else frozen=$PID_B; other=a; fi
  kill -STOP "$frozen"
  frozen_at=$(date +%s)
  switched=0
  while [ $(( $(date +%s) - frozen_at )) -lt "$SWITCH_BUDGET" ]; do
    if [ "$(probe_route)" = "$other" ]; then
      switched=$(( $(date +%s) - frozen_at ))
      break
    fi
    sleep 2
  done
  kill -CONT "$frozen"
  if [ "$switched" -gt 0 ]; then
    pass "$engine: HK Auto kept Fastest and its new member, moving to $other ${switched}s after $CONNECTED_ROUTE stopped answering"
  else
    fail "$engine: HK Auto did not move to $other within ${SWITCH_BUDGET}s"
  fi
  quit_app
  # Version 1 again for the next engine.
  vm "open -a /Applications/AetherRoute.app --env AETHERROUTE_QA_AUTOCONNECT=0 \
    --env AETHERROUTE_QA_REPLACE_PROFILE_PATH=\"$SUPPORT/override-e2e-v1.yaml\"; sleep 8" || true
  quit_app
done

STAGE=done
vm "find '$REMOTE' -depth -delete" >/dev/null 2>&1 || true
log "failures=$FAILURES"
test "$FAILURES" -eq 0
