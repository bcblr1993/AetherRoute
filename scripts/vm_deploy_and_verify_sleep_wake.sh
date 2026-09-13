#!/bin/sh
set -eu
umask 077

# Installs a QA candidate into a Tart VM, brings up TUN mode, and runs the real
# sleep/wake recovery verification against it.
#
# The install and extension-priming sequences mirror
# `test_vm_acceptance_matrix.sh`; the point of this driver is to reach a
# connected tunnel so `test_sleep_wake_recovery.sh` has something to suspend.

CANDIDATE=${1:-}
VM=${2:-aether-diag-1434}
ENGINE=${AETHERROUTE_ENGINE:-tun}
SSH_KEY=${AETHERROUTE_VM_SSH_KEY:-$HOME/.ssh/id_ed25519}
VM_USER=${AETHERROUTE_VM_USER:-chenxu}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

test -n "$CANDIDATE" || fail "usage: $0 /absolute/candidate.zip [vm-name]"
test -f "$CANDIDATE" || fail "candidate not found: $CANDIDATE"

IP=$(tart ip "$VM" 2>/dev/null || true)
test -n "$IP" || fail "cannot resolve an IP for VM $VM"

vm() {
  ssh -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 -i "$SSH_KEY" "$VM_USER@$IP" "$@"
}
send() {
  scp -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -i "$SSH_KEY" "$1" "$VM_USER@$IP:$2" >/dev/null
}

say "VM $VM at $IP, candidate $(basename "$CANDIDATE")"

REMOTE_WORK=/tmp/ar-sleep-wake-verify
vm "rm -rf $REMOTE_WORK && mkdir -p $REMOTE_WORK"

CANDIDATE_SHA=$(shasum -a 256 "$CANDIDATE" | awk '{print $1}')
say "uploading candidate"
send "$CANDIDATE" "$REMOTE_WORK/candidate.zip"
ACTUAL_SHA=$(vm "shasum -a 256 '$REMOTE_WORK/candidate.zip'" | awk '{print $1}')
test "$ACTUAL_SHA" = "$CANDIDATE_SHA" || fail "candidate checksum mismatch in guest"

say "installing"
vm "set -e
  cd '$REMOTE_WORK'
  osascript -e 'tell application \"AetherRoute\" to quit' 2>/dev/null || true
  for i in \$(seq 1 30); do pgrep -x AetherRoute >/dev/null || break; sleep 1; done
  if pgrep -x AetherRoute >/dev/null; then
    echo 'previous app did not quit cleanly; refusing replacement' >&2; exit 1
  fi
  sleep 2
  ditto -x -k candidate.zip extract
  codesign --verify --deep --strict extract/AetherRoute.app
  if [ -d /Applications/AetherRoute.app ]; then
    find /Applications/AetherRoute.app -depth -delete
  fi
  ditto extract/AetherRoute.app /Applications/AetherRoute.app
  codesign --verify --deep --strict /Applications/AetherRoute.app
  find extract candidate.zip -depth -delete"

BUILD=$(vm '/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
  /Applications/AetherRoute.app/Contents/Info.plist')
say "installed build $BUILD"

# grep -a rather than strings: a bare test VM has no developer tools.
vm 'grep -aq "qaAutomation autoConnect" \
  /Applications/AetherRoute.app/Contents/MacOS/AetherRoute' \
  || fail "candidate lacks the QA automation fixture; rebuild with AETHERROUTE_QA_AUTOMATION=1"
say "[PASS] QA automation fixture present"

# The new build number needs its system extension registration replaced before a
# scored run, otherwise checks can observe the previous build.
say "priming $ENGINE extension registration for build $BUILD"
vm "set -e
  PREF=\$HOME/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences/com.aetherroute.desktop
  osascript -e 'tell application \"AetherRoute\" to quit' 2>/dev/null || true
  for i in \$(seq 1 30); do pgrep -x AetherRoute >/dev/null || break; sleep 1; done
  defaults write \"\$PREF\" AetherRoute.NetworkEngineMode -string $ENGINE
  defaults write \"\$PREF\" defaultRoutingMode -string rule
  JSON='{\"version\":1,\"isEnabled\":true,\"httpPort\":7890,\"socksPort\":7891}'
  defaults write \"\$PREF\" AetherRoute.LocalProxySettings -data \"\$(printf '%s' \"\$JSON\" | xxd -p | tr -d '\n')\"
  open -a /Applications/AetherRoute.app --env AETHERROUTE_QA_AUTOCONNECT=0"

case "$ENGINE" in
  tun) IDENTIFIER=com.aetherroute.desktop.tunnel ;;
  transparent) IDENTIFIER=com.aetherroute.desktop.transparent-proxy ;;
  *) fail "unknown engine $ENGINE" ;;
esac
READY=0
i=0
while [ $i -lt 30 ]; do
  i=$((i + 1))
  STATE=$(vm "systemextensionsctl list" 2>/dev/null || true)
  ROW=$(printf '%s\n' "$STATE" | grep -F "$IDENTIFIER" | grep -v 'waiting to uninstall' || true)
  case "$ROW" in
    *"/$BUILD)"*"[activated enabled]"*) READY=1; break ;;
  esac
  sleep 2
done
test "$READY" -eq 1 || {
  vm "systemextensionsctl list" || true
  fail "$IDENTIFIER did not reach [activated enabled] at build $BUILD"
}
say "[PASS] $IDENTIFIER activated at build $BUILD"

say "connecting with autoconnect"
vm "osascript -e 'tell application \"AetherRoute\" to quit' 2>/dev/null || true
  for i in \$(seq 1 30); do pgrep -x AetherRoute >/dev/null || break; sleep 1; done
  open -a /Applications/AetherRoute.app --env AETHERROUTE_QA_AUTOCONNECT=1"

CONNECTED=0
i=0
while [ $i -lt 40 ]; do
  i=$((i + 1)); sleep 3
  if [ "$ENGINE" = tun ]; then
    S=$(vm "scutil --nc status AetherRoute 2>/dev/null | head -1" || true)
    RIF=$(vm "route -n get default 2>/dev/null | awk '/interface:/{print \$2;exit}'" || true)
    case "$S:$RIF" in Connected:utun*) CONNECTED=1 ;; esac
  else
    vm "/usr/bin/log show --last 60s --style compact --info --predicate 'eventMessage CONTAINS \"stage=startProxy success\"' 2>/dev/null | grep -q 'startProxy success'" \
      && CONNECTED=1
  fi
  [ "$CONNECTED" -eq 1 ] && break
done
test "$CONNECTED" -eq 1 || {
  vm "/usr/bin/log show --last 3m --info --debug --predicate 'subsystem == \"com.aetherroute.desktop\"' --style compact 2>/dev/null | tail -40" || true
  fail "tunnel did not connect within 120s"
}
say "[PASS] connected ($ENGINE)"

# The recovery script needs this helper to post the host's wake notifications.
test -f /tmp/post_notification \
  || fail "/tmp/post_notification is missing on this Mac; build it before running"
send /tmp/post_notification /tmp/post_notification
vm "chmod +x /tmp/post_notification"

say "handing off to test_sleep_wake_recovery.sh"
exec sh "$ROOT/scripts/test_sleep_wake_recovery.sh" "$VM"
