#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CORE_ROOT=${AETHER_CORE_ROOT:-$ROOT/../references/clash-rs}
TEST_BIN=${AETHER_TEST_BIN:-}
EXPECTED_TEST_SHA256=${AETHER_TEST_SHA256:-}
SSH_PORT=${AETHER_INTEROP_SSH_PORT:-59030}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-openssh.XXXXXX")
SERVER_PID=

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID"
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

if nc -z 127.0.0.1 "$SSH_PORT" 2>/dev/null; then
  echo "loopback SSH test port $SSH_PORT is already in use" >&2
  exit 1
fi

ssh-keygen -q -t ed25519 -N "" -f "$WORK_DIR/host_key"
PRIVATE_KEY_PASSPHRASE=${AETHER_INTEROP_SSH_PRIVATE_KEY_TEST_PASSPHRASE-aetherroute-interop-passphrase}
ssh-keygen -q -t ed25519 -N "" -f "$WORK_DIR/client_key"
cp "$WORK_DIR/client_key.pub" "$WORK_DIR/authorized_keys"
chmod 600 \
  "$WORK_DIR/host_key" \
  "$WORK_DIR/client_key" \
  "$WORK_DIR/authorized_keys"

USER_NAME=$(id -un)
HOST_KEY=$(awk '{print $1 " " $2}' "$WORK_DIR/host_key.pub")
sed \
  -e "s|__PORT__|$SSH_PORT|g" \
  -e "s|__WORK_DIR__|$WORK_DIR|g" \
  -e "s|__USER__|$USER_NAME|g" \
  "$ROOT/Tests/Interop/sshd_config.template" \
  >"$WORK_DIR/sshd_config"

run_test() {
  if [ -n "$TEST_BIN" ]; then
    if [ -z "$EXPECTED_TEST_SHA256" ]; then
      echo "set AETHER_TEST_SHA256 for the prebuilt test binary" >&2
      return 1
    fi
    actual=$(shasum -a 256 "$TEST_BIN" | awk '{print $1}')
    if [ "$actual" != "$EXPECTED_TEST_SHA256" ]; then
      echo "test binary checksum mismatch: $actual" >&2
      return 1
    fi
    "$TEST_BIN" \
      proxy::interop_tests::interoperates_with_openssh \
      --ignored --nocapture
  else
    (
      cd "$CORE_ROOT"
      cargo test \
        --locked \
        -p clash-lib \
        --no-default-features \
        --features aether-embedded,aether-tuic,aws-lc-rs,shadowquic,shadowsocks,ssh,tun,wireguard,zero_copy \
        proxy::interop_tests::interoperates_with_openssh \
        -- --ignored --nocapture
    )
  fi
}

run_cycle() {
  cycle=$1
  echo "OpenSSH interop cycle $cycle"
  /usr/sbin/sshd -D -f "$WORK_DIR/sshd_config" -E "$WORK_DIR/sshd.log" &
  SERVER_PID=$!
  attempt=0
  while ! nc -z 127.0.0.1 "$SSH_PORT" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
      cat "$WORK_DIR/sshd.log" >&2
      return 1
    fi
    sleep 0.1
  done

  if [ "$cycle" -eq 1 ]; then
    if ! /usr/bin/ssh \
      -F /dev/null \
      -p "$SSH_PORT" \
      -i "$WORK_DIR/client_key" \
      -o BatchMode=yes \
      -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      "$USER_NAME@127.0.0.1" true >/dev/null 2>&1; then
      echo "OpenSSH native-client preflight failed for cycle $cycle:" >&2
      cat "$WORK_DIR/sshd.log" >&2
      return 1
    fi
    if [ -n "$PRIVATE_KEY_PASSPHRASE" ]; then
      ssh-keygen -q -p -P "" -N "$PRIVATE_KEY_PASSPHRASE" \
        -f "$WORK_DIR/client_key"
    fi
  fi

  if ! AETHER_INTEROP_SSH_PORT=$SSH_PORT \
    AETHER_INTEROP_SSH_USERNAME=$USER_NAME \
    AETHER_INTEROP_SSH_PRIVATE_KEY=$WORK_DIR/client_key \
    AETHER_INTEROP_SSH_PRIVATE_KEY_PASSPHRASE=$PRIVATE_KEY_PASSPHRASE \
    AETHER_INTEROP_SSH_HOST_KEY=$HOST_KEY \
    run_test; then
    echo "OpenSSH server log for failed cycle $cycle:" >&2
    cat "$WORK_DIR/sshd.log" >&2
    return 1
  fi

  kill "$SERVER_PID"
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
}

run_cycle 1
run_cycle 2
echo "OpenSSH interoperability and restart gate passed"
