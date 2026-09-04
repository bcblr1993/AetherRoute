#!/bin/sh
set -eu
umask 077

# Unattended acceptance matrix against a Tart VM.
#
# Installs a QA candidate, then walks every engine and routing mode, running
# scripts/test_runtime_acceptance.sh in each and collecting the verdicts. The
# candidate must be built with AETHERROUTE_QA_AUTOMATION=1 so the app can start
# its tunnel without a human clicking Connect; that fixture is rejected by the
# Developer ID guard for anything destined for distribution.
#
# The VM must auto-login (FileVault off), or its home directory stays encrypted
# and SSH key authentication cannot read authorized_keys.
#
# Exit status is the number of failed checks across the whole matrix.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CANDIDATE=${1:-}
VM=${2:-aether-diag-1434}
REPORT_DIR=${3:-}
SSH_KEY=${AETHERROUTE_VM_SSH_KEY:-$HOME/.ssh/id_ed25519}
VM_USER=${AETHERROUTE_VM_USER:-chenxu}
ENGINES=${AETHERROUTE_MATRIX_ENGINES:-tun transparent}
ROUTING_MODES=${AETHERROUTE_MATRIX_ROUTING:-rule global direct}

usage() {
  echo "usage: $0 /absolute/candidate.zip [vm-name] [/absolute/report-dir]" >&2
}

