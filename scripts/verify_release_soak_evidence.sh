#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EVIDENCE=${1:-}

fail() {
  echo "Release soak evidence failed: $*" >&2
  exit 1
}

case "$EVIDENCE" in
  /*) ;;
  '') echo "usage: verify_release_soak_evidence.sh /absolute/evidence/directory" >&2; exit 64 ;;
  *) fail "evidence path must be absolute" ;;
esac

AETHERROUTE_SOAK_TREND_MIN_DURATION_SECONDS=86400 \
AETHERROUTE_SOAK_RSS_SLOPE_BUDGET_BYTES_PER_HOUR=1048576 \
  "$ROOT/scripts/verify_isolated_soak_trends.sh" "$EVIDENCE" >/dev/null

field() {
  file=$1
  key=$2
  count=$(awk -F= -v key="$key" '$1 == key {count++} END {print count+0}' "$file")
  test "$count" -eq 1 || fail "$file must contain exactly one $key field"
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print}' "$file"
}

metadata="$EVIDENCE/metadata.txt"
result="$EVIDENCE/result.txt"
test "$(field "$metadata" schema)" = 2 \
  || fail "release evidence must use schema 2 with FD growth data"
test "$(field "$metadata" requested_duration_seconds)" -ge 86400 \
  || fail "release evidence must request at least 24 hours"
test "$(field "$metadata" packet_cycles_per_round)" -eq 1000 \
  || fail "release evidence must exercise 1000 PacketFlow cycles per round"
test "$(field "$metadata" flow_udp_probe_datagrams)" -eq 3 \
  || fail "release evidence must use the three-datagram FlowOnly probe"
test "$(field "$metadata" round_timeout_seconds)" -le 600 \
  || fail "release evidence has an excessive round timeout"
test "$(field "$metadata" flow_rss_budget_bytes)" -le 67108864 \
  || fail "release evidence weakens the FlowOnly RSS budget"
test "$(field "$metadata" packet_rss_budget_bytes)" -le 33554432 \
  || fail "release evidence weakens the PacketFlow RSS budget"
test "$(field "$metadata" fd_growth_budget)" -le 4 \
  || fail "release evidence weakens the FD growth budget"
test "$(field "$metadata" diagnostic_report_scan)" = exact-process-basename \
  || fail "release evidence did not scan exact core diagnostic reports"
test "$(field "$metadata" orphan_process_scan)" = exact-binary-path \
  || fail "release evidence did not scan exact core process paths"
git_commit=$(field "$metadata" git_commit)
printf '%s\n' "$git_commit" | grep -Eq '^[0-9a-f]{40}$' \
  || fail "git_commit must be a full lowercase Git commit"
test "$git_commit" = "$(git -C "$ROOT" rev-parse HEAD)" \
  || fail "git_commit does not match the current release commit"
source_manifest_sha256=$(field "$metadata" source_manifest_sha256)
printf '%s\n' "$source_manifest_sha256" | grep -Eq '^[0-9a-f]{64}$' \
  || fail "source_manifest_sha256 must be lowercase SHA-256"
current_source_manifest_sha256=$("$ROOT/scripts/source_manifest.sh" \
  | awk '$1 == "MANIFEST_SHA256" {print $2}')
test "$source_manifest_sha256" = "$current_source_manifest_sha256" \
  || fail "source manifest does not match the current release tree"
test "$(field "$result" new_diagnostic_reports)" -eq 0 \
  || fail "release evidence contains a core crash, hang, or spin report"
test "$(field "$result" orphan_processes)" -eq 0 \
  || fail "release evidence contains an orphan core process"
rounds=$(field "$result" rounds)
test "$rounds" -ge 800 \
  || fail "release evidence must contain at least 800 complete rounds"

parse_utc() {
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s' 2>/dev/null \
    || fail "invalid UTC timestamp: $1"
}

started_utc=$(field "$metadata" started_utc)
completed_utc=$(field "$result" completed_utc)
actual_duration=$(field "$result" actual_duration_seconds)
started_epoch=$(parse_utc "$started_utc")
completed_epoch=$(parse_utc "$completed_utc")
timestamp_duration=$((completed_epoch - started_epoch))
duration_delta=$((timestamp_duration - actual_duration))
if [ "$duration_delta" -lt 0 ]; then duration_delta=$((-duration_delta)); fi
test "$duration_delta" -le 2 \
  || fail "UTC timestamps do not match the recorded duration"

set -- $(awk -F '\t' '
  NR == 1 {next}
  {
    if ($3 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ ||
        (previous != "" && $3 < previous)) exit 1
    if (first == "") first=$3
    previous=$3
  }
  END {
    if (first == "" || previous == "") exit 1
    print first, previous
  }
' "$EVIDENCE/rounds.tsv") || fail "round timestamps are invalid or unordered"
test "$#" -eq 2 || fail "could not derive round timestamp bounds"
first_round_epoch=$(parse_utc "$1")
last_round_epoch=$(parse_utc "$2")
test "$first_round_epoch" -ge "$started_epoch" \
  || fail "first round predates the soak start"
test "$last_round_epoch" -le "$completed_epoch" \
  || fail "last round exceeds the soak completion"
test $((first_round_epoch - started_epoch)) -le 600 \
  || fail "round evidence does not cover the start boundary"
test $((completed_epoch - last_round_epoch)) -le 600 \
  || fail "round evidence does not cover the completion boundary"

verify_source_hash() {
  key=$1
  source=$2
  recorded=$(field "$metadata" "$key")
  actual=$(shasum -a 256 "$source" | awk '{print $1}')
  test "$recorded" = "$actual" \
    || fail "$key does not match the release source tree"
}

verify_source_hash runner_sha256 \
  "$ROOT/scripts/test_isolated_soak.sh"
verify_source_hash flow_harness_sha256 \
  "$ROOT/Tests/CoreSmoke/flow_core_smoke.c"
verify_source_hash packet_harness_sha256 \
  "$ROOT/Tests/CoreSmoke/packet_tunnel_core_smoke.c"
verify_source_hash flow_artifact_sha256 \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a"
verify_source_hash packet_artifact_sha256 \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a"

echo "Release soak evidence verified: exact source commit, complete source manifest, current cores and harnesses, 24-hour duration, at least 800 complete rounds, bounded RSS slope and FD growth."
