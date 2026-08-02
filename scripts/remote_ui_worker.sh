#!/bin/sh
set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 <source-root> <evidence-dir> <expected-source> [only-test]" >&2
  exit 64
fi

ROOT=$1
EVIDENCE=$2
EXPECTED_SOURCE=$3
ONLY_TEST=${4:-}
ACTUAL_SOURCE="$EVIDENCE/source-before.txt"
SOURCE_AFTER="$EVIDENCE/source-after.txt"
TEST_LOG="$EVIDENCE/ui-test.log"
RESULT="$EVIDENCE/result.env"

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

"$ROOT/scripts/source_manifest.sh" > "$ACTUAL_SOURCE"
cmp -s "$EXPECTED_SOURCE" "$ACTUAL_SOURCE" || {
  echo "Remote UI source manifest differs from the staged snapshot" >&2
  diff -u "$EXPECTED_SOURCE" "$ACTUAL_SOURCE" >&2 || true
  exit 1
}

network_before=$(network_control_hash)
started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
source_sha=$(tail -1 "$ACTUAL_SOURCE" | awk '{print $2}')
console_locked=$(
  /usr/sbin/ioreg -n Root -d1 -w0 \
    | awk -F'= ' '
        /"IOConsoleLocked"/ {
          value = $2
          gsub(/[[:space:]"]/, "", value)
          print value
          exit
        }
      '
)

if [ "$console_locked" != No ]; then
  printf '%s\n' \
    'Remote macOS UI session is locked; unlock it once before UI automation.' \
    'No UI runner was started and no system network settings were changed.' \
    > "$TEST_LOG"
  test_status=78
else
  set +e
  if [ -n "$ONLY_TEST" ]; then
    /usr/bin/caffeinate -dimsu /usr/bin/env \
      AETHERROUTE_UI_TEST_WAIT_FOR_LOCK=1 \
      AETHERROUTE_UI_TEST_ONLY="$ONLY_TEST" \
      "$ROOT/scripts/test_ui.sh" > "$TEST_LOG" 2>&1
  else
    /usr/bin/caffeinate -dimsu /usr/bin/env \
      AETHERROUTE_UI_TEST_WAIT_FOR_LOCK=1 \
      "$ROOT/scripts/test_ui.sh" > "$TEST_LOG" 2>&1
  fi
  test_status=$?
  set -e
fi

network_after=$(network_control_hash)
"$ROOT/scripts/source_manifest.sh" > "$SOURCE_AFTER"
source_unchanged=true
network_unchanged=true
cmp -s "$ACTUAL_SOURCE" "$SOURCE_AFTER" || source_unchanged=false
test "$network_before" = "$network_after" || network_unchanged=false

finished_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
{
  printf 'started_at=%s\n' "$started_at"
  printf 'finished_at=%s\n' "$finished_at"
  printf 'source_manifest_sha256=%s\n' "$source_sha"
  printf 'console_locked_before=%s\n' "$console_locked"
  printf 'test_status=%s\n' "$test_status"
  printf 'source_unchanged=%s\n' "$source_unchanged"
  printf 'network_control_before_sha256=%s\n' "$network_before"
  printf 'network_control_after_sha256=%s\n' "$network_after"
  printf 'network_unchanged=%s\n' "$network_unchanged"
} > "$RESULT"

test "$source_unchanged" = true || exit 1
test "$network_unchanged" = true || exit 1
exit "$test_status"
