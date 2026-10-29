#!/bin/sh
set -eu

# ShadowsocksR interoperability against the Apache-2.0 Python server
# (shadowsocksrr/shadowsocksr, akkariiin/dev at b365980), one process per
# line of ssr-cases.txt, all on 127.0.0.1. TEST ONLY: the server is never
# copied into the application. The server refuses loopback targets by
# default; the echo target is on loopback, so the forbidden list is set to a
# documentation address instead.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ARCHIVE=${SSR_ARCHIVE:?set SSR_ARCHIVE to the pinned shadowsocksr source archive}
EXPECTED_ARCHIVE_SHA256=63f1578f0efbfccc3f82d684bbf0ada276d5c04c6b8aad33f0e9d9e4d8573a3f
TEST_BIN=${AETHER_TEST_BIN:?set AETHER_TEST_BIN}
EXPECTED_TEST_SHA256=${AETHER_TEST_SHA256:?set AETHER_TEST_SHA256}
CASES="$ROOT/ssr-cases.txt"
PASSWORD=ssr-interop-password
TEST_FILTER=proxy::interop_tests::interoperates_with_ssr_python_server
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-prebuilt-ssr.XXXXXX")
PIDS=

cleanup() {
  for pid in $PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  find "$WORK_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

verify_sha256() {
  actual=$(shasum -a 256 "$2" | awk '{print $1}')
  if [ "$actual" != "$1" ]; then
    echo "checksum mismatch for $2: $actual" >&2
    exit 1
  fi
}

verify_sha256 "$EXPECTED_ARCHIVE_SHA256" "$ARCHIVE"
verify_sha256 "$EXPECTED_TEST_SHA256" "$TEST_BIN"
mkdir "$WORK_DIR/src"
tar -xzf "$ARCHIVE" -C "$WORK_DIR/src" --strip-components 1
OPENSSL_LIB=$(brew --prefix openssl@3)/lib
# RC4 (rc4-md5, and auth_chain's payload cipher) is in OpenSSL 3's legacy
# provider, which is off by default; enable it for these test servers only.
cat >"$WORK_DIR/openssl-legacy.cnf" <<'CNF'
openssl_conf = openssl_init
[openssl_init]
providers = provider_sect
[provider_sect]
default = default_sect
legacy = legacy_sect
[default_sect]
activate = 1
[legacy_sect]
activate = 1
CNF

grep -Ev '^[[:space:]]*(#|$)' "$CASES" >"$WORK_DIR/cases"
while read -r port cipher protocol obfs; do
  OPENSSL_CONF="$WORK_DIR/openssl-legacy.cnf" OPENSSL_MODULES="$OPENSSL_LIB/ossl-modules" \
  DYLD_LIBRARY_PATH="$OPENSSL_LIB" python3 "$WORK_DIR/src/shadowsocks/server.py" \
    -s 127.0.0.1 -p "$port" -k "$PASSWORD" -m "$cipher" -O "$protocol" -o "$obfs" \
    --forbidden-ip 192.0.2.1/32 \
    >"$WORK_DIR/server-$port.log" 2>&1 &
  PIDS="$PIDS $!"
done <"$WORK_DIR/cases"

while read -r port cipher protocol obfs; do
  attempt=0
  while ! lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -F "127.0.0.1:$port" >/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
      echo "SSR server $port ($cipher $protocol $obfs) did not start" >&2
      cat "$WORK_DIR/server-$port.log" >&2
      exit 1
    fi
    sleep 0.1
  done
done <"$WORK_DIR/cases"

AETHER_INTEROP_SSR_CASES="$WORK_DIR/cases" AETHER_INTEROP_SSR_PASSWORD="$PASSWORD" \
  "$TEST_BIN" "$TEST_FILTER" --ignored --nocapture
echo "Prebuilt SSR gate passed: $(wc -l <"$WORK_DIR/cases" | tr -d ' ') combinations"
