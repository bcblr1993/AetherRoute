#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

fail() {
  echo "candidate network regression gate failed: $*" >&2
  exit 1
}

summary_field() {
  key=$1
  file=$2
  count=$(grep -Ec "^${key}=[0-9]+$" "$file" || true)
  test "$count" -eq 1 || fail "missing or duplicated summary field: $key"
  sed -n "s/^${key}=//p" "$file"
}

check_summary() {
  summary=$1
  test -f "$summary" && test ! -L "$summary" \
    || fail "correlation summary is not a regular file"

  vm_failure_rows=$(summary_field vm_failure_rows "$summary")
  shared_target_failure=$(summary_field shared_target_failure "$summary")
  host_other_failure=$(summary_field host_other_failure "$summary")
  vm_path_only=$(summary_field vm_path_only "$summary")
  out_of_window=$(summary_field out_of_window "$summary")

  test "$vm_path_only" -eq 0 \
    || fail "VM-only proxy-path failures observed: $vm_path_only"
  test "$host_other_failure" -eq 0 \
    || fail "VM failures did not match the host target failure: $host_other_failure"
  test "$out_of_window" -eq 0 \
    || fail "VM failures lacked an in-window host control sample: $out_of_window"
  test "$vm_failure_rows" -eq "$shared_target_failure" \
    || fail "not every VM failure was a same-target public outage"

  printf 'candidate_network_gate=passed\n'
  printf 'vm_failure_rows=%s\n' "$vm_failure_rows"
  printf 'shared_target_public_outages=%s\n' "$shared_target_failure"
  printf 'vm_path_only_failures=0\n'
}

if test "${1:-}" = --check-summary; then
  test "$#" -eq 2 || fail "usage: $0 --check-summary summary.txt"
  check_summary "$2"
  exit 0
fi

test "$#" -ge 6 && test "$#" -le 9 || {
  echo "usage: $0 vm-evidence host-evidence vm-runner-sha host-runner-sha build tun-sha [minimum-duration] [vm-interval] [host-interval]" >&2
  exit 64
}

VM_EVIDENCE=$1
HOST_EVIDENCE=$2
VM_RUNNER_SHA=$3
HOST_RUNNER_SHA=$4
EXPECTED_BUILD=$5
EXPECTED_TUN_SHA=$6
MINIMUM_DURATION=${7:-3600}
VM_INTERVAL=${8:-5}
HOST_INTERVAL=${9:-30}

for path in "$VM_EVIDENCE" "$HOST_EVIDENCE"; do
  case "$path" in /*) ;; *) fail "evidence path must be absolute: $path" ;; esac
  test -d "$path" && test ! -L "$path" \
    || fail "evidence directory is invalid: $path"
done
for digest in "$VM_RUNNER_SHA" "$HOST_RUNNER_SHA" "$EXPECTED_TUN_SHA"; do
  printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$' \
    || fail "invalid expected SHA256"
done
printf '%s:%s:%s:%s\n' \
  "$EXPECTED_BUILD" "$MINIMUM_DURATION" "$VM_INTERVAL" "$HOST_INTERVAL" \
  | grep -Eq '^[1-9][0-9]*:[1-9][0-9]*:[1-9][0-9]*:[1-9][0-9]*$' \
  || fail "invalid numeric gate parameter"

for tool in verify_network_failure_diagnostic_1434.sh \
  verify_host_network_control_1434.sh correlate_vm_host_network_1434.rb; do
  test -f "$SCRIPT_DIR/$tool" && test ! -L "$SCRIPT_DIR/$tool" \
    || fail "missing frozen gate tool: $tool"
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-1436-network-gate.XXXXXX")
cleanup() {
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

"$SCRIPT_DIR/verify_network_failure_diagnostic_1434.sh" \
  "$VM_EVIDENCE" "$VM_RUNNER_SHA" "$EXPECTED_BUILD" \
  "$EXPECTED_TUN_SHA" "$MINIMUM_DURATION" "$VM_INTERVAL" \
  >"$WORK/vm-verifier.txt"
"$SCRIPT_DIR/verify_host_network_control_1434.sh" \
  "$HOST_EVIDENCE" "$HOST_RUNNER_SHA" "$MINIMUM_DURATION" \
  "$HOST_INTERVAL" >"$WORK/host-verifier.txt"

ruby "$SCRIPT_DIR/correlate_vm_host_network_1434.rb" \
  "$VM_EVIDENCE/samples.tsv" "$HOST_EVIDENCE/samples.tsv" 45 \
  >"$WORK/correlation.tsv" 2>"$WORK/correlation-summary.txt"

cat "$WORK/vm-verifier.txt"
cat "$WORK/host-verifier.txt"
check_summary "$WORK/correlation-summary.txt"
