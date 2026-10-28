#!/bin/sh
# Installs a notarized candidate DMG on the dedicated Mac mini, collects the
# TUN and Transparent Proxy runtime receipts package_release_dmg.sh requires,
# and restores the Mac mini's own preferences afterwards.
#
# Usage: AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES \
#   collect_physical_runtime_pair.sh /absolute/candidate.dmg [/absolute/evidence-dir]
#
# Interface switching disrupts the Mac mini: never run this while the remote
# or UI performance gate uses it.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOST=chenxu@100.64.0.3
DMG=${1:-}
case "$DMG" in
  /*.dmg) ;;
  *) echo "usage: $0 /absolute/candidate.dmg [/absolute/evidence-dir]" >&2; exit 64 ;;
esac
test -f "$DMG" || { echo "candidate DMG not found: $DMG" >&2; exit 66; }
test "${AETHERROUTE_ALLOW_PHYSICAL_RUNTIME:-}" = YES || {
  echo "requires AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES for the dedicated test Mac" >&2
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
SSH="ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=10"
PREF='$HOME/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences/com.aetherroute.desktop'
QUIT='osascript -e "tell application \"AetherRoute\" to quit" >/dev/null 2>&1 || true
i=0; while pgrep -x AetherRoute >/dev/null; do i=$((i+1)); [ $i -ge 20 ] && { pkill -9 -x AetherRoute || true; sleep 2; break; }; sleep 1; done'

restore() {
  $SSH "$HOST" "PREF=$PREF; BK=\$HOME/aetherroute-prefs-backup-$BUILD.plist
$QUIT
if [ -f \"\$BK\" ]; then defaults import \"\$PREF\" \"\$BK\" && find \"\$BK\" -delete; fi
find /tmp -maxdepth 1 -name aetherroute-candidate-$BUILD.dmg -delete
echo \"restored engine=\$(defaults read \"\$PREF\" AetherRoute.NetworkEngineMode 2>/dev/null)\"" || true
}
trap 'restore; find "$WORK" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

echo "Installing $VERSION ($BUILD) on $HOST"
scp -q -o BatchMode=yes "$DMG" "$HOST:/tmp/aetherroute-candidate-$BUILD.dmg"
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

for ENGINE in tun transparent; do
  $SSH "$HOST" "PREF=$PREF
$QUIT
defaults write \"\$PREF\" AetherRoute.NetworkEngineMode -string $ENGINE
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
  test "$ready" = 1 || { echo "$ENGINE did not connect on $HOST" >&2; exit 1; }
  echo "$ENGINE connected; collecting receipts"
  PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/collect_physical_runtime_evidence.py" \
    "$DMG" "$HOST" "$ENGINE" "$OUT"
done
echo "Physical evidence complete: $OUT"
