#!/bin/sh
# Installs a notarized candidate DMG in the isolated Tart VM (`macos27`),
# collects the TUN and Transparent Proxy runtime receipts package_release_dmg.sh
# requires, and restores the VM's preferences afterwards.
#
# Usage: AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES \
#   collect_physical_runtime_pair.sh /absolute/candidate.dmg [/absolute/evidence-dir]
#
# Interface switching disrupts the VM's uplinks: run this after the VM matrix,
# remote ARM64 source gate, and UI performance gate have finished.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VM_NAME=${AETHERROUTE_VM_NAME:-macos27}
VM_USER=${AETHERROUTE_VM_USER:-chenxu}
SSH_KEY=${AETHERROUTE_VM_SSH_KEY:-$HOME/.ssh/id_ed25519}
EVIDENCE_HOST=${AETHERROUTE_REMOTE_HOST:-vm:$VM_NAME}
DMG=${1:-}
case "$DMG" in
  /*.dmg) ;;
  *) echo "usage: $0 /absolute/candidate.dmg [/absolute/evidence-dir]" >&2; exit 64 ;;
esac
test -f "$DMG" || { echo "candidate DMG not found: $DMG" >&2; exit 66; }
test "${AETHERROUTE_ALLOW_PHYSICAL_RUNTIME:-}" = YES || {
  echo "requires AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES for the dedicated test VM" >&2
  exit 64
}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-physical-pair.XXXXXX")
trap 'find "$WORK" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
MOUNT="$WORK/mount"
mkdir "$MOUNT"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" -quiet
VERSION=$(defaults read "$MOUNT/AetherRoute.app/Contents/Info" CFBundleShortVersionString)
BUILD=$(defaults read "$MOUNT/AetherRoute.app/Contents/Info" CFBundleVersion)
hdiutil detach "$MOUNT" -quiet
OUT=${2:-"$ROOT/outputs/physical-runtime-$VERSION-$BUILD"}

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=10 -o StrictHostKeyChecking=accept-new"
if [ -f "$SSH_KEY" ]; then
  SSH_OPTS="$SSH_OPTS -o IdentitiesOnly=yes -i $SSH_KEY"
fi
SSH="ssh $SSH_OPTS"
SCP="scp -q $SSH_OPTS"

VM_IP=""
case "$EVIDENCE_HOST" in
  vm:*)
    TARGET_VM=${EVIDENCE_HOST#vm:}
    state=$(tart list 2>/dev/null | awk -v v="$TARGET_VM" '$2 == v {print $NF}')
    test -n "$state" || { echo "unknown Tart VM: $TARGET_VM" >&2; exit 66; }
    if [ "$state" != running ]; then
      nohup tart run "$TARGET_VM" --no-graphics >/dev/null 2>&1 &
    fi
    for _ in $(seq 1 30); do
      VM_IP=$(tart ip "$TARGET_VM" 2>/dev/null || true)
      if [ -n "$VM_IP" ] && $SSH "$VM_USER@$VM_IP" true 2>/dev/null; then
        break
      fi
      VM_IP=""
      sleep 2
    done
    test -n "$VM_IP" || { echo "Tart VM $TARGET_VM is not reachable over SSH" >&2; exit 1; }
    HOST="$VM_USER@$VM_IP"
    ;;
  *)
    HOST="$EVIDENCE_HOST"
    ;;
esac

PREF='$HOME/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences/com.aetherroute.desktop'
QUIT='osascript -e "tell application \"AetherRoute\" to quit" >/dev/null 2>&1 || true
i=0; while pgrep -x AetherRoute >/dev/null; do i=$((i+1)); [ $i -ge 20 ] && { pkill -9 -x AetherRoute || true; sleep 2; break; }; sleep 1; done'

restore() {
  $SSH "$HOST" "PREF=$PREF; BK=\$HOME/aetherroute-prefs-backup-$BUILD.plist
$QUIT
if [ -f \"\$BK\" ]; then defaults import \"\$PREF\" \"\$BK\" && find \"\$BK\" -delete; fi
rm -f \"/tmp/aetherroute-candidate-$BUILD.dmg\"
echo \"restored engine=\$(defaults read \"\$PREF\" AetherRoute.NetworkEngineMode 2>/dev/null)\"" || true
}
trap 'restore; find "$WORK" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

echo "Installing $VERSION ($BUILD) on $EVIDENCE_HOST ($HOST)"
$SCP "$DMG" "$HOST:/tmp/aetherroute-candidate-$BUILD.dmg"
$SSH "$HOST" "set -e
PREF=$PREF; BK=\$HOME/aetherroute-prefs-backup-$BUILD.plist
test -e \"\$BK\" || defaults export \"\$PREF\" \"\$BK\"
$QUIT
M=\$(mktemp -d /tmp/ar-mnt.XXXXXX)
hdiutil attach /tmp/aetherroute-candidate-$BUILD.dmg -readonly -nobrowse -mountpoint \"\$M\" -quiet
if [ -e /Applications/AetherRoute.app ]; then find /Applications/AetherRoute.app -depth -delete; fi
ditto \"\$M/AetherRoute.app\" /Applications/AetherRoute.app
hdiutil detach \"\$M\" -quiet; rmdir \"\$M\"
test \"\$(defaults read /Applications/AetherRoute.app/Contents/Info CFBundleVersion)\" = $BUILD"

if [ -n "${TARGET_VM:-}" ]; then
  needs_reprime=$($SSH "$HOST" '
    for id in com.aetherroute.desktop.tunnel com.aetherroute.desktop.transparent-proxy; do
      bundled="/Applications/AetherRoute.app/Contents/Library/SystemExtensions/$id.systemextension/Contents/MacOS/$id"
      matched=0
      for staged in /Library/SystemExtensions/*/"$id.systemextension/Contents/MacOS/$id"; do
        if [ -f "$staged" ] && cmp -s "$staged" "$bundled"; then matched=1; break; fi
      done
      if [ "$matched" -ne 1 ]; then echo yes; exit 0; fi
    done
    echo no
  ')
  if [ "$needs_reprime" = yes ]; then
    echo "Re-staging notarized system extensions for build $BUILD on $EVIDENCE_HOST"
    $SSH "$HOST" "set -e
