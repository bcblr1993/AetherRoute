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
test "$timestamp_duration" -eq "$actual_duration" \
  || fail "UTC timestamps do not match the recorded duration"

# BEGIN effective runtime continuity
# A row covers [completed_utc - wall_seconds, completed_utc]. The runner
# records both from the same ended epoch. Its one-second watchdog polling is
# already inside wall_seconds; only integer-second quantization and the
# observed sub-second record/hash work may separate consecutive intervals.
# These gaps never count toward the required 24 hours of effective runtime.
awk -F '\t' \
  -v started_epoch="$started_epoch" \
  -v completed_epoch="$completed_epoch" \
  -v requested="$(field "$metadata" requested_duration_seconds)" \
  -v actual_duration="$actual_duration" '
  function leap(year) {
    return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  }
  function epoch(value, part, year, month, day, hour, minute, second,
                 days, month_index, limit) {
    if (value !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) return -1
    split(value, part, /[-T:Z]/)
    year=part[1]+0; month=part[2]+0; day=part[3]+0
    hour=part[4]+0; minute=part[5]+0; second=part[6]+0
    if (year < 1970 || month < 1 || month > 12 || hour > 23 || minute > 59 || second > 59) return -1
    limit=month_days[month]+(month == 2 && leap(year))
    if (day < 1 || day > limit) return -1
    days=(year-1970)*365 + int((year-1)/4)-492 - int((year-1)/100)+19 + int((year-1)/400)-4
    for (month_index=1; month_index<month; month_index++)
      days+=month_days[month_index]+(month_index == 2 && leap(year))
    return ((days+day-1)*24+hour)*3600+minute*60+second
  }
  function reject(reason) {
    print "soak continuity: " reason > "/dev/stderr"
    invalid=1
    exit 1
  }
  BEGIN {
    split("31 28 31 30 31 30 31 31 30 31 30 31", month_days, " ")
    previous_end=started_epoch
  }
  NR == 1 {next}
  {
    expected_round=int((NR-2)/2)+1
    expected_engine=(NR % 2 == 0 ? "flow" : "packet")
    if ($1 != expected_round || $2 != expected_engine) reject("round intervals are not in execution order")
    interval_end=epoch($3)
    if (interval_end < 0) reject("invalid completed UTC timestamp")
    interval_start=interval_end-$4
    gap=interval_start-previous_end
    if (gap < 0) reject("effective runtime intervals overlap or predate the start")
    if (gap > 1) reject("uncovered gap exceeds one-second recording allowance")
    if (interval_end > completed_epoch) reject("effective runtime extends beyond completion")
    active_wall+=$4
    recording_gaps+=gap
    previous_end=interval_end
    rows++
  }
  END {
    if (invalid) exit 1
    if (!rows || rows % 2) reject("incomplete interval pairs")
    trailing_gap=completed_epoch-previous_end
    if (trailing_gap < 0 || trailing_gap > 1) reject("completion boundary is not covered")
    if (active_wall < requested) reject("accumulated effective runtime is shorter than requested")
    if (active_wall+recording_gaps+trailing_gap != actual_duration) reject("runtime coverage differs from measured duration")
  }
' "$EVIDENCE/rounds.tsv" || fail "continuous effective runtime is not proven"
# END effective runtime continuity

current_source_manifest_sha256=$("$ROOT/scripts/source_manifest.sh" \
  | awk '$1 == "MANIFEST_SHA256" {print $2}')
test "$source_manifest_sha256" = "$current_source_manifest_sha256" \
  || fail "source manifest does not match the current release tree"

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

echo "Release soak evidence verified: exact source commit, complete source manifest, current cores and harnesses, 24-hour effective runtime, adjacent nonoverlapping intervals, at least 800 complete rounds, bounded RSS slope and FD growth."