case "$CANDIDATE" in
  /*.zip) ;;
  *) usage; exit 64 ;;
esac
test -f "$CANDIDATE" || { echo "candidate not found: $CANDIDATE" >&2; exit 66; }
if [ -n "$REPORT_DIR" ]; then
  case "$REPORT_DIR" in /*) ;; *) usage; exit 64 ;; esac
  test ! -e "$REPORT_DIR" || {
    echo "refusing to overwrite reports: $REPORT_DIR" >&2
    exit 1
  }
  mkdir -m 700 -p "$REPORT_DIR"
fi

command -v tart >/dev/null || { echo "tart is required" >&2; exit 69; }
test -f "$ROOT/scripts/test_runtime_acceptance.sh" \
  || { echo "acceptance script is missing" >&2; exit 66; }

log() { printf '%s\n' "$*"; }

# ------------------------------------------------------------------- boot ---
state=$(tart list 2>/dev/null | awk -v v="$VM" '$2 == v {print $NF}')
test -n "$state" || { echo "unknown VM: $VM" >&2; exit 66; }
if [ "$state" != running ]; then
  log "booting $VM headless"
  nohup tart run "$VM" --no-graphics >/dev/null 2>&1 &
fi

IP=""
i=0
while [ "$i" -lt 40 ]; do
  IP=$(tart ip "$VM" 2>/dev/null || true)
  if [ -n "$IP" ] && ssh -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$SSH_KEY" \
    "$VM_USER@$IP" true 2>/dev/null; then
    break
  fi
  IP=""
  i=$((i + 1))
  sleep 10
done
test -n "$IP" || {
  echo "VM never became reachable over SSH." >&2
  echo "Auto-login must be on and FileVault off, or the home directory stays" >&2
  echo "encrypted and sshd cannot read authorized_keys." >&2
  exit 1
}
log "VM reachable at $IP"

vm() {
  ssh -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 -i "$SSH_KEY" "$VM_USER@$IP" "$@"
}
send() {
  scp -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
    -i "$SSH_KEY" "$1" "$VM_USER@$IP:$2" >/dev/null
}

# ---------------------------------------------------------------- install ---
log "installing $(basename "$CANDIDATE")"
send "$CANDIDATE" /tmp/candidate.zip
send "$ROOT/scripts/test_runtime_acceptance.sh" /tmp/test_runtime_acceptance.sh
vm 'set -e
  chmod +x /tmp/test_runtime_acceptance.sh
  osascript -e "tell application \"AetherRoute\" to quit" 2>/dev/null || true
  for i in $(seq 1 15); do pgrep -x AetherRoute >/dev/null || break; sleep 1; done
  pkill -x AetherRoute 2>/dev/null || true
  sleep 2
  rm -rf /Applications/AetherRoute.app /tmp/candidate-extract
  mkdir -p /tmp/candidate-extract
  ditto -x -k /tmp/candidate.zip /tmp/candidate-extract
  cp -R /tmp/candidate-extract/AetherRoute.app /Applications/'

BUILD=$(vm '/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
  /Applications/AetherRoute.app/Contents/Info.plist')
log "installed build $BUILD"

# grep -a rather than strings: a bare test VM has no developer tools.
vm 'grep -aq "qaAutomation autoConnect" \
  /Applications/AetherRoute.app/Contents/MacOS/AetherRoute' || {
  echo "candidate lacks the QA automation fixture; rebuild with" >&2
  echo "AETHERROUTE_QA_AUTOMATION=1 scripts/build_signed_local_test_candidate.sh" >&2
  exit 1
}

TOTAL_FAIL=0
SUMMARY=""

for engine in $ENGINES; do
  for routing in $ROUTING_MODES; do
    label="$engine/$routing"
    log ""
    log "=== $label ==="

    vm "PREF=\$HOME/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences/com.aetherroute.desktop
      osascript -e 'tell application \"AetherRoute\" to quit' 2>/dev/null || true
      for i in \$(seq 1 15); do pgrep -x AetherRoute >/dev/null || break; sleep 1; done
      pkill -x AetherRoute 2>/dev/null || true
      sleep 3
      defaults write \"\$PREF\" AetherRoute.NetworkEngineMode -string $engine
      defaults write \"\$PREF\" defaultRoutingMode -string $routing
      JSON='{\"version\":1,\"isEnabled\":true,\"httpPort\":7890,\"socksPort\":7891}'
      defaults write \"\$PREF\" AetherRoute.LocalProxySettings \
        -data \"\$(printf '%s' \"\$JSON\" | xxd -p | tr -d '\n')\"
      open -a /Applications/AetherRoute.app --env AETHERROUTE_QA_AUTOCONNECT=1"

    # Wait for whichever signal this engine actually produces.
    vm "for i in \$(seq 1 30); do
          sleep 5
          if [ '$engine' = transparent ]; then
            pgrep -f com.aetherroute.desktop.transparent-proxy >/dev/null && exit 0
          else
            [ \"\$(scutil --nc status AetherRoute 2>/dev/null | head -1)\" = Connected ] && exit 0
          fi
        done
        exit 1" \
      && log "connected unattended" \
      || log "did not reach a connected state within 150s"

    remote_report=/tmp/acceptance-$engine-$routing.txt
    vm "rm -f $remote_report" || true
    if vm "/tmp/test_runtime_acceptance.sh $BUILD $remote_report" \
      >"${TMPDIR:-/tmp}/matrix-$engine-$routing.out" 2>&1; then
      failures=0
    else
      failures=$?
    fi
    tail -30 "${TMPDIR:-/tmp}/matrix-$engine-$routing.out"
    if [ -n "$REPORT_DIR" ]; then
      cp "${TMPDIR:-/tmp}/matrix-$engine-$routing.out" \
        "$REPORT_DIR/$engine-$routing.txt"
    fi
    TOTAL_FAIL=$((TOTAL_FAIL + failures))
    SUMMARY="$SUMMARY
  $(printf '%-22s %s' "$label" \
      "$([ "$failures" -eq 0 ] && echo 'all checks passed' \
        || echo "$failures failed")")"
  done
done

log ""
log "matrix summary (build $BUILD on $VM):$SUMMARY"
log ""
if [ "$TOTAL_FAIL" -eq 0 ]; then
  log "every configuration passed."
else
  log "$TOTAL_FAIL checks failed across the matrix."
fi
[ -n "$REPORT_DIR" ] && log "reports: $REPORT_DIR"
exit "$TOTAL_FAIL"
