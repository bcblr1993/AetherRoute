#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EVIDENCE=${1:-}
EXPECTED_DMG_SHA256=${2:-}
EXPECTED_MANIFEST_SHA256=${3:-}
CANDIDATE_MANIFEST=${4:-}

fail() {
  echo "Post-install evidence failed: $*" >&2
  exit 1
}

case "$EVIDENCE" in
  /*) ;;
  '') echo "usage: verify_postinstall_evidence.sh /absolute/evidence expected-dmg-sha256 expected-candidate-manifest-sha256 /absolute/candidate-manifest" >&2; exit 64 ;;
  *) fail "evidence path must be absolute" ;;
esac
for value in "$EXPECTED_DMG_SHA256" "$EXPECTED_MANIFEST_SHA256"; do
  case "$value" in ''|*[!0-9a-f]*) fail "expected hashes must be lowercase SHA-256" ;; esac
  test "${#value}" -eq 64 || fail "expected hashes must be 64 characters"
done
case "$CANDIDATE_MANIFEST" in /*) ;; *) fail "candidate manifest path must be absolute" ;; esac
test -f "$CANDIDATE_MANIFEST" && test ! -L "$CANDIDATE_MANIFEST" \
  || fail "candidate manifest must be a regular non-symlink file"
test "$(shasum -a 256 "$CANDIDATE_MANIFEST" | awk '{print $1}')" = "$EXPECTED_MANIFEST_SHA256" \
  || fail "supplied candidate manifest hash differs"
test "$(jq -r '.dmg.sha256' "$CANDIDATE_MANIFEST")" = "$EXPECTED_DMG_SHA256" \
  || fail "supplied candidate DMG hash differs"
test -d "$EVIDENCE" && test ! -L "$EVIDENCE" \
  || fail "evidence must be a real directory"
for name in metadata.txt result.txt SHA256SUMS; do
  test -f "$EVIDENCE/$name" && test ! -L "$EVIDENCE/$name" \
    || fail "$name must be a regular non-symlink file"
done
unexpected=$(find "$EVIDENCE" -mindepth 1 -maxdepth 1 \
  ! -name metadata.txt ! -name result.txt ! -name SHA256SUMS \
  ! -name installed-ne-performance -print)
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
test "$(field "$metadata" schema)" = 2 || fail "unsupported evidence schema"
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
require_uint_at_most connected_cpu_p95_basis_points 500
require_uint_at_most combined_resident_memory_bytes 268435456
require_uint_at_most ui_action_p95_milliseconds 120
require_uint_at_most main_thread_stalls_250ms_or_more 0
# The 1 GiB/s floor belongs to the separate isolated-core gate in test.sh.
# Installed provider throughput/latency require measured, calibrated evidence.
if grep -Eq '^(tun|transparent)_(throughput_mib_per_second|added_p95_latency_microseconds)=' "$result"; then
  fail "legacy standalone throughput/latency numbers cannot prove installed performance"
fi
performance="$EVIDENCE/installed-ne-performance"
test -d "$performance" && test ! -L "$performance" \
  || fail "missing installed Network Extension performance evidence"
test -f "$performance/SHA256SUMS" && test ! -L "$performance/SHA256SUMS" \
  || fail "missing installed performance checksums"
test "$(field "$result" installed_ne_performance_evidence_sha256)" = \
  "$(shasum -a 256 "$performance/SHA256SUMS" | awk '{print $1}')" \
  || fail "installed performance evidence hash differs"
"$ROOT/scripts/verify_installed_ne_performance_evidence.sh" \
  "$performance" "$CANDIDATE_MANIFEST"

test "$(field "$result" raw_xcresult_retained)" = no \
  || fail "raw xcresult must not be retained"
test "$(field "$result" endpoint_data_retained)" = no \
  || fail "endpoint or canary data must not be retained"
test "$(field "$result" status)" = passed || fail "post-install result did not pass"

echo "Post-install evidence verified: exact candidate, Developer ID runtime, leak/recovery/performance/UI gates passed."
