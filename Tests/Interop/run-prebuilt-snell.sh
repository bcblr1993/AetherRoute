#!/bin/sh
set -eu

# Snell v1–v5 against Mihomo 1.19.29's Snell listeners, one per case in
# snell-cases.txt (version, http/tls obfs, v3+ UDP, v4 reuse). Two cycles
# check that a restarted server is reached again.
# TEST ONLY: Mihomo is a GPL-licensed independent process and must never be
# copied into an AetherRoute application bundle or release artifact.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MIHOMO_ARCHIVE=${MIHOMO_ARCHIVE:-$ROOT/mihomo-darwin-arm64-v1.19.29.gz}
TEST_BIN=${AETHER_TEST_BIN:-$ROOT/clash-lib-tests}
CONFIG=$ROOT/mihomo-snell-server.yaml
CASES=$ROOT/snell-cases.txt
EXPECTED_MIHOMO_SHA256=4dc25df9e899f14161911302a8ee5fc9e202ed9c976fc405bf82c50ff27466ca
EXPECTED_TEST_SHA256=${AETHER_TEST_SHA256:?set AETHER_TEST_SHA256 to the transferred test artifact checksum}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-snell.XXXXXX")
SERVER_PID=

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID"
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

verify_sha256() {
  expected=$1
  path=$2
  actual=$(shasum -a 256 "$path" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "checksum mismatch for $path: $actual" >&2
    exit 1
  fi
}

verify_sha256 "$EXPECTED_MIHOMO_SHA256" "$MIHOMO_ARCHIVE"
verify_sha256 "$EXPECTED_TEST_SHA256" "$TEST_BIN"
gzip -dc "$MIHOMO_ARCHIVE" >"$WORK_DIR/mihomo"
chmod 755 "$WORK_DIR/mihomo"
"$WORK_DIR/mihomo" -v | grep -F "Mihomo Meta v1.19.29 darwin arm64" >/dev/null

grep -F "allow-lan: false" "$CONFIG" >/dev/null
grep -F "bind-address: 127.0.0.1" "$CONFIG" >/dev/null
if grep -Eq '0\.0\.0\.0|listen:[[:space:]]*::|^[[:space:]]*tun:' "$CONFIG"; then
  echo "Mihomo Snell configuration is not loopback-only" >&2
  exit 1
fi
mkdir -p "$WORK_DIR/home"
if ! "$WORK_DIR/mihomo" -d "$WORK_DIR/home" -t -f "$CONFIG" >"$WORK_DIR/check.log" 2>&1; then
  cat "$WORK_DIR/check.log" >&2
  exit 1
fi

ports=$(grep -Ev '^[[:space:]]*(#|$)' "$CASES" | awk '{print $1}')

run_cycle() {
  cycle=$1
  echo "Prebuilt Snell cycle $cycle"
  "$WORK_DIR/mihomo" -d "$WORK_DIR/home" -f "$CONFIG" >"$WORK_DIR/mihomo.log" 2>&1 &
  SERVER_PID=$!
  for port in $ports; do
    attempt=0
    until lsof -nP -a -p "$SERVER_PID" -iTCP:"$port" -sTCP:LISTEN 2>/dev/null \
      | grep -F "127.0.0.1:$port" >/dev/null; do
      attempt=$((attempt + 1))
      if ! kill -0 "$SERVER_PID" 2>/dev/null || [ "$attempt" -ge 100 ]; then
        cat "$WORK_DIR/mihomo.log" >&2
        return 1
      fi
      sleep 0.05
    done
  done

  if ! AETHER_INTEROP_SNELL_CASES="$CASES" \
    AETHER_INTEROP_SNELL_PSK=snell-interop-psk \
    "$TEST_BIN" proxy::interop_tests::interoperates_with_snell_mihomo_server \
    --ignored --nocapture; then
    tail -n 40 "$WORK_DIR/mihomo.log" >&2
    return 1
  fi

  kill "$SERVER_PID"
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
}

run_cycle 1
run_cycle 2
echo "Prebuilt Snell gate passed: $(echo "$ports" | wc -l | tr -d ' ') cases"
