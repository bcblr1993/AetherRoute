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
MIN_FREE_KB=${AETHERROUTE_VM_MIN_FREE_KB:-2097152}

# Values below become remote shell arguments. Reject unknown modes before any
# installation, and make every run own its temporary files and logs.
engine_count=0
for engine in $ENGINES; do
  case "$engine" in tun|transparent) ;; *) echo "invalid engine: $engine" >&2; exit 64 ;; esac
  engine_count=$((engine_count + 1))
done
routing_count=0
for routing in $ROUTING_MODES; do
  case "$routing" in rule|global|direct) ;; *) echo "invalid routing mode: $routing" >&2; exit 64 ;; esac
  routing_count=$((routing_count + 1))
done
case "$MIN_FREE_KB" in ''|*[!0-9]*) echo "invalid disk budget" >&2; exit 64 ;; esac
test "$engine_count" -gt 0 && test "$routing_count" -gt 0 || exit 64

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
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-vm-matrix.XXXXXX")
REMOTE_WORK=""
cleanup() {
  if [ -n "$REMOTE_WORK" ]; then
    vm "find '$REMOTE_WORK' -depth -delete" >/dev/null 2>&1 || true
  fi
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

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
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -i "$SSH_KEY" \
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
  ssh -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 -i "$SSH_KEY" "$VM_USER@$IP" "$@"
}
send() {
  scp -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -i "$SSH_KEY" "$1" "$VM_USER@$IP:$2" >/dev/null
}

# ---------------------------------------------------------------- install ---
# Delete only this harness's old staging files before uploading another copy.
# Keep app data and prior reports. A failed/partial run cannot accumulate ZIPs.
vm 'for path in /tmp/candidate.zip /tmp/candidate-extract; do
      if [ -e "$path" ]; then find "$path" -depth -delete; fi
    done'
free_kb=$(vm "df -Pk /Applications | awk 'NR == 2 {print \$4}'")
case "$free_kb" in ''|*[!0-9]*) echo "cannot determine VM free disk" >&2; exit 1 ;; esac
expanded_bytes=$(unzip -l "$CANDIDATE" | awk '/[0-9]+ files?$/ {print $1}')
case "$expanded_bytes" in ''|*[!0-9]*) echo "cannot determine candidate size" >&2; exit 1 ;; esac
archive_bytes=$(stat -f %z "$CANDIDATE")
required_kb=$((MIN_FREE_KB + (archive_bytes + expanded_bytes * 2 + 1023) / 1024))
test "$free_kb" -ge "$required_kb" || {
  echo "VM has ${free_kb} KiB free; requires ${required_kb} KiB for staging and installation" >&2
  exit 1
}
log "VM free disk before installation: ${free_kb} KiB"
REMOTE_WORK=$(vm 'mktemp -d /tmp/aetherroute-vm-matrix.XXXXXXXX')
printf '%s\n' "$REMOTE_WORK" | grep -Eq '^/tmp/aetherroute-vm-matrix\.[A-Za-z0-9]+$' || exit 1
candidate_sha=$(shasum -a 256 "$CANDIDATE" | awk '{print $1}')
if [ -n "$REPORT_DIR" ]; then
  printf 'candidate_sha256=%s\nvm=%s\nfree_kb_before=%s\n' \
    "$candidate_sha" "$VM" "$free_kb" >"$REPORT_DIR/candidate.txt"
fi
log "installing $(basename "$CANDIDATE")"
send "$CANDIDATE" "$REMOTE_WORK/candidate.zip"
send "$ROOT/scripts/test_runtime_acceptance.sh" "$REMOTE_WORK/test_runtime_acceptance.sh"
actual_sha=$(vm "shasum -a 256 '$REMOTE_WORK/candidate.zip'" | awk '{print $1}')
test "$actual_sha" = "$candidate_sha" || { echo "VM candidate checksum mismatch" >&2; exit 1; }
vm "set -e
  cd '$REMOTE_WORK'
  chmod +x test_runtime_acceptance.sh
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
printf '%s\n' "$BUILD" | grep -Eq '^[1-9][0-9]*$' || exit 1
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

    vm "set -e
      PREF=\$HOME/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences/com.aetherroute.desktop
      osascript -e 'tell application \"AetherRoute\" to quit' 2>/dev/null || true
      for i in \$(seq 1 30); do pgrep -x AetherRoute >/dev/null || break; sleep 1; done
      if pgrep -x AetherRoute >/dev/null; then
        echo 'app did not quit cleanly between modes' >&2; exit 1
      fi
      for i in \$(seq 1 30); do
        pgrep -f '/com[.]aetherroute[.]desktop[.](tunnel|transparent-proxy)[.]systemextension/Contents/MacOS/' >/dev/null || break
        sleep 1
      done
      if pgrep -f '/com[.]aetherroute[.]desktop[.](tunnel|transparent-proxy)[.]systemextension/Contents/MacOS/' >/dev/null; then
        echo 'provider did not stop between modes' >&2; exit 1
      fi
      defaults write \"\$PREF\" AetherRoute.NetworkEngineMode -string $engine
      defaults write \"\$PREF\" defaultRoutingMode -string $routing
      JSON='{\"version\":1,\"isEnabled\":true,\"httpPort\":7890,\"socksPort\":7891}'
      defaults write \"\$PREF\" AetherRoute.LocalProxySettings \
        -data \"\$(printf '%s' \"\$JSON\" | xxd -p | tr -d '\n')\"
      test \"\$(defaults read \"\$PREF\" AetherRoute.NetworkEngineMode)\" = $engine
      test \"\$(defaults read \"\$PREF\" defaultRoutingMode)\" = $routing
      open -a /Applications/AetherRoute.app --env AETHERROUTE_QA_AUTOCONNECT=1"

    # Wait for whichever signal this engine actually produces.
    readiness_failed=0
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
      || { log "did not reach a connected state within 150s"; readiness_failed=1; }

    if ! vm "PREF=\$HOME/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences/com.aetherroute.desktop
      test \"\$(defaults read \"\$PREF\" AetherRoute.NetworkEngineMode)\" = $engine &&
      test \"\$(defaults read \"\$PREF\" defaultRoutingMode)\" = $routing"; then
      log "running preferences do not match requested $label"
      readiness_failed=1
    fi

    remote_report=$REMOTE_WORK/acceptance-$engine-$routing.txt
    if vm "AETHERROUTE_ACCEPTANCE_PRIVILEGED_OBSERVATION=YES '$REMOTE_WORK/test_runtime_acceptance.sh' $BUILD '$remote_report'" \
      >"$WORK/matrix-$engine-$routing.out" 2>&1; then
      failures=0
    else
      failures=$?
    fi
    failures=$((failures + readiness_failed))
    tail -30 "$WORK/matrix-$engine-$routing.out"
    if [ -n "$REPORT_DIR" ]; then
      cp "$WORK/matrix-$engine-$routing.out" \
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
if [ -n "$REPORT_DIR" ]; then
  printf 'build=%s\nfailed_checks=%s\n' "$BUILD" "$TOTAL_FAIL" >"$REPORT_DIR/result.txt"
  (cd "$REPORT_DIR" && shasum -a 256 ./*.txt >SHA256SUMS)
fi
# Shell statuses wrap at 256. Never turn a large failure count into success.
test "$TOTAL_FAIL" -eq 0
