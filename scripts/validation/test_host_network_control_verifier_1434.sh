#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -x "$SCRIPT_DIR/run_host_network_control_1434.sh" ] \
  && [ -x "$SCRIPT_DIR/verify_host_network_control_1434.sh" ]; then
  RUNNER="$SCRIPT_DIR/run_host_network_control_1434.sh"
  VERIFIER="$SCRIPT_DIR/verify_host_network_control_1434.sh"
else
  ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
  RUNNER="$ROOT/scripts/validation/run_host_network_control_1434.sh"
  VERIFIER="$ROOT/scripts/validation/verify_host_network_control_1434.sh"
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-host-control-test.XXXXXX")
cleanup() { find "$WORK" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

"$RUNNER" "$WORK/evidence" 1 1 >/dev/null
RUNNER_SHA=$(shasum -a 256 "$WORK/evidence/runner.sh" | awk '{print $1}')
OUTPUT=$("$VERIFIER" "$WORK/evidence" "$RUNNER_SHA" 1 1)
printf '%s\n' "$OUTPUT" | grep -Fx 'host_control_evidence=verified' >/dev/null

printf 'tampered\n' >>"$WORK/evidence/samples.tsv"
if "$VERIFIER" "$WORK/evidence" "$RUNNER_SHA" 1 1 >/dev/null 2>&1; then
  echo 'host control verifier accepted tampered evidence' >&2
  exit 1
fi
echo 'host network control verifier self-test passed'
