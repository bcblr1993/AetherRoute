#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SING_BOX_BIN=${SING_BOX_BIN:-$ROOT/sing-box}
SHADOW_TLS_BIN=${SHADOW_TLS_BIN:-$ROOT/shadow-tls}
TEST_BIN=${AETHER_TEST_BIN:-$ROOT/clash-lib-tests}
TEST_FILTER=${AETHER_INTEROP_TEST_FILTER:-proxy::interop_tests::interoperates_with_sing_box_protocol_matrix}
CYCLES=${AETHER_INTEROP_CYCLES:-2}
EXPECTED_SING_BOX_SHA256=${SING_BOX_SHA256:-89629d674086064d2211c2cdb5715635e231c81f1bd47c23ab379da698d892f2}
EXPECTED_SHADOW_TLS_SHA256=${SHADOW_TLS_SHA256:-a7c39d70cfc5868f654b19766b768518413ac4ffd9532ea8534a36a1d447b5b1}
EXPECTED_TEST_SHA256=${AETHER_TEST_SHA256:?set AETHER_TEST_SHA256 to the transferred test artifact checksum}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-prebuilt-interop.XXXXXX")
SERVER_PID=
SHADOW_TLS_PID=

case $CYCLES in
  ''|*[!0-9]*)
    echo "AETHER_INTEROP_CYCLES must be a positive integer" >&2
    exit 1
    ;;
esac
if [ "$CYCLES" -lt 1 ] || [ "$CYCLES" -gt 1000 ]; then
  echo "AETHER_INTEROP_CYCLES must be between 1 and 1000" >&2
  exit 1
fi

cleanup() {
  if [ -n "$SHADOW_TLS_PID" ] && kill -0 "$SHADOW_TLS_PID" 2>/dev/null; then
    kill "$SHADOW_TLS_PID"
    wait "$SHADOW_TLS_PID" 2>/dev/null || true
  fi
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

verify_sha256 "$EXPECTED_SING_BOX_SHA256" "$SING_BOX_BIN"
verify_sha256 "$EXPECTED_SHADOW_TLS_SHA256" "$SHADOW_TLS_BIN"
verify_sha256 "$EXPECTED_TEST_SHA256" "$TEST_BIN"
"$SING_BOX_BIN" version | grep -F "sing-box version 1.13.15" >/dev/null
"$SHADOW_TLS_BIN" --version | grep -F "shadow-tls 0.2.25" >/dev/null

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj /CN=localhost \
  -keyout "$WORK_DIR/key.pem" \
  -out "$WORK_DIR/cert.pem" >/dev/null 2>&1
sed \
  -e "s|__CERT__|$WORK_DIR/cert.pem|g" \
  -e "s|__KEY__|$WORK_DIR/key.pem|g" \
  "$ROOT/sing-box-server.json.template" \
  >"$WORK_DIR/server.json"
"$SING_BOX_BIN" check -c "$WORK_DIR/server.json"

run_cycle() {
  cycle=$1
  echo "Prebuilt interop cycle $cycle"
  "$SING_BOX_BIN" run -c "$WORK_DIR/server.json" >"$WORK_DIR/server.log" 2>&1 &
  SERVER_PID=$!
  attempt=0
  while ! nc -z 127.0.0.1 59000 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
      cat "$WORK_DIR/server.log" >&2
      return 1
    fi
    sleep 0.1
  done

  RUST_LOG=error "$SHADOW_TLS_BIN" --v3 server \
    --listen 127.0.0.1:59021 \
    --server 127.0.0.1:59002 \
    --tls www.feishu.cn:443 \
    --password shadowtls-password \
    >"$WORK_DIR/shadow-tls.log" 2>&1 &
  SHADOW_TLS_PID=$!
  attempt=0
  while ! lsof -nP -a -p "$SHADOW_TLS_PID" -iTCP:59021 -sTCP:LISTEN \
    2>/dev/null | grep -F "127.0.0.1:59021" >/dev/null; do
    attempt=$((attempt + 1))
    if ! kill -0 "$SHADOW_TLS_PID" 2>/dev/null || [ "$attempt" -ge 50 ]; then
      cat "$WORK_DIR/shadow-tls.log" >&2
      return 1
    fi
    sleep 0.1
  done
  binding=$(lsof -nP -a -p "$SHADOW_TLS_PID" -iTCP:59021 -sTCP:LISTEN)
  if echo "$binding" | grep -Eq '\*:59021|0\.0\.0\.0:59021|\[::\]:59021'; then
    echo "ShadowTLS opened a non-loopback listener" >&2
    echo "$binding" >&2
    return 1
  fi

  if ! "$TEST_BIN" "$TEST_FILTER" --ignored --nocapture; then
    echo "sing-box log for failed cycle $cycle:" >&2
    tail -200 "$WORK_DIR/server.log" >&2
    return 1
  fi

  kill "$SHADOW_TLS_PID"
  wait "$SHADOW_TLS_PID" 2>/dev/null || true
  SHADOW_TLS_PID=
  kill "$SERVER_PID"
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
}

cycle=1
while [ "$cycle" -le "$CYCLES" ]; do
  run_cycle "$cycle"
  cycle=$((cycle + 1))
done
echo "Prebuilt protocol interoperability and restart gate passed: cycles=$CYCLES"
