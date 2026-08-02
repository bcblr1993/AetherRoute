#!/bin/sh
set -eu
umask 077

if [ "$#" -ne 2 ]; then
  echo "usage: $0 SOURCE_ROOT EVIDENCE_DIRECTORY" >&2
  exit 64
fi

ROOT=$1
EVIDENCE=$2
INTEROP="$ROOT/Tests/Interop"
mkdir -p "$EVIDENCE"

network_control_hash() {
  {
    /usr/sbin/scutil --proxy
    /usr/sbin/scutil --dns
    /usr/sbin/netstat -rn -f inet | awk '$1 == "default" {print}'
    /usr/sbin/netstat -rn -f inet6 | awk '$1 == "default" {print}'
    /sbin/ifconfig -l
  } | shasum -a 256 | awk '{print $1}'
}

source_hash() {
  find "$ROOT" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    shasum -a 256 "$file"
  done | shasum -a 256 | awk '{print $1}'
}

network_before=$(network_control_hash)
source_before=$(source_hash)
started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
test_status=1

finish() {
  exit_status=$?
  network_after=$(network_control_hash)
  source_after=$(source_hash)
  network_unchanged=false
  source_unchanged=false
  test "$network_before" = "$network_after" && network_unchanged=true
  test "$source_before" = "$source_after" && source_unchanged=true
  {
    printf 'started_at=%s\n' "$started_at"
    printf 'finished_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'test_status=%s\n' "$test_status"
    printf 'network_control_before_sha256=%s\n' "$network_before"
    printf 'network_control_after_sha256=%s\n' "$network_after"
    printf 'network_unchanged=%s\n' "$network_unchanged"
    printf 'source_before_sha256=%s\n' "$source_before"
    printf 'source_after_sha256=%s\n' "$source_after"
    printf 'source_unchanged=%s\n' "$source_unchanged"
  } > "$EVIDENCE/result.env"
  test "$network_unchanged" = true || exit_status=1
  test "$source_unchanged" = true || exit_status=1
  if [ "$exit_status" -ne 0 ]; then
    echo "Remote protocol interoperability failed; evidence follows:" >&2
    cat "$EVIDENCE/result.env" >&2
  fi
}
trap finish EXIT HUP INT TERM

test "$(uname -m)" = arm64
test_bin="$INTEROP/clash-lib-tests"
test_sha=$(shasum -a 256 "$test_bin" | awk '{print $1}')
test "$test_sha" = b964b5724d0f553037600c45415ed0f78fc448da2f216fa234f259b3ec0895fa

env \
  AETHER_TEST_BIN="$test_bin" \
  AETHER_TEST_SHA256="$test_sha" \
  SING_BOX_BIN="$INTEROP/sing-box" \
  SHADOW_TLS_BIN="$INTEROP/shadow-tls" \
  AETHER_INTEROP_CYCLES=2 \
  "$INTEROP/run-prebuilt-matrix.sh" \
  > "$EVIDENCE/sing-box-matrix.log" 2>&1

env \
  AETHER_TEST_BIN="$test_bin" \
  AETHER_TEST_SHA256="$test_sha" \
  XRAY_BIN="$INTEROP/xray" \
  "$INTEROP/run-prebuilt-reality.sh" \
  > "$EVIDENCE/xray-reality.log" 2>&1

wireguard_sha=$(shasum -a 256 "$INTEROP/wireguard-go-loopback-server" \
  | awk '{print $1}')
env \
  AETHER_TEST_BIN="$test_bin" \
  AETHER_TEST_SHA256="$test_sha" \
  WIREGUARD_GO_BIN="$INTEROP/wireguard-go-loopback-server" \
  WIREGUARD_GO_SHA256="$wireguard_sha" \
  AETHER_INTEROP_CYCLES=2 \
  AETHER_INTEROP_WIREGUARD_HANDLER_CYCLES=3 \
  "$INTEROP/run-prebuilt-wireguard.sh" \
  > "$EVIDENCE/wireguard-go.log" 2>&1

env \
  AETHER_TEST_BIN="$test_bin" \
  AETHER_TEST_SHA256="$test_sha" \
  "$INTEROP/test-openssh.sh" \
  > "$EVIDENCE/openssh.log" 2>&1

env \
  AETHER_TEST_BIN="$test_bin" \
  AETHER_TEST_SHA256="$test_sha" \
  MIHOMO_ARCHIVE="$INTEROP/mihomo-darwin-arm64-v1.19.29.gz" \
  AETHER_INTEROP_CYCLES=2 \
  "$INTEROP/run-prebuilt-shadowquic.sh" \
  > "$EVIDENCE/mihomo-shadowquic.log" 2>&1

test_status=0
printf '%s\n' \
  'Remote independent interoperability passed: protocols=12 matrix_cases=21 independent_cases=4 restart_cycles=2 network_unchanged=true'
