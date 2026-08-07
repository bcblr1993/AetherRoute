#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PRODUCER="$ROOT/scripts/test_isolated_soak.sh"
for requirement in \
  'SOURCE_MANIFEST_BEFORE="$TEMP/source-before.txt"' \
  'printf '\''git_commit=%s\n'\'' "$GIT_COMMIT"' \
  'printf '\''source_manifest_sha256=%s\n'\'' "$SOURCE_MANIFEST_SHA256"' \
  'cmp -s "$SOURCE_MANIFEST_BEFORE" "$SOURCE_MANIFEST_AFTER"' \
  'Git commit changed during the isolated soak'
do
  grep -F "$requirement" "$PRODUCER" >/dev/null || {
    echo "isolated soak producer is missing source-freeze gate: $requirement" >&2
    exit 1
  }
done
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-release-soak.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
EVIDENCE="$TEMP/release evidence"
mkdir "$EVIDENCE"
CURRENT_SOURCE_MANIFEST_SHA256=$("$ROOT/scripts/source_manifest.sh" \
  | awk '$1 == "MANIFEST_SHA256" {print $2}')
CURRENT_GIT_COMMIT=$(git -C "$ROOT" rev-parse HEAD)

hash_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

write_hashes() {
  shasum -a 256 \
    "$EVIDENCE/metadata.txt" "$EVIDENCE/rounds.tsv" "$EVIDENCE/result.txt" \
    >"$EVIDENCE/SHA256SUMS"
}

write_metadata() {
  packet_hash=$1
  printf '%s\n' \
    'schema=2' \
    'started_utc=2026-08-01T00:00:00Z' \
    'requested_duration_seconds=86400' \
    'packet_cycles_per_round=1000' \
    'flow_udp_probe_datagrams=3' \
    'round_timeout_seconds=600' \
    'flow_rss_budget_bytes=67108864' \
    'packet_rss_budget_bytes=33554432' \
    'fd_growth_budget=4' \
    'machine=arm64' \
    'os=26.5' \
    "git_commit=$CURRENT_GIT_COMMIT" \
    "source_manifest_sha256=$CURRENT_SOURCE_MANIFEST_SHA256" \
    "runner_sha256=$(hash_of "$ROOT/scripts/test_isolated_soak.sh")" \
    "flow_harness_sha256=$(hash_of "$ROOT/Tests/CoreSmoke/flow_core_smoke.c")" \
    "packet_harness_sha256=$(hash_of "$ROOT/Tests/CoreSmoke/packet_tunnel_core_smoke.c")" \
    "flow_artifact_sha256=$(hash_of "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a")" \
    "packet_artifact_sha256=$packet_hash" \
    'diagnostic_report_scan=exact-process-basename' \
    'orphan_process_scan=exact-binary-path' \
    'network_extension=disabled' \
    'system_network_settings=unchanged' >"$EVIDENCE/metadata.txt"
}

printf 'round\tengine\tcompleted_utc\twall_seconds\tcycles\tmax_rss_bytes\tresult_sha256\tfd_growth\n' \
  >"$EVIDENCE/rounds.tsv"
round=1
while [ "$round" -le 800 ]; do
  completed_utc=2026-08-01T12:00:00Z
  if [ "$round" -eq 1 ]; then
    completed_utc=2026-08-01T00:01:00Z
  elif [ "$round" -eq 800 ]; then
    completed_utc=2026-08-02T00:00:00Z
  fi
  printf '%s\tflow\t%s\t1\t500\t9000000\t%s\t2\n' \
    "$round" \
    "$completed_utc" \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    >>"$EVIDENCE/rounds.tsv"
  printf '%s\tpacket\t%s\t2\t1000\t12000000\t%s\t0\n' \
    "$round" \
    "$completed_utc" \
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    >>"$EVIDENCE/rounds.tsv"
  round=$((round + 1))
done
printf '%s\n' \
  'completed_utc=2026-08-02T00:00:00Z' \
  'actual_duration_seconds=86400' \
  'rounds=800' \
  'flow_lifecycle_cycles=400000' \
  'packet_lifecycle_cycles=800000' \
  'flow_peak_rss_bytes=9000000' \
  'packet_peak_rss_bytes=12000000' \
  'flow_peak_fd_growth=2' \
  'packet_peak_fd_growth=0' \
  'new_diagnostic_reports=0' \
  'orphan_processes=0' \
  'status=passed' >"$EVIDENCE/result.txt"

current_packet_hash=$(hash_of \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a")
write_metadata "$current_packet_hash"
write_hashes
"$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" >/dev/null
cp "$EVIDENCE/metadata.txt" "$TEMP/valid-metadata.txt"

sed -i '' \
  's/^source_manifest_sha256=.*/source_manifest_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
  "$EVIDENCE/metadata.txt"
write_hashes
if "$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "release soak verifier accepted a stale source manifest" >&2
  exit 1
fi

cp "$TEMP/valid-metadata.txt" "$EVIDENCE/metadata.txt"
sed -i '' \
  's/^git_commit=.*/git_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
  "$EVIDENCE/metadata.txt"
write_hashes
if "$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "release soak verifier accepted a stale Git commit" >&2
  exit 1
fi

cp "$TEMP/valid-metadata.txt" "$EVIDENCE/metadata.txt"
write_hashes

cp "$EVIDENCE/rounds.tsv" "$TEMP/valid-rounds.tsv"
cp "$EVIDENCE/result.txt" "$TEMP/valid-result.txt"
sed '$d' "$EVIDENCE/rounds.tsv" | sed '$d' >"$EVIDENCE/rounds.short"
mv "$EVIDENCE/rounds.short" "$EVIDENCE/rounds.tsv"
sed -e 's/^rounds=800$/rounds=799/' \
  -e 's/^flow_lifecycle_cycles=400000$/flow_lifecycle_cycles=399500/' \
  -e 's/^packet_lifecycle_cycles=800000$/packet_lifecycle_cycles=799000/' \
  "$EVIDENCE/result.txt" >"$EVIDENCE/result.short"
mv "$EVIDENCE/result.short" "$EVIDENCE/result.txt"
write_hashes
if "$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "release soak verifier accepted fewer than 800 rounds" >&2
  exit 1
fi

cp "$TEMP/valid-rounds.tsv" "$EVIDENCE/rounds.tsv"
cp "$TEMP/valid-result.txt" "$EVIDENCE/result.txt"
sed -i '' \
  's/^completed_utc=2026-08-02T00:00:00Z$/completed_utc=2026-08-02T00:00:10Z/' \
  "$EVIDENCE/result.txt"
write_hashes
if "$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "release soak verifier accepted inconsistent UTC boundaries" >&2
  exit 1
fi

cp "$TEMP/valid-result.txt" "$EVIDENCE/result.txt"
sed -i '' 's/^new_diagnostic_reports=0$/new_diagnostic_reports=1/' \
  "$EVIDENCE/result.txt"
write_metadata "$current_packet_hash"
write_hashes
if "$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "release soak verifier accepted a crash diagnostic report" >&2
  exit 1
fi

cp "$TEMP/valid-result.txt" "$EVIDENCE/result.txt"
write_metadata aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
write_hashes
if "$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "release soak verifier accepted a stale PacketFlow artifact" >&2
  exit 1
fi

write_metadata "$current_packet_hash"
sed -i '' 's/^fd_growth_budget=4$/fd_growth_budget=5/' \
  "$EVIDENCE/metadata.txt"
write_hashes
if "$ROOT/scripts/verify_release_soak_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "release soak verifier accepted a weakened FD budget" >&2
  exit 1
fi

echo "Exact release soak evidence verifier tests passed."
