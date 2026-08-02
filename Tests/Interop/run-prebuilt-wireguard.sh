#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WIREGUARD_GO_BIN=${WIREGUARD_GO_BIN:-$ROOT/wireguard-go-loopback-server}
TEST_BIN=${AETHER_TEST_BIN:-$ROOT/clash-lib-tests}
EXPECTED_WIREGUARD_GO_SHA256=${WIREGUARD_GO_SHA256:?set WIREGUARD_GO_SHA256 to the transferred helper checksum}
EXPECTED_TEST_SHA256=${AETHER_TEST_SHA256:?set AETHER_TEST_SHA256 to the transferred test artifact checksum}
ENDPOINT_PORT=${AETHER_INTEROP_WIREGUARD_PORT:-59040}
TCP_PORT=${AETHER_INTEROP_WIREGUARD_TCP_PORT:-59041}
UDP_PORT=${AETHER_INTEROP_WIREGUARD_UDP_PORT:-59042}
HANDLER_CYCLES=${AETHER_INTEROP_WIREGUARD_HANDLER_CYCLES:-3}
CYCLES=${AETHER_INTEROP_CYCLES:-2}
TEST_FILTER=proxy::interop_tests::interoperates_wireguard_with_wireguard_go_netstack
EXPECTED_VERSION=v0.0.0-20250521234502-f333402bd9cb
EXPECTED_REVISION=f333402bd9cbe0f3eeb02507bd14e23d7d639280
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-wireguard-interop.XXXXXX")
SERVER_PID=

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID"
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

positive_integer() {
  name=$1
  value=$2
  maximum=$3
  case $value in
    ''|*[!0-9]*)
      echo "$name must be a positive integer" >&2
      exit 1
      ;;
  esac
  if [ "$value" -lt 1 ] || [ "$value" -gt "$maximum" ]; then
    echo "$name must be between 1 and $maximum" >&2
    exit 1
  fi
}

verify_sha256() {
  expected=$1
  path=$2
  actual=$(shasum -a 256 "$path" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "checksum mismatch for $path: $actual" >&2
    exit 1
  fi
}

positive_integer AETHER_INTEROP_WIREGUARD_PORT "$ENDPOINT_PORT" 65535
positive_integer AETHER_INTEROP_WIREGUARD_TCP_PORT "$TCP_PORT" 65535
positive_integer AETHER_INTEROP_WIREGUARD_UDP_PORT "$UDP_PORT" 65535
positive_integer AETHER_INTEROP_WIREGUARD_HANDLER_CYCLES "$HANDLER_CYCLES" 100
positive_integer AETHER_INTEROP_CYCLES "$CYCLES" 1000
if [ "$TCP_PORT" = "$UDP_PORT" ]; then
  echo "WireGuard virtual TCP and UDP echo ports must differ" >&2
  exit 1
fi

verify_sha256 "$EXPECTED_WIREGUARD_GO_SHA256" "$WIREGUARD_GO_BIN"
verify_sha256 "$EXPECTED_TEST_SHA256" "$TEST_BIN"
"$WIREGUARD_GO_BIN" -version \
  | grep -F "wireguard-go $EXPECTED_VERSION revision $EXPECTED_REVISION" >/dev/null

run_cycle() {
  cycle=$1
  server_log=$WORK_DIR/wireguard-go-$cycle.log
  client_log=$WORK_DIR/clash-lib-$cycle.log
  echo "WireGuard wireguard-go/gVisor cold-start cycle $cycle"
  "$WIREGUARD_GO_BIN" \
    -listen-port "$ENDPOINT_PORT" \
    -tcp-port "$TCP_PORT" \
    -udp-port "$UDP_PORT" \
    >"$server_log" 2>&1 &
  SERVER_PID=$!

  attempt=0
  while ! grep -F "READY wireguard-go=$EXPECTED_VERSION endpoint=127.0.0.1:$ENDPOINT_PORT" "$server_log" >/dev/null 2>&1; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      cat "$server_log" >&2
      echo "wireguard-go loopback server exited before readiness" >&2
      return 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
      cat "$server_log" >&2
      echo "wireguard-go loopback server readiness timed out" >&2
      return 1
    fi
    sleep 0.1
  done

  if AETHER_INTEROP_WIREGUARD_PORT=$ENDPOINT_PORT \
    AETHER_INTEROP_WIREGUARD_TCP_PORT=$TCP_PORT \
    AETHER_INTEROP_WIREGUARD_UDP_PORT=$UDP_PORT \
    AETHER_INTEROP_WIREGUARD_HANDLER_CYCLES=$HANDLER_CYCLES \
    "$TEST_BIN" "$TEST_FILTER" --exact --ignored --nocapture --test-threads=1 \
    >"$client_log" 2>&1; then
    test_status=0
  else
    test_status=$?
  fi
  cat "$client_log"

  if [ "$test_status" -ne 0 ] || grep -F "panicked at" "$client_log" >/dev/null; then
    echo "wireguard-go server log for failed cycle $cycle:" >&2
    tail -200 "$server_log" >&2
    echo "clash-lib WireGuard log for failed cycle $cycle:" >&2
    tail -200 "$client_log" >&2
    return 1
  fi

  kill "$SERVER_PID"
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
}

cycle=1
while [ "$cycle" -le "$CYCLES" ]; do
  run_cycle "$cycle"
  cycle=$((cycle + 1))
done

echo "WireGuard independent TCP/UDP, handler-destroy/reconnect, and server-restart gate passed: server_cycles=$CYCLES handler_cycles=$HANDLER_CYCLES"