PREF=$PREF
$QUIT
sudo killall -9 com.aetherroute.desktop.tunnel com.aetherroute.desktop.transparent-proxy 2>/dev/null || true
sudo python3 - <<'PY'
import plistlib
from pathlib import Path
p = Path('/Library/SystemExtensions/db.plist')
if p.is_file():
    data = plistlib.loads(p.read_bytes())
    data['developerMode'] = True
    for ext in data.get('extensions', []):
        if ext.get('identifier', '').startswith('com.aetherroute.desktop.'):
            ext['bundleVersion']['CFBundleVersion'] = '0'
    p.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_BINARY))
PY
sudo killall -9 sysextd 2>/dev/null || true
sleep 2
for eng in tun transparent; do
  defaults write \"\$PREF\" AetherRoute.NetworkEngineMode -string \$eng
  defaults write \"\$PREF\" AetherRoute.LastConnectionIntent -bool false
  open -a /Applications/AetherRoute.app
  sleep 8
  $QUIT
done"
    tart stop "$TARGET_VM" >/dev/null 2>&1 || true
    sleep 2
    nohup tart run "$TARGET_VM" --no-graphics >/dev/null 2>&1 &
    VM_IP=""
    for _ in $(seq 1 40); do
      VM_IP=$(tart ip "$TARGET_VM" 2>/dev/null || true)
      if [ -n "$VM_IP" ] && $SSH "$VM_USER@$VM_IP" 'pgrep -x Dock >/dev/null && pgrep -x WindowServer >/dev/null' 2>/dev/null; then
        break
      fi
      VM_IP=""
      sleep 2
    done
    test -n "$VM_IP" || { echo "Tart VM $TARGET_VM did not return after system extension reboot" >&2; exit 1; }
    HOST="$VM_USER@$VM_IP"
  fi
fi

for ENGINE in tun transparent; do
  $SSH "$HOST" "PREF=$PREF
$QUIT
defaults write \"\$PREF\" AetherRoute.NetworkEngineMode -string $ENGINE
defaults write \"\$PREF\" defaultRoutingMode -string rule
JSON='{\"version\":1,\"isEnabled\":true,\"httpPort\":7890,\"socksPort\":7891}'
defaults write \"\$PREF\" AetherRoute.LocalProxySettings -data \"\$(printf '%s' \"\$JSON\" | xxd -p | tr -d '\n')\"
defaults write \"\$PREF\" AetherRoute.LastConnectionIntent -bool true
open -a /Applications/AetherRoute.app"
  ready=0
  for _ in $(seq 1 40); do
    if $SSH "$HOST" "sh -s -- ready $BUILD $ENGINE" <"$ROOT/scripts/vm_matrix_lifecycle.sh" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 5
  done
  test "$ready" = 1 || { echo "$ENGINE did not connect on $EVIDENCE_HOST" >&2; exit 1; }
  for _ in $(seq 1 10); do
    if $SSH "$HOST" 'curl -sS --max-time 8 -o /dev/null https://api.anthropic.com/v1/messages' >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  echo "$ENGINE connected; collecting receipts"
  AETHERROUTE_VM_IP="$VM_IP" \
    PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/collect_physical_runtime_evidence.py" \
    "$DMG" "$EVIDENCE_HOST" "$ENGINE" "$OUT"
done
echo "Runtime evidence complete: $OUT"
