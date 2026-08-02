#!/bin/sh
set -eu

# TEST ONLY: Mihomo is a GPL-licensed independent process and must never be
# copied into an AetherRoute application bundle or release artifact.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_ROOT=${AETHER_CORE_ROOT:?set AETHER_CORE_ROOT to the audited clash-rs fork}
MIHOMO_ARCHIVE=${MIHOMO_ARCHIVE:?set MIHOMO_ARCHIVE to mihomo-darwin-arm64-v1.19.29.gz}
CONFIG=$ROOT/Tests/Interop/mihomo-shadowquic-server.yaml
EXPECTED_MIHOMO_SHA256=4dc25df9e899f14161911302a8ee5fc9e202ed9c976fc405bf82c50ff27466ca
TEST_FILTER=proxy::interop_tests::interoperates_shadowquic_with_mihomo_and_recovers_after_restart
CYCLES=${AETHER_INTEROP_CYCLES:-2}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-shadowquic.XXXXXX")
PREFLIGHT_PID=

cleanup() {
  if [ -n "$PREFLIGHT_PID" ] && kill -0 "$PREFLIGHT_PID" 2>/dev/null; then
    kill "$PREFLIGHT_PID"
    wait "$PREFLIGHT_PID" 2>/dev/null || true
  fi
  find "$WORK_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

case $CYCLES in
  ''|*[!0-9]*)
    echo "AETHER_INTEROP_CYCLES must be a positive integer" >&2
    exit 1
    ;;
esac
if [ "$CYCLES" -lt 1 ] || [ "$CYCLES" -gt 100 ]; then
  echo "AETHER_INTEROP_CYCLES must be between 1 and 100" >&2
  exit 1
fi
if [ "$(uname -m)" != arm64 ]; then
  echo "ShadowQUIC interoperability requires an Apple Silicon host" >&2
  exit 1
fi

actual_sha256=$(shasum -a 256 "$MIHOMO_ARCHIVE" | awk '{print $1}')
if [ "$actual_sha256" != "$EXPECTED_MIHOMO_SHA256" ]; then
  echo "Mihomo archive checksum mismatch: $actual_sha256" >&2
  exit 1
fi
gzip -dc "$MIHOMO_ARCHIVE" >"$WORK_DIR/mihomo"
chmod 755 "$WORK_DIR/mihomo"
"$WORK_DIR/mihomo" -v | grep -F "Mihomo Meta v1.19.29 darwin arm64" >/dev/null

grep -F "allow-lan: false" "$CONFIG" >/dev/null
grep -F "bind-address: 127.0.0.1" "$CONFIG" >/dev/null
grep -F "listen: 127.0.0.1" "$CONFIG" >/dev/null
grep -F "port: 59030" "$CONFIG" >/dev/null
if grep -Eq '0\.0\.0\.0|listen:[[:space:]]*::|^[[:space:]]*tun:' "$CONFIG"; then
  echo "Mihomo ShadowQUIC configuration is not loopback-only" >&2
  exit 1
fi

mkdir -p "$WORK_DIR/preflight-home"
"$WORK_DIR/mihomo" -d "$WORK_DIR/preflight-home" -t -f "$CONFIG"
"$WORK_DIR/mihomo" \
  -d "$WORK_DIR/preflight-home" \
  -f "$CONFIG" >"$WORK_DIR/preflight.log" 2>&1 &
PREFLIGHT_PID=$!
attempt=0
while ! grep -F "proxy listening at: 127.0.0.1:59030" "$WORK_DIR/preflight.log" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if ! kill -0 "$PREFLIGHT_PID" 2>/dev/null || [ "$attempt" -ge 100 ]; then
    cat "$WORK_DIR/preflight.log" >&2
    exit 1
  fi
  sleep 0.05
done
binding=$(lsof -nP -a -p "$PREFLIGHT_PID" -iUDP:59030)
echo "$binding" | grep -F "UDP 127.0.0.1:59030" >/dev/null
if echo "$binding" | grep -Eq '\*:59030|0\.0\.0\.0:59030|\[::\]:59030'; then
  echo "Mihomo opened a non-loopback ShadowQUIC socket" >&2
  echo "$binding" >&2
  exit 1
fi
kill "$PREFLIGHT_PID"
wait "$PREFLIGHT_PID" 2>/dev/null || true
PREFLIGHT_PID=

cycle=1
while [ "$cycle" -le "$CYCLES" ]; do
  echo "ShadowQUIC independent interoperability cycle $cycle"
  (
    cd "$CORE_ROOT"
    AETHER_INTEROP_MIHOMO_BIN="$WORK_DIR/mihomo" \
    AETHER_INTEROP_MIHOMO_CONFIG="$CONFIG" \
      cargo test \
        --locked \
        -p clash-lib \
        --no-default-features \
        --features aether-tuic,aws-lc-rs,shadowquic,shadowsocks,ssh,tun,wireguard,zero_copy \
        "$TEST_FILTER" \
        -- --ignored --nocapture
  )
  cycle=$((cycle + 1))
done

echo "ShadowQUIC independent TCP/UDP/reconnect/restart gate passed: cycles=$CYCLES"
