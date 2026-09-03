#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERIFIER="$SCRIPT_DIR/verify_candidate_network_regression_1436.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-1436-gate-test.XXXXXX")
cleanup() {
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

write_summary() {
  destination=$1
  vm_failures=$2
  shared=$3
  host_other=$4
  vm_only=$5
  out_of_window=$6
  {
    printf 'vm_schema=raw-v1\n'
    printf 'vm_failure_rows=%s\n' "$vm_failures"
    printf 'host_samples=120\n'
    printf 'shared_target_failure=%s\n' "$shared"
    printf 'host_other_failure=%s\n' "$host_other"
    printf 'vm_path_only=%s\n' "$vm_only"
    printf 'out_of_window=%s\n' "$out_of_window"
  } >"$destination"
}

write_summary "$WORK/pass-zero.txt" 0 0 0 0 0
"$VERIFIER" --check-summary "$WORK/pass-zero.txt" >/dev/null

write_summary "$WORK/pass-shared.txt" 2 2 0 0 0
"$VERIFIER" --check-summary "$WORK/pass-shared.txt" >/dev/null

for scenario in vm-only host-other out-of-window incomplete; do
  case "$scenario" in
    vm-only) write_summary "$WORK/$scenario.txt" 1 0 0 1 0 ;;
    host-other) write_summary "$WORK/$scenario.txt" 1 0 1 0 0 ;;
    out-of-window) write_summary "$WORK/$scenario.txt" 1 0 0 0 1 ;;
    incomplete) write_summary "$WORK/$scenario.txt" 2 1 0 0 0 ;;
  esac
  if "$VERIFIER" --check-summary "$WORK/$scenario.txt" >/dev/null 2>&1; then
    echo "negative scenario unexpectedly passed: $scenario" >&2
    exit 1
  fi
done

echo 'candidate network regression verifier self-test passed'
