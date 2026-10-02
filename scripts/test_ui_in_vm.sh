#!/bin/sh
# Runs the macOS UI test suite inside the Tart VM (or, with
# AETHERROUTE_UI_REMOTE, another Mac) instead of on this Mac.
#
#   scripts/test_ui_in_vm.sh [vm-name] [evidence-dir] [only-test]
#
# 1. Here: build and sign the UI-review app and its XCTest runner with this
#    Mac's Apple Development identity (nothing is launched), via
#    AETHERROUTE_UI_TEST_EXPORT_PRODUCTS.
# 2. Copy the signed products into the VM. The VM needs no signing identity
#    and no private key ever leaves this Mac.
# 3. In the VM, `xcodebuild test-without-building -xctestrun` drives the
#    review app inside an isolated HOME. The VM must have Xcode, developer
#    mode on and a logged-in GUI session (see docs in AGENTS.md).
# 4. Copy the log and result bundle back and check this Mac's network state is
#    unchanged.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VM=${1:-macos27}
EVIDENCE=${2:-}
ONLY_TEST=${3:-}
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
[ -n "$EVIDENCE" ] || EVIDENCE="$ROOT/outputs/ui-vm-$STAMP"
case "$EVIDENCE" in /*) ;; *) EVIDENCE="$ROOT/$EVIDENCE" ;; esac
mkdir -p "$EVIDENCE"
EXPORT="$EVIDENCE/products"
REMOTE_DIR=/tmp/aetherroute-ui-vm
SSH_OPTIONS="-o BatchMode=yes -o ConnectTimeout=10"

# AETHERROUTE_UI_REMOTE=user@host runs on another Mac (e.g. the physical
# Mac mini) instead of the Tart VM; everything else is identical.
if [ -n "${AETHERROUTE_UI_REMOTE:-}" ]; then
  REMOTE=$AETHERROUTE_UI_REMOTE
  VM=$REMOTE
else
  IP=$(tart ip "$VM" 2>/dev/null || true)
  [ -n "$IP" ] || { echo "VM $VM is not running (tart run $VM)." >&2; exit 69; }
  REMOTE="chenxu@$IP"
fi
vm() { ssh $SSH_OPTIONS "$REMOTE" "$@"; }

# The runner drives a real GUI session; without one it cannot start.
vm 'pgrep -x Dock >/dev/null' || {
  echo "The VM has no logged-in GUI session; log in to the VM window once." >&2
  exit 78
}
vm '/usr/sbin/DevToolsSecurity -status | grep -q "currently enabled" && xcodebuild -version >/dev/null 2>&1' || {
  echo "The VM needs Xcode and developer mode (DevToolsSecurity -enable)." >&2
  exit 78
}

host_network_hash() {
  {
    /usr/sbin/scutil --proxy
    /usr/sbin/scutil --dns
    /usr/sbin/netstat -rn -f inet | awk '$1 == "default" {print}'
    /usr/sbin/netstat -rn -f inet6 | awk '$1 == "default" {print}'
    /sbin/ifconfig -l
  } | shasum -a 256 | awk '{print $1}'
}
host_tunnel_pids() {
  pgrep -f 'com.aetherroute.desktop.(tunnel|transparent-proxy)' | sort | tr '\n' ' '
}
network_before=$(host_network_hash)
tunnel_before=$(host_tunnel_pids)

echo "==> Building and signing UI test products here (nothing is launched)"
AETHERROUTE_UI_TEST_EXPORT_PRODUCTS="$EXPORT" "$ROOT/scripts/test_ui.sh"

echo "==> Copying products to the VM"
vm "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR/Home/tmp'"
rsync -a --delete -e "ssh $SSH_OPTIONS" "$EXPORT/" "$REMOTE:$REMOTE_DIR/Products/"

XCTESTRUN=$(cd "$EXPORT" && ls ./*.xctestrun | head -1 | sed 's|^\./||')
echo "==> Running in the VM ($XCTESTRUN)"
only=
[ -z "$ONLY_TEST" ] || only="-only-testing:$ONLY_TEST"
status=0
vm "cd '$REMOTE_DIR' && \
  TEST_RUNNER_AETHERROUTE_UI_TEST_ISOLATED_HOME='$REMOTE_DIR/Home' \
  TEST_RUNNER_AETHERROUTE_RUN_UI_RESPONSIVENESS=NO \
  HOME='$REMOTE_DIR/Home' CFFIXED_USER_HOME='$REMOTE_DIR/Home' TMPDIR='$REMOTE_DIR/Home/tmp' \
  AETHERROUTE_UI_TEST_ISOLATED_HOME='$REMOTE_DIR/Home' \
  /usr/bin/caffeinate -dimsu xcodebuild test-without-building \
    -xctestrun 'Products/$XCTESTRUN' \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath '$REMOTE_DIR/result.xcresult' \
    $only" > "$EVIDENCE/ui-test.log" 2>&1 || status=$?

echo "==> Collecting results"
rsync -a -e "ssh $SSH_OPTIONS" "$REMOTE:$REMOTE_DIR/result.xcresult/" "$EVIDENCE/result.xcresult/" 2>/dev/null || true
vm "rm -rf '$REMOTE_DIR'; pkill -f aetherroute-ui-vm 2>/dev/null; true"
find "$EXPORT" -depth -delete 2>/dev/null || true

network_after=$(host_network_hash)
tunnel_after=$(host_tunnel_pids)
host_unchanged=true
[ "$network_before" = "$network_after" ] || host_unchanged=false
[ "$tunnel_before" = "$tunnel_after" ] || host_unchanged=false

passed=$(grep -c "Test Case .* passed" "$EVIDENCE/ui-test.log" || true)
failed=$(grep -c "Test Case .* failed" "$EVIDENCE/ui-test.log" || true)
{
  printf 'vm=%s\n' "$VM"
  printf 'test_status=%s\n' "$status"
  printf 'passed=%s\n' "$passed"
  printf 'failed=%s\n' "$failed"
  printf 'host_network_before_sha256=%s\n' "$network_before"
  printf 'host_network_after_sha256=%s\n' "$network_after"
  printf 'host_tunnel_pids_before=%s\n' "$tunnel_before"
  printf 'host_tunnel_pids_after=%s\n' "$tunnel_after"
  printf 'host_unchanged=%s\n' "$host_unchanged"
} > "$EVIDENCE/result.env"
cat "$EVIDENCE/result.env"
echo "Evidence: $EVIDENCE"

[ "$host_unchanged" = true ] || { echo "This Mac's network state or tunnel changed during the run." >&2; exit 1; }
exit "$status"
