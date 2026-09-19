#!/bin/sh
set -eu

BASE=${1:-}
MODE=${2:-fast}

base_prefix=/tmp/aetherroute-remote-gate.
base_suffix=${BASE#"$base_prefix"}
if [ "$BASE" = "$base_suffix" ]; then
  echo "Unsafe remote gate directory: $BASE" >&2
  exit 64
fi
case "$base_suffix" in
  ''|*[!A-Za-z0-9]*)
    echo "Unsafe remote gate directory: $BASE" >&2
    exit 64
    ;;
esac
case "$MODE" in
  fast|full) ;;
  *)
    echo "Remote gate mode must be fast or full" >&2
    exit 64
    ;;
esac

ROOT="$BASE/payload/AetherRoute"
EVIDENCE="$BASE/evidence"
TMP_ROOT="$BASE/tmp"
DERIVED_DATA="$BASE/derived-data"
EXPECTED_PAYLOAD="$BASE/payload.sha256"
EXPECTED_SOURCE="$BASE/source-manifest.txt"
ACTUAL_PAYLOAD="$BASE/payload-actual.sha256"
ACTUAL_SOURCE="$BASE/source-manifest-actual.txt"
GATE_STATUS=failed

# Homebrew is intentionally absent from the default non-interactive SSH PATH
# on the validation Mac. Keep the remote gate deterministic without requiring
# shell profile files to be sourced.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

for command in go gofmt jq python3; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Remote validation requires $command" >&2
    exit 1
  }
done

mkdir -p "$EVIDENCE" "$TMP_ROOT"

finish() {
  exit_code=$?
  ended_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  {
    printf 'status=%s\n' "$GATE_STATUS"
    printf 'mode=%s\n' "$MODE"
    printf 'exit_code=%s\n' "$exit_code"
    printf 'ended_at=%s\n' "$ended_at"
  } > "$EVIDENCE/result.env"
}
trap finish EXIT
trap 'exit 130' HUP INT TERM

test -x "$ROOT/scripts/test.sh"
test -x "$ROOT/scripts/test_sanitizers.sh"
test -f "$EXPECTED_PAYLOAD"
test -f "$EXPECTED_SOURCE"

arch=$(uname -m)
test "$arch" = arm64 || {
  echo "Remote validation requires Apple silicon (arm64), got: $arch" >&2
  exit 1
}

xcode_version=$(xcodebuild -version | paste -sd ' ' -)
available_kb=$(df -Pk /tmp | awk 'END {print $4}')
case "$MODE" in
  fast) required_kb=$((8 * 1024 * 1024)) ;;
  full) required_kb=$((20 * 1024 * 1024)) ;;
esac
test "$available_kb" -ge "$required_kb" || {
  echo "Remote /tmp has ${available_kb} KiB free; ${required_kb} KiB required for $MODE mode" >&2
  exit 1
}

create_payload_manifest() {
  manifest_root=$1
  manifest_output=$2
  (
    cd "$manifest_root"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r file
    do
      hash=$(shasum -a 256 "$file" | awk '{print $1}')
      printf '%s  %s\n' "$hash" "$file"
    done
  ) > "$manifest_output"
}

create_payload_manifest "$BASE/payload" "$ACTUAL_PAYLOAD"
cmp -s "$EXPECTED_PAYLOAD" "$ACTUAL_PAYLOAD" || {
  echo "Remote payload differs from the local staged snapshot" >&2
  diff -u "$EXPECTED_PAYLOAD" "$ACTUAL_PAYLOAD" >&2 || true
  exit 1
}

"$ROOT/scripts/source_manifest.sh" > "$ACTUAL_SOURCE"
cmp -s "$EXPECTED_SOURCE" "$ACTUAL_SOURCE" || {
  echo "Remote source manifest differs from the local source snapshot" >&2
  diff -u "$EXPECTED_SOURCE" "$ACTUAL_SOURCE" >&2 || true
  exit 1
}

if grep -R -E -n \
  '^[[:space:]]*((sudo|doas)[[:space:]]+)?((/usr/sbin/)?networksetup[[:space:]]+-(set|create|delete)|(/sbin/)?route[[:space:]]+(add|delete|change)|(/usr/sbin/)?scutil[[:space:]]+--(set|nc))' \
  "$ROOT/scripts" >/dev/null; then
  echo "A remote validation script contains a forbidden system-network mutation command" >&2
  exit 1
fi

network_control_hash() {
  {
    /usr/sbin/scutil --proxy
    /usr/sbin/scutil --dns
    /usr/sbin/netstat -rn -f inet | awk '$1 == "default" {print}'
    /usr/sbin/netstat -rn -f inet6 | awk '$1 == "default" {print}'
    /sbin/ifconfig -l
  } | shasum -a 256 | awk '{print $1}'
}

network_before=$(network_control_hash)
started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
source_sha=$(tail -1 "$ACTUAL_SOURCE" | awk '{print $2}')
payload_sha=$(shasum -a 256 "$ACTUAL_PAYLOAD" | awk '{print $1}')
{
  printf 'architecture=%s\n' "$arch"
  printf 'xcode=%s\n' "$xcode_version"
  printf 'available_tmp_kb=%s\n' "$available_kb"
  printf 'mode=%s\n' "$MODE"
  printf 'started_at=%s\n' "$started_at"
  printf 'source_manifest_sha256=%s\n' "$source_sha"
  printf 'payload_manifest_sha256=%s\n' "$payload_sha"
  printf 'network_control_before_sha256=%s\n' "$network_before"
} > "$EVIDENCE/machine.env"

export TMPDIR="$TMP_ROOT"
export AETHERROUTE_DERIVED_DATA_PATH="$DERIVED_DATA"
export AETHERROUTE_INTEROP_TEST_BINARY="$BASE/payload/references/interop-tools/clash-rs-2272555/clash-lib-protocol-tests"

(cd "$ROOT" && "$ROOT/scripts/test.sh")
if [ "$MODE" = full ]; then
  (cd "$ROOT" && "$ROOT/scripts/test_sanitizers.sh")
fi

network_after=$(network_control_hash)
test "$network_before" = "$network_after" || {
  echo "System proxy/DNS/default-route/interface state changed during the remote gate" >&2
  exit 1
}
printf 'network_control_after_sha256=%s\n' "$network_after" >> "$EVIDENCE/machine.env"

"$ROOT/scripts/source_manifest.sh" > "$BASE/source-manifest-after.txt"
cmp -s "$ACTUAL_SOURCE" "$BASE/source-manifest-after.txt" || {
  echo "Remote source tree changed during validation" >&2
  exit 1
}

GATE_STATUS=passed
echo "Remote arm64 $MODE gate passed without changing system proxy or default routes."
