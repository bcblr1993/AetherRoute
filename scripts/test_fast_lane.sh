#!/bin/sh
# Day-to-day gate: everything that runs on this Mac without touching its
# network, its tunnel or any system extension. Run it before every commit;
# the full release pipeline (VM matrix, Mac mini gates, physical evidence)
# runs only for releases.
#
#   scripts/test_fast_lane.sh            # core regression, gates, differential
#   AETHER_FAST_LANE_INTEROP=1 ...       # also the 12-protocol interop gate
#
# The interop gate runs automatically when Core/Engine has commits or edits
# that the superproject has not recorded yet, since AGENTS.md requires it
# before any engine change is committed.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STARTED=$(date +%s)
step() {
  name=$1
  shift
  begin=$(date +%s)
  if "$@" >"$LOGS/$name.log" 2>&1; then
    echo "PASS $name ($(( $(date +%s) - begin ))s)"
  else
    echo "FAIL $name ($(( $(date +%s) - begin ))s); log: $LOGS/$name.log" >&2
    exit 1
  fi
}
LOGS=${AETHER_FAST_LANE_LOGS:-"$ROOT/outputs/fast-lane-$(date -u +%Y%m%dT%H%M%SZ)"}
mkdir -p "$LOGS"

engine_changed=0
if [ -n "$(git -C "$ROOT" status --porcelain -- Core/Engine)" ] \
  || [ -n "$(git -C "$ROOT/Core/Engine" status --porcelain)" ]; then
  engine_changed=1
fi

step network-switch env PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/test_network_switch_gate.py"
step engine-reconnect sh "$ROOT/Tests/EngineReconnect/run.sh"
step runtime-environment sh "$ROOT/Tests/RuntimeEnvironment/run.sh"
step network-snapshot sh "$ROOT/scripts/test_network_state_snapshot.sh"
step large-upload-gate env PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/test_large_upload_gate.py"
step recovery-subscription-compat sh "$ROOT/scripts/test_recovery_and_subscription_compat_gate.sh"
step differential-unit env PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/test_subscription_differential.py"
# Cargo rebuilds only what changed, so building every time costs seconds and
# keeps the differential end-to-end run on the engine as it is now.
step differential-engine-build sh -c "cd '$ROOT/Core/Engine' && CARGO_TARGET_DIR='$ROOT/build/differential-target' cargo build --locked -p clash-rs --release --no-default-features --features shadowsocks,ssh,shadowquic,wireguard,aws-lc-rs,clash-lib/aether-tuic,clash-lib/zero_copy"
step differential-e2e env PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/test_subscription_differential.py" --e2e
# The engine's own unit tests, with the app's feature set (no other gate
# ran them before 2.0), and the app's copy of the engine capability list.
step engine-unit sh -c "cd '$ROOT/Core/Engine' && CARGO_TARGET_DIR='$ROOT/build/engine-unit-target' cargo test --locked -p clash-lib --lib --no-default-features --features shadowsocks,ssh,shadowquic,wireguard,aws-lc-rs,aether-tuic,zero_copy"
step engine-capabilities env PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/engine_capabilities.py" check
if [ "$engine_changed" = 1 ] || [ "${AETHER_FAST_LANE_INTEROP:-0}" = 1 ]; then
  step protocol-interop "$ROOT/scripts/test_protocol_interop_all.sh" "$LOGS/interop"
fi
echo "Fast lane passed in $(( $(date +%s) - STARTED ))s; logs in $LOGS"
