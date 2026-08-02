#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-soak-verifier.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
EVIDENCE="$TEMP/evidence with spaces"
mkdir "$EVIDENCE"

write_hashes() {
  shasum -a 256 \
    "$EVIDENCE/metadata.txt" "$EVIDENCE/rounds.tsv" "$EVIDENCE/result.txt" \
    >"$EVIDENCE/SHA256SUMS"
}

printf '%s\n' \
  'schema=1' \
  'started_utc=2026-08-01T00:00:00Z' \
  'requested_duration_seconds=60' \
  'packet_cycles_per_round=20' \
  'round_timeout_seconds=60' \
  'flow_rss_budget_bytes=67108864' \
  'packet_rss_budget_bytes=33554432' \
  'machine=arm64' \
  'os=26.5' \
  'network_extension=disabled' \
  'system_network_settings=unchanged' >"$EVIDENCE/metadata.txt"
printf '%b\n' \
  'round\tengine\tcompleted_utc\twall_seconds\tcycles\tmax_rss_bytes\tresult_sha256' \
  '1\tflow\t2026-08-01T00:00:01Z\t1\t500\t9000000\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  '1\tpacket\t2026-08-01T00:00:03Z\t2\t20\t12000000\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  '2\tflow\t2026-08-01T00:00:04Z\t1\t500\t9100000\tcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
  '2\tpacket\t2026-08-01T00:01:00Z\t2\t20\t12100000\tdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
  >"$EVIDENCE/rounds.tsv"
printf '%s\n' \
  'completed_utc=2026-08-01T00:01:00Z' \
  'actual_duration_seconds=60' \
  'rounds=2' \
  'flow_lifecycle_cycles=1000' \
  'packet_lifecycle_cycles=40' \
  'flow_peak_rss_bytes=9100000' \
  'packet_peak_rss_bytes=12100000' \
  'status=passed' >"$EVIDENCE/result.txt"
write_hashes

"$ROOT/scripts/verify_isolated_soak_result.sh" "$EVIDENCE" >/dev/null

sed -i '' 's/^schema=1$/schema=2/' "$EVIDENCE/metadata.txt"
printf '%s\n' 'fd_growth_budget=4' >>"$EVIDENCE/metadata.txt"
awk 'BEGIN {FS=OFS="\t"} NR == 1 {print $0, "fd_growth"; next}
  $2 == "flow" {print $0, 2; next} {print $0, 0}' \
  "$EVIDENCE/rounds.tsv" >"$EVIDENCE/rounds.schema2"
mv "$EVIDENCE/rounds.schema2" "$EVIDENCE/rounds.tsv"
printf '%s\n' 'flow_peak_fd_growth=2' 'packet_peak_fd_growth=0' \
  >>"$EVIDENCE/result.txt"
write_hashes
"$ROOT/scripts/verify_isolated_soak_result.sh" "$EVIDENCE" >/dev/null

awk 'BEGIN {FS=OFS="\t"} NR > 1 && $2 == "flow" && !changed {
  $8=5; changed=1
} {print}' "$EVIDENCE/rounds.tsv" >"$EVIDENCE/rounds.fd-regression"
mv "$EVIDENCE/rounds.fd-regression" "$EVIDENCE/rounds.tsv"
write_hashes
if "$ROOT/scripts/verify_isolated_soak_result.sh" "$EVIDENCE" >/dev/null 2>&1; then
  echo "soak verifier accepted a file-descriptor growth regression" >&2
  exit 1
fi
awk 'BEGIN {FS=OFS="\t"} NR > 1 && $2 == "flow" && !changed {
  $8=2; changed=1
} {print}' "$EVIDENCE/rounds.tsv" >"$EVIDENCE/rounds.fd-restored"
mv "$EVIDENCE/rounds.fd-restored" "$EVIDENCE/rounds.tsv"
write_hashes
if AETHERROUTE_SOAK_PACKET_WALL_BUDGET_SECONDS=1 \
  "$ROOT/scripts/verify_isolated_soak_result.sh" "$EVIDENCE" >/dev/null 2>&1; then
  echo "soak verifier accepted a packet wall-time regression" >&2
  exit 1
fi

sed '$d' "$EVIDENCE/rounds.tsv" >"$EVIDENCE/rounds.incomplete"
mv "$EVIDENCE/rounds.incomplete" "$EVIDENCE/rounds.tsv"
write_hashes
if "$ROOT/scripts/verify_isolated_soak_result.sh" "$EVIDENCE" >/dev/null 2>&1; then
  echo "soak verifier accepted an incomplete round matrix" >&2
  exit 1
fi

echo "Isolated soak evidence verifier tests passed."
