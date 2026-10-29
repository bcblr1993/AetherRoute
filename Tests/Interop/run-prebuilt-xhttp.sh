#!/bin/sh
set -eu

# VLESS over xhttp against Xray: TLS, REALITY and plaintext inbounds, each in
# mode auto so every client mode (packet-up, stream-up, stream-one) is
# accepted. Two cycles check that a restarted server is reached again.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
XRAY_BIN=${XRAY_BIN:-$ROOT/xray}
TEST_BIN=${AETHER_TEST_BIN:-$ROOT/clash-lib-tests}
EXPECTED_XRAY_SHA256=${XRAY_SHA256:-5d9dd24c0aba4b6cfcc6a33a5d67f854816ee17f392bf932ec8176da46f7e404}
EXPECTED_TEST_SHA256=${AETHER_TEST_SHA256:?set AETHER_TEST_SHA256 to the transferred test artifact checksum}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-xhttp.XXXXXX")
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

AETHER_INTEROP_CERT_FINGERPRINT=$(sh "$ROOT/make-test-pki.sh" "$WORK_DIR")
AETHER_INTEROP_CA_FILE=$WORK_DIR/ca.pem
export AETHER_INTEROP_CERT_FINGERPRINT AETHER_INTEROP_CA_FILE
sed \
  -e "s|__CERT__|$WORK_DIR/cert.pem|g" \
  -e "s|__KEY__|$WORK_DIR/key.pem|g" \
  "$ROOT/xray-xhttp-server.json.template" \
  >"$WORK_DIR/server.json"
"$XRAY_BIN" run -test -config "$WORK_DIR/server.json" >/dev/null

run_cycle() {
  cycle=$1
  echo "Prebuilt xhttp cycle $cycle"
  "$XRAY_BIN" run -config "$WORK_DIR/server.json" >"$WORK_DIR/xray.log" 2>&1 &
  SERVER_PID=$!
  for port in 59080 59081 59082; do
    attempt=0
    while ! nc -z 127.0.0.1 "$port" 2>/dev/null; do
      attempt=$((attempt + 1))
      if [ "$attempt" -ge 50 ]; then
        cat "$WORK_DIR/xray.log" >&2
        return 1
      fi
      sleep 0.1
    done
  done

  if ! "$TEST_BIN" \
    proxy::interop_tests::interoperates_vless_xhttp_with_xray \
    --ignored --nocapture; then
    cat "$WORK_DIR/xray.log" >&2
    return 1
  fi

  kill "$SERVER_PID"
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
}

run_cycle 1
run_cycle 2
echo "Prebuilt VLESS xhttp gate passed"
