#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-postinstall-evidence.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
EVIDENCE="$TEMP/evidence"
mkdir "$EVIDENCE"
DMG_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MANIFEST_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

write_hashes() {
  (cd "$EVIDENCE" && shasum -a 256 metadata.txt result.txt >SHA256SUMS)
}
printf '%s\n' \
  'schema=1' \
  'machine=arm64' \
  'os=26.5' \
  "candidate_dmg_sha256=$DMG_SHA" \
  "candidate_manifest_sha256=$MANIFEST_SHA" \
  'application_signature=Developer ID Application' >"$EVIDENCE/metadata.txt"
write_result() {
  dns_state=$1
  cpu_p95=$2
  printf '%s\n' \
    'notarization=passed' 'stapler=passed' 'gatekeeper=passed' \
    'clean_install=passed' 'upgrade=passed' 'rollback=passed' \
    'tun_cycles=3' 'tun_canary=passed' \
    'transparent_cycles=3' 'transparent_canary=passed' \
    'ipv4_canary=passed' 'ipv6_canary=passed' "dns_leak=$dns_state" \
    'bypass=passed' 'recursion=passed' 'disconnect_restore=passed' \
    'sleep_wake=passed' 'path_change=passed' 'crash_recovery=passed' \
    'network_control_restored=passed' \
    "connected_cpu_p95_basis_points=$cpu_p95" \
    'combined_resident_memory_bytes=200000000' \
    'ui_action_p95_milliseconds=100' \
    'main_thread_stalls_250ms_or_more=0' \
    'tun_added_p95_latency_microseconds=4000' \
    'transparent_added_p95_latency_microseconds=4000' \
    'tun_throughput_mib_per_second=1200' \
    'transparent_throughput_mib_per_second=1200' \
    'raw_xcresult_retained=no' 'endpoint_data_retained=no' \
    'status=passed' >"$EVIDENCE/result.txt"
}

write_result passed 400
write_hashes
"$ROOT/scripts/verify_postinstall_evidence.sh" \
  "$EVIDENCE" "$DMG_SHA" "$MANIFEST_SHA" >/dev/null

write_result failed 400
write_hashes
if "$ROOT/scripts/verify_postinstall_evidence.sh" \
  "$EVIDENCE" "$DMG_SHA" "$MANIFEST_SHA" >/dev/null 2>&1; then
  echo "post-install verifier accepted a DNS leak failure" >&2
  exit 1
fi

write_result passed 501
write_hashes
if "$ROOT/scripts/verify_postinstall_evidence.sh" \
  "$EVIDENCE" "$DMG_SHA" "$MANIFEST_SHA" >/dev/null 2>&1; then
  echo "post-install verifier accepted excessive connected CPU" >&2
  exit 1
fi

write_result passed 400
write_hashes
touch "$EVIDENCE/raw-network.log"
if "$ROOT/scripts/verify_postinstall_evidence.sh" \
  "$EVIDENCE" "$DMG_SHA" "$MANIFEST_SHA" >/dev/null 2>&1; then
  echo "post-install verifier accepted an extra raw log" >&2
  exit 1
fi
find "$EVIDENCE/raw-network.log" -delete

echo "Post-install production evidence verifier tests passed."
