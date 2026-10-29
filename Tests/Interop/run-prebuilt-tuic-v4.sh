#!/bin/sh
set -eu

# TEST ONLY: tuic-server is a GPL-3.0-licensed independent process and must
# never be copied into an AetherRoute application bundle or release artifact.
# Two server cycles verify TUIC v4 (version: 4, BLAKE3 token digest, TCP,
# native/QUIC UDP, reduce-rtt, cert pinning, and untrusted cert rejection).
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TUIC_V4_BIN=${TUIC_V4_BIN:-$ROOT/tuic-server-v4}
TEST_BIN=${AETHER_TEST_BIN:-$ROOT/clash-lib-tests}
EXPECTED_TUIC_V4_SHA256=${TUIC_V4_SHA256:-34db3ad8470245de4c69a7ded438c96b263a1338443634cf4b0cdeeea8a9106a}
EXPECTED_TEST_SHA256=${AETHER_TEST_SHA256:?set AETHER_TEST_SHA256 to the transferred test artifact checksum}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-tuic-v4.XXXXXX")
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

verify_sha256 "$EXPECTED_TUIC_V4_SHA256" "$TUIC_V4_BIN"
verify_sha256 "$EXPECTED_TEST_SHA256" "$TEST_BIN"
"$TUIC_V4_BIN" --version | grep -F "0.8.5" >/dev/null

AETHER_INTEROP_CERT_FINGERPRINT=$(sh "$ROOT/make-test-pki.sh" "$WORK_DIR")
AETHER_INTEROP_CA_FILE=$WORK_DIR/ca.pem
export AETHER_INTEROP_CERT_FINGERPRINT AETHER_INTEROP_CA_FILE

run_cycle() {
  cycle=$1
  echo "Prebuilt tuic-v4 cycle $cycle"
  "$TUIC_V4_BIN" \
    --port 59090 \
    --ip 127.0.0.1 \
    --token tuic-v4-interop-token \
    --certificate "$WORK_DIR/cert.pem" \
    --private-key "$WORK_DIR/key.pem" \
    --alpn h3 \
    --max-idle-time 15000 \
    --authentication-timeout 3000 \
    --log-level info \
    >"$WORK_DIR/tuic-v4.log" 2>&1 &
  SERVER_PID=$!

  attempt=0
  while ! grep -F "Server started. Listening: 127.0.0.1:59090" "$WORK_DIR/tuic-v4.log" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if ! kill -0 "$SERVER_PID" 2>/dev/null || [ "$attempt" -ge 50 ]; then
      cat "$WORK_DIR/tuic-v4.log" >&2
      return 1
    fi
    sleep 0.1
  done

  binding=$(lsof -nP -a -p "$SERVER_PID" -iUDP:59090)
  echo "$binding" | grep -F "UDP 127.0.0.1:59090" >/dev/null
  if echo "$binding" | grep -Eq '\*:59090|0\.0\.0\.0:59090|\[::\]:59090'; then
    echo "tuic-server-v4 opened a non-loopback socket" >&2
    echo "$binding" >&2
    return 1
  fi

  if ! "$TEST_BIN" \
    proxy::interop_tests::interoperates_tuic_v4_with_tuic_server \
    --ignored --nocapture; then
    cat "$WORK_DIR/tuic-v4.log" >&2
    return 1
  fi

  kill "$SERVER_PID"
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
}

run_cycle 1
run_cycle 2
echo "Prebuilt TUIC v4 gate passed"
