#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-soak-trends.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
EVIDENCE="$TEMP/evidence with spaces"
mkdir "$EVIDENCE"

write_hashes() {
  shasum -a 256 \
    "$EVIDENCE/metadata.txt" "$EVIDENCE/rounds.tsv" "$EVIDENCE/result.txt" \
    >"$EVIDENCE/SHA256SUMS"
}

write_metadata() {
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
}

write_rounds() {
  mode=$1
  printf 'round\tengine\tcompleted_utc\twall_seconds\tcycles\tmax_rss_bytes\tresult_sha256\n' \
    >"$EVIDENCE/rounds.tsv"
  round=1
  while [ "$round" -le 20 ]; do
    flow_rss=9000000
    if [ "$mode" = growing ]; then
      flow_rss=$((9000000 + round * 100000))
    fi
    printf '%s\tflow\t2026-08-01T00:00:30Z\t1\t500\t%s\t%s\n' \
      "$round" "$flow_rss" \
      aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
      >>"$EVIDENCE/rounds.tsv"
    printf '%s\tpacket\t2026-08-01T00:01:00Z\t2\t20\t12000000\t%s\n' \
      "$round" \
      bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
      >>"$EVIDENCE/rounds.tsv"
    round=$((round + 1))
  done
}

write_result() {
  flow_peak=$1
  printf '%s\n' \
    'completed_utc=2026-08-01T00:01:00Z' \
    'actual_duration_seconds=60' \
    'rounds=20' \
    'flow_lifecycle_cycles=10000' \
    'packet_lifecycle_cycles=400' \
    "flow_peak_rss_bytes=$flow_peak" \
    'packet_peak_rss_bytes=12000000' \
    'status=passed' >"$EVIDENCE/result.txt"
}

write_metadata
write_rounds flat
write_result 9000000
write_hashes
AETHERROUTE_SOAK_TREND_MIN_DURATION_SECONDS=60 \
  "$ROOT/scripts/verify_isolated_soak_trends.sh" "$EVIDENCE" >/dev/null

if "$ROOT/scripts/verify_isolated_soak_trends.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "soak trend verifier accepted evidence shorter than 24 hours" >&2
  exit 1
fi

write_rounds growing
write_result 11000000
write_hashes
if AETHERROUTE_SOAK_TREND_MIN_DURATION_SECONDS=60 \
  "$ROOT/scripts/verify_isolated_soak_trends.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "soak trend verifier accepted an RSS slope regression" >&2
  exit 1
fi

echo "Isolated soak RSS trend verifier tests passed."
