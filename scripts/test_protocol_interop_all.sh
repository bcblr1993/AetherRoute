#!/bin/sh
# Builds the engine's interoperability test binary and runs every protocol
# interop gate against real third-party servers on loopback: the sing-box
# matrix (24 cases), VLESS REALITY (Xray), WireGuard (wireguard-go), ShadowQUIC
# (Mihomo) and SSH (OpenSSH). Each gate runs even if an earlier one fails; the
# summary and per-gate logs land in the output directory.
#
# Usage: test_protocol_interop_all.sh [/absolute/output-directory]
# Tools come from scripts/fetch_interop_tools.sh (AETHER_INTEROP_TOOLS to use
# another directory). The engine is built optimized like the shipped one;
# AETHER_INTEROP_PROFILE=debug builds faster for local iteration. The
# runners' own knobs (AETHER_INTEROP_CYCLES, AETHER_INTEROP_IDLE_SECS,
# AETHER_INTEROP_CASES) pass through.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_ROOT=${AETHER_CORE_ROOT:-"$ROOT/Core/Engine"}
TOOLS=${AETHER_INTEROP_TOOLS:-"$ROOT/build/interop-tools"}
TARGET_DIR=${AETHER_INTEROP_TARGET_DIR:-"$ROOT/build/interop-target"}
OUTPUT=${1:-"$ROOT/outputs/interop-$(date -u +%Y%m%dT%H%M%SZ)"}
FEATURES=aether-tuic,aws-lc-rs,shadowquic,shadowsocks,ssh,tun,wireguard,zero_copy

case $OUTPUT in
  /*) ;;
  *)
    echo "output directory must be absolute: $OUTPUT" >&2
    exit 1
    ;;
esac
for tool in sing-box shadow-tls xray wireguard-go-loopback-server \
  mihomo-darwin-arm64-v1.19.29.gz; do
  if [ ! -f "$TOOLS/$tool" ]; then
    echo "missing $TOOLS/$tool; run scripts/fetch_interop_tools.sh first" >&2
    exit 1
  fi
done
for command in cargo jq lsof shasum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "protocol interop requires $command" >&2
    exit 1
  fi
done

# Every server binds a fixed loopback port; a leftover process would make a
# gate test the wrong server or fail for an unrelated reason.
busy=$(lsof -nP -iTCP:59000-59042 -sTCP:LISTEN 2>/dev/null | tail -n +2 || true)
busy_udp=$(lsof -nP -iUDP:59000-59042 2>/dev/null | tail -n +2 || true)
if [ -n "$busy$busy_udp" ]; then
  echo "interop ports 59000-59042 are in use:" >&2
  printf '%s\n%s\n' "$busy" "$busy_udp" >&2
  exit 1
fi

mkdir -p "$OUTPUT"
PROFILE=${AETHER_INTEROP_PROFILE:-release}
case $PROFILE in
  release) PROFILE_FLAG=--release ;;
  debug) PROFILE_FLAG= ;;
  *)
    echo "AETHER_INTEROP_PROFILE must be release or debug" >&2
    exit 1
    ;;
esac

echo "Building clash-lib interop tests ($PROFILE)"
TEST_BIN=$(
  cd "$CORE_ROOT"
  CARGO_TARGET_DIR="$TARGET_DIR" cargo test --locked -p clash-lib $PROFILE_FLAG \
    --no-default-features --features "$FEATURES" --no-run \
    --message-format=json 2>"$OUTPUT/build.log" \
    | jq -r 'select(.profile.test == true and .target.name == "clash_lib")
      | .executable' \
    | tail -n 1
)
if [ -z "$TEST_BIN" ] || [ ! -x "$TEST_BIN" ]; then
  tail -n 40 "$OUTPUT/build.log" >&2
  echo "clash-lib interop test binary did not build" >&2
  exit 1
fi
TEST_SHA256=$(shasum -a 256 "$TEST_BIN" | awk '{print $1}')
CORE_COMMIT=$(git -C "$CORE_ROOT" rev-parse HEAD)
CORE_DIRTY=$(git -C "$CORE_ROOT" status --porcelain | wc -l | tr -d ' ')

SUMMARY="$OUTPUT/summary.txt"
{
  echo "core commit: $CORE_COMMIT (uncommitted files: $CORE_DIRTY)"
  echo "profile: $PROFILE"
  echo "test binary sha256: $TEST_SHA256"
} >"$SUMMARY"

failures=0
run_gate() {
  name=$1
  shift
  echo "Running $name"
  started=$(date +%s)
  if env AETHER_TEST_BIN="$TEST_BIN" AETHER_TEST_SHA256="$TEST_SHA256" "$@" \
    >"$OUTPUT/$name.log" 2>&1; then
    result=PASS
  else
    result=FAIL
    failures=$((failures + 1))
  fi
  line="$result $name ($(( $(date +%s) - started ))s)"
  echo "$line"
  echo "$line" >>"$SUMMARY"
}

run_gate matrix \
  SING_BOX_BIN="$TOOLS/sing-box" SHADOW_TLS_BIN="$TOOLS/shadow-tls" \
  sh "$ROOT/Tests/Interop/run-prebuilt-matrix.sh"
run_gate reality \
  XRAY_BIN="$TOOLS/xray" \
  sh "$ROOT/Tests/Interop/run-prebuilt-reality.sh"
run_gate wireguard \
  WIREGUARD_GO_BIN="$TOOLS/wireguard-go-loopback-server" \
  WIREGUARD_GO_SHA256="$(shasum -a 256 "$TOOLS/wireguard-go-loopback-server" | awk '{print $1}')" \
  sh "$ROOT/Tests/Interop/run-prebuilt-wireguard.sh"
run_gate shadowquic \
  MIHOMO_ARCHIVE="$TOOLS/mihomo-darwin-arm64-v1.19.29.gz" \
  sh "$ROOT/Tests/Interop/run-prebuilt-shadowquic.sh"
run_gate ssh \
  sh "$ROOT/Tests/Interop/test-openssh.sh"

passed_cases=$(grep -c "interoperability and network reset passed" \
  "$OUTPUT/matrix.log" || true)
rejected=$(grep -c "rejects an untrusted certificate" "$OUTPUT/matrix.log" || true)
echo "matrix: $passed_cases case passes, $rejected certificate rejections" >>"$SUMMARY"

echo
cat "$SUMMARY"
if [ "$failures" -ne 0 ]; then
  echo "$failures protocol interop gate(s) failed; logs in $OUTPUT" >&2
  exit 1
fi
echo "All protocol interop gates passed; logs in $OUTPUT"
