#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
XRAY_BIN=${XRAY_BIN:-$ROOT/xray}
TEST_BIN=${AETHER_TEST_BIN:-$ROOT/clash-lib-tests}
EXPECTED_XRAY_SHA256=${XRAY_SHA256:-5d9dd24c0aba4b6cfcc6a33a5d67f854816ee17f392bf932ec8176da46f7e404}
EXPECTED_TEST_SHA256=${AETHER_TEST_SHA256:?set AETHER_TEST_SHA256 to the transferred test artifact checksum}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-reality.XXXXXX")
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

verify_sha256 "$EXPECTED_XRAY_SHA256" "$XRAY_BIN"
verify_sha256 "$EXPECTED_TEST_SHA256" "$TEST_BIN"
"$XRAY_BIN" version | grep -F "Xray 26.3.27" >/dev/null
"$XRAY_BIN" run -test -config "$ROOT/xray-reality-server.json"

run_cycle() {
  cycle=$1
  echo "Prebuilt REALITY cycle $cycle"
  "$XRAY_BIN" run -config "$ROOT/xray-reality-server.json" >"$WORK_DIR/xray.log" 2>&1 &
  SERVER_PID=$!
  attempt=0
  while ! nc -z 127.0.0.1 59020 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
      cat "$WORK_DIR/xray.log" >&2
      return 1
    fi
    sleep 0.1
  done

  "$TEST_BIN" \
    proxy::interop_tests::interoperates_vless_reality_with_xray \
    --ignored --nocapture

  kill "$SERVER_PID"
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
}

run_cycle 1
run_cycle 2
echo "Prebuilt VLESS REALITY and restart gate passed"
