#!/bin/sh
set -eu

EVIDENCE=${1:-}
EXPECTED_DMG_SHA256=${2:-}
EXPECTED_MANIFEST_SHA256=${3:-}

fail() {
  echo "Post-install evidence failed: $*" >&2
  exit 1
}

case "$EVIDENCE" in
  /*) ;;
  '') echo "usage: verify_postinstall_evidence.sh /absolute/evidence expected-dmg-sha256 expected-candidate-manifest-sha256" >&2; exit 64 ;;
  *) fail "evidence path must be absolute" ;;
esac
for value in "$EXPECTED_DMG_SHA256" "$EXPECTED_MANIFEST_SHA256"; do
  case "$value" in ''|*[!0-9a-f]*) fail "expected hashes must be lowercase SHA-256" ;; esac
  test "${#value}" -eq 64 || fail "expected hashes must be 64 characters"
done
test -d "$EVIDENCE" && test ! -L "$EVIDENCE" \
  || fail "evidence must be a real directory"
for name in metadata.txt result.txt SHA256SUMS; do
  test -f "$EVIDENCE/$name" && test ! -L "$EVIDENCE/$name" \
    || fail "$name must be a regular non-symlink file"
done
unexpected=$(find "$EVIDENCE" -mindepth 1 -maxdepth 1 \
  ! -name metadata.txt ! -name result.txt ! -name SHA256SUMS -print)
test -z "$unexpected" || fail "evidence contains unexpected raw files"
if grep -E -i 'https?://|token=|password=|endpoint=' \
  "$EVIDENCE/metadata.txt" "$EVIDENCE/result.txt" >/dev/null; then
  fail "evidence contains a URL, endpoint, or credential-like value"
fi

field() {
  file=$1
  key=$2
  count=$(awk -F= -v key="$key" '$1 == key {count++} END {print count+0}' "$file")
  test "$count" -eq 1 || fail "$file must contain exactly one $key field"
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print}' "$file"
}

verify_hash() {
  name=$1
  expected=$(awk -v name="$name" '
    {
      hash=substr($0, 1, 64)
      path=substr($0, 65)
      sub(/^[[:space:]]+\*?/, "", path)
      sub(/^\*/, "", path)
      count=split(path, parts, "/")
      if (parts[count] == name) {matches++; matched=hash}
    }
    END {if (matches != 1) exit 1; print matched}
  ' "$EVIDENCE/SHA256SUMS") || fail "SHA256SUMS must name $name exactly once"
  actual=$(shasum -a 256 "$EVIDENCE/$name" | awk '{print $1}')
  test "$actual" = "$expected" || fail "$name SHA-256 does not match"
}
verify_hash metadata.txt
verify_hash result.txt

metadata="$EVIDENCE/metadata.txt"
result="$EVIDENCE/result.txt"
test "$(field "$metadata" schema)" = 1 || fail "unsupported evidence schema"
test "$(field "$metadata" machine)" = arm64 || fail "evidence is not arm64"
test "$(field "$metadata" candidate_dmg_sha256)" = "$EXPECTED_DMG_SHA256" \
  || fail "candidate DMG hash mismatch"
test "$(field "$metadata" candidate_manifest_sha256)" = "$EXPECTED_MANIFEST_SHA256" \
  || fail "candidate manifest hash mismatch"
test "$(field "$metadata" application_signature)" = 'Developer ID Application' \
  || fail "installed app is not Developer ID Application signed"
for key in notarization stapler gatekeeper clean_install upgrade rollback \
  ipv4_canary ipv6_canary dns_leak bypass recursion disconnect_restore \
  sleep_wake path_change crash_recovery network_control_restored; do
  test "$(field "$result" "$key")" = passed \
    || fail "$key did not pass"
done

for engine in tun transparent; do
  cycles=$(field "$result" "${engine}_cycles")
  case "$cycles" in ''|*[!0-9]*) fail "$engine cycles must be an integer" ;; esac
  test "$cycles" -ge 3 || fail "$engine must pass at least three cycles"
  test "$(field "$result" "${engine}_canary")" = passed \
    || fail "$engine canary did not pass"
done

require_uint_at_most() {
  key=$1
  maximum=$2
  value=$(field "$result" "$key")
  case "$value" in ''|*[!0-9]*) fail "$key must be an unsigned integer" ;; esac
  test "$value" -le "$maximum" || fail "$key exceeds $maximum"
}
require_uint_at_least() {
  key=$1
  minimum=$2
  value=$(field "$result" "$key")
  case "$value" in ''|*[!0-9]*) fail "$key must be an unsigned integer" ;; esac
  test "$value" -ge "$minimum" || fail "$key is below $minimum"
}
require_uint_at_most connected_cpu_p95_basis_points 500
require_uint_at_most combined_resident_memory_bytes 268435456
require_uint_at_most ui_action_p95_milliseconds 120
require_uint_at_most main_thread_stalls_250ms_or_more 0
require_uint_at_most tun_added_p95_latency_microseconds 5000
require_uint_at_most transparent_added_p95_latency_microseconds 5000
require_uint_at_least tun_throughput_mib_per_second 1024
require_uint_at_least transparent_throughput_mib_per_second 1024

test "$(field "$result" raw_xcresult_retained)" = no \
  || fail "raw xcresult must not be retained"
test "$(field "$result" endpoint_data_retained)" = no \
  || fail "endpoint or canary data must not be retained"
test "$(field "$result" status)" = passed || fail "post-install result did not pass"

echo "Post-install evidence verified: exact candidate, Developer ID runtime, leak/recovery/performance/UI gates passed."
