#!/bin/sh
set -eu

# Mieru (TCP, UDP, multiplexing, port-range) against Mihomo 1.19.29's Mieru
# listeners, one per case in mieru-cases.txt. Two cycles check that a restarted
# server is reached again.
# TEST ONLY: Mihomo is a GPL-licensed independent process and must never be
# copied into an AetherRoute application bundle or release artifact.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MIHOMO_ARCHIVE=${MIHOMO_ARCHIVE:-$ROOT/mihomo-darwin-arm64-v1.19.29.gz}
TEST_BIN=${AETHER_TEST_BIN:-$ROOT/clash-lib-tests}
CONFIG=$ROOT/mihomo-mieru-server.yaml
CASES=$ROOT/mieru-cases.txt
EXPECTED_MIHOMO_SHA256=4dc25df9e899f14161911302a8ee5fc9e202ed9c976fc405bf82c50ff27466ca
EXPECTED_TEST_SHA256=${AETHER_TEST_SHA256:?set AETHER_TEST_SHA256 to the transferred test artifact checksum}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-mieru.XXXXXX")
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
  echo "Mihomo Mieru configuration is not loopback-only" >&2
  exit 1
fi
mkdir -p "$WORK_DIR/home"
BASE_PORT=$(python3 -c '
import socket, sys
for base in range(39200, 39900, 5):
    ok = True
    for p in range(base, base + 5):
        for fam, addr in ((socket.AF_INET6, ("::", p)), (socket.AF_INET, ("127.0.0.1", p))):
            for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
                s = socket.socket(fam, kind)
                try:
                    if fam == socket.AF_INET6 and hasattr(socket, "IPV6_V6ONLY"):
                        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                    s.bind(addr)
                except OSError:
                    ok = False
                    break
                finally:
                    s.close()
            if not ok:
                break
        if not ok:
            break
    if ok:
        print(base)
        sys.exit(0)
sys.exit(1)
') || {
  echo "could not find a free contiguous 5-port Mieru range in 39200..39899" >&2
  exit 1
}

P0=$BASE_PORT
P1=$((BASE_PORT + 1))
P2=$((BASE_PORT + 2))
P3=$((BASE_PORT + 3))
P4=$((BASE_PORT + 4))

sed \
  -e "s/39200/$P0/g" \
  -e "s/39201/$P1/g" \
  -e "s/39202/$P2/g" \
  -e "s/39203/$P3/g" \
  -e "s/39204/$P4/g" \
  "$CONFIG" >"$WORK_DIR/server.yaml"
sed \
  -e "s/39200/$P0/g" \
  -e "s/39201/$P1/g" \
  -e "s/39202/$P2/g" \
  -e "s/39203/$P3/g" \
  -e "s/39204/$P4/g" \
  "$CASES" >"$WORK_DIR/cases.txt"

if ! "$WORK_DIR/mihomo" -d "$WORK_DIR/home" -t -f "$WORK_DIR/server.yaml" >"$WORK_DIR/check.log" 2>&1; then
  cat "$WORK_DIR/check.log" >&2
  exit 1
fi

run_cycle() {
  cycle=$1
  echo "Prebuilt Mieru cycle $cycle"
  "$WORK_DIR/mihomo" -d "$WORK_DIR/home" -f "$WORK_DIR/server.yaml" >"$WORK_DIR/mihomo.log" 2>&1 &
  SERVER_PID=$!
  for port in "$P0" "$P2" "$P3" "$P4"; do
    attempt=0
    until lsof -nP -a -p "$SERVER_PID" -iTCP:"$port" -sTCP:LISTEN 2>/dev/null \
      | grep -F ":$port" >/dev/null; do
      attempt=$((attempt + 1))
      if ! kill -0 "$SERVER_PID" 2>/dev/null || [ "$attempt" -ge 100 ]; then
        cat "$WORK_DIR/mihomo.log" >&2
        return 1
      fi
      sleep 0.05
    done
  done

  if ! AETHER_INTEROP_MIERU_CASES="$WORK_DIR/cases.txt" \
    AETHER_INTEROP_MIERU_USERNAME=mieru-user \
    AETHER_INTEROP_MIERU_PASSWORD=mieru-pass \
    "$TEST_BIN" proxy::interop_tests::interoperates_with_mieru_mihomo_server \
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
echo "Prebuilt Mieru gate passed: $(grep -Evc '^[[:space:]]*(#|$)' "$WORK_DIR/cases.txt" | tr -d ' ') cases"
