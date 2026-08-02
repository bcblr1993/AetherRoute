#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONTROLLER="$ROOT/scripts/test_remote_arm64.sh"
WORKER="$ROOT/scripts/remote_arm64_worker.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-remote-guards.XXXXXX")
cleanup() {
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

sh -n "$CONTROLLER"
sh -n "$WORKER"

bootstrap_line=$(grep -n 'scripts/bootstrap.sh' "$ROOT/scripts/test.sh" \
  | head -1 | cut -d: -f1)
dmg_line=$(grep -n 'scripts/test_dmg_upgrade_rollback.sh' "$ROOT/scripts/test.sh" \
  | head -1 | cut -d: -f1)
test -n "$bootstrap_line"
test -n "$dmg_line"
test "$bootstrap_line" -lt "$dmg_line" || {
  echo "Remote validation must generate the Xcode project before the DMG gate" >&2
  exit 1
}

grep -F '  Services \' "$CONTROLLER" >/dev/null || {
  echo "Remote controller payload is missing Services" >&2
  exit 1
}
grep -F 'references/interop-tools/clash-rs-2272555/clash-lib-protocol-tests' \
  "$CONTROLLER" >/dev/null || {
  echo "Remote controller payload is missing the pinned interop verifier" >&2
  exit 1
}

if AETHERROUTE_ALLOW_REMOTE_GATE=NO \
  "$CONTROLLER" example.invalid fast > "$WORK/no-opt-in.log" 2>&1; then
  echo "Remote controller ran without explicit opt-in" >&2
  exit 1
fi
grep -F 'requires explicit AETHERROUTE_ALLOW_REMOTE_GATE=YES' \
  "$WORK/no-opt-in.log" >/dev/null

if AETHERROUTE_ALLOW_REMOTE_GATE=YES \
  "$CONTROLLER" '-oProxyCommand=unsafe' fast > "$WORK/unsafe.log" 2>&1; then
  echo "Remote controller accepted an option-like endpoint" >&2
  exit 1
fi
grep -F 'plain user@host or host value' "$WORK/unsafe.log" >/dev/null

if AETHERROUTE_ALLOW_REMOTE_GATE=YES \
  "$CONTROLLER" localhost fast > "$WORK/local.log" 2>&1; then
  echo "Remote controller accepted localhost" >&2
  exit 1
fi
grep -F 'refuses a local endpoint' "$WORK/local.log" >/dev/null

for required in \
  'uname -m' \
  'AETHERROUTE_DERIVED_DATA_PATH' \
  'export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"' \
  'for command in go gofmt jq python3' \
  'scripts/test.sh' \
  'scripts/test_sanitizers.sh' \
  'System proxy/DNS/default-route/interface state changed' \
  'Remote source tree changed during validation'
do
  grep -F "$required" "$WORKER" >/dev/null || {
    echo "Remote worker is missing guard: $required" >&2
    exit 1
  }
done

recursive_remove=$(printf 'rm%srf' ' -')
if grep -F "$recursive_remove" "$CONTROLLER" "$WORKER" >/dev/null; then
  echo "Remote validation cleanup must use an exact find target" >&2
  exit 1
fi

echo 'Remote arm64 validation guards verified'
