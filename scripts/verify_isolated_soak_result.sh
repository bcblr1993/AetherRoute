#!/bin/sh
set -eu

OUTPUT=${1:-}
FLOW_WALL_BUDGET=${AETHERROUTE_SOAK_FLOW_WALL_BUDGET_SECONDS:-10}
PACKET_WALL_BUDGET=${AETHERROUTE_SOAK_PACKET_WALL_BUDGET_SECONDS:-90}

fail() {
  echo "Isolated soak evidence failed: $*" >&2
  exit 1
}

case "$OUTPUT" in
  /*) ;;
  '') echo "usage: verify_isolated_soak_result.sh /absolute/output/directory" >&2; exit 64 ;;
  *) OUTPUT="$PWD/$OUTPUT" ;;
esac
test -d "$OUTPUT" && test ! -L "$OUTPUT" \
  || fail "output must be a real directory"

case "$FLOW_WALL_BUDGET:$PACKET_WALL_BUDGET" in
  *[!0-9:]*|:*|*:) fail "wall-time budgets must be positive integers" ;;
esac
test "$FLOW_WALL_BUDGET" -gt 0 && test "$PACKET_WALL_BUDGET" -gt 0 \
  || fail "wall-time budgets must be positive integers"

for name in metadata.txt rounds.tsv result.txt SHA256SUMS; do
  path="$OUTPUT/$name"
  test -f "$path" && test ! -L "$path" \
    || fail "$name must be a regular non-symlink file"
done

field() {
  file=$1
  key=$2
  count=$(awk -F= -v key="$key" '$1 == key {count++} END {print count+0}' "$file")
  test "$count" -eq 1 || fail "$file must contain exactly one $key field"
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print}' "$file"
}

require_uint() {
  label=$1
  value=$2
  case "$value" in
    ''|*[!0-9]*) fail "$label must be an unsigned integer" ;;
  esac
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
      if (parts[count] == name) {
        matches++
        matched_hash=hash
      }
    }
    END {
      if (matches != 1) exit 1
      print matched_hash
    }
  ' "$OUTPUT/SHA256SUMS") || fail "SHA256SUMS must name $name exactly once"
  case "$expected" in
    ''|*[!0-9a-f]*) fail "$name has an invalid SHA-256 entry" ;;
  esac
  test "${#expected}" -eq 64 || fail "$name has an invalid SHA-256 length"
  actual=$(shasum -a 256 "$OUTPUT/$name" | awk '{print $1}')
  test "$actual" = "$expected" || fail "$name SHA-256 does not match"
}

for name in metadata.txt rounds.tsv result.txt; do
  verify_hash "$name"
done

metadata="$OUTPUT/metadata.txt"
result="$OUTPUT/result.txt"
schema=$(field "$metadata" schema)
test "$schema" = 1 || test "$schema" = 2 || fail "unsupported metadata schema"
test "$(field "$metadata" machine)" = arm64 || fail "soak did not run on arm64"
test "$(field "$metadata" network_extension)" = disabled \
  || fail "isolated soak unexpectedly enabled NetworkExtension"
test "$(field "$metadata" system_network_settings)" = unchanged \
  || fail "isolated soak did not attest unchanged system networking"

requested=$(field "$metadata" requested_duration_seconds)
packet_cycles=$(field "$metadata" packet_cycles_per_round)
round_timeout=$(field "$metadata" round_timeout_seconds)
flow_rss_budget=$(field "$metadata" flow_rss_budget_bytes)
packet_rss_budget=$(field "$metadata" packet_rss_budget_bytes)
fd_growth_budget=0
if [ "$schema" = 2 ]; then
  fd_growth_budget=$(field "$metadata" fd_growth_budget)
fi
for pair in \
  "requested_duration_seconds:$requested" \
  "packet_cycles_per_round:$packet_cycles" \
  "round_timeout_seconds:$round_timeout" \
  "flow_rss_budget_bytes:$flow_rss_budget" \
  "packet_rss_budget_bytes:$packet_rss_budget"
do
  require_uint "${pair%%:*}" "${pair#*:}"
done
require_uint fd_growth_budget "$fd_growth_budget"
test "$requested" -ge 60 || fail "requested duration is shorter than 60 seconds"
test "$packet_cycles" -gt 0 || fail "packet cycle count must be positive"

test "$(field "$result" status)" = passed || fail "result is not passed"
actual_duration=$(field "$result" actual_duration_seconds)
rounds=$(field "$result" rounds)
flow_cycles=$(field "$result" flow_lifecycle_cycles)
packet_total=$(field "$result" packet_lifecycle_cycles)
flow_peak=$(field "$result" flow_peak_rss_bytes)
packet_peak=$(field "$result" packet_peak_rss_bytes)
flow_fd_peak=0
packet_fd_peak=0
if [ "$schema" = 2 ]; then
  flow_fd_peak=$(field "$result" flow_peak_fd_growth)
  packet_fd_peak=$(field "$result" packet_peak_fd_growth)
fi
for pair in \
  "actual_duration_seconds:$actual_duration" "rounds:$rounds" \
  "flow_lifecycle_cycles:$flow_cycles" "packet_lifecycle_cycles:$packet_total" \
  "flow_peak_rss_bytes:$flow_peak" "packet_peak_rss_bytes:$packet_peak"
do
  require_uint "${pair%%:*}" "${pair#*:}"
done
require_uint flow_peak_fd_growth "$flow_fd_peak"
require_uint packet_peak_fd_growth "$packet_fd_peak"
test "$rounds" -gt 0 || fail "result contains no completed rounds"
test "$actual_duration" -ge "$requested" \
  || fail "actual duration is shorter than requested"
test "$actual_duration" -le $((requested + round_timeout * 2)) \
  || fail "actual duration exceeds the bounded final round allowance"
test "$flow_cycles" -eq $((rounds * 500)) \
  || fail "FlowOnly lifecycle total does not match the round count"
test "$packet_total" -eq $((rounds * packet_cycles)) \
  || fail "PacketFlow lifecycle total does not match the round count"

metrics=$(awk -F '\t' \
  -v rounds="$rounds" \
  -v packet_cycles="$packet_cycles" \
  -v flow_rss_budget="$flow_rss_budget" \
  -v packet_rss_budget="$packet_rss_budget" \
  -v round_timeout="$round_timeout" \
  -v flow_wall_budget="$FLOW_WALL_BUDGET" \
  -v packet_wall_budget="$PACKET_WALL_BUDGET" \
  -v schema="$schema" \
  -v fd_growth_budget="$fd_growth_budget" '
  BEGIN {
    expected_header="round\tengine\tcompleted_utc\twall_seconds\tcycles\tmax_rss_bytes\tresult_sha256"
    if (schema == 2) expected_header=expected_header "\tfd_growth"
  }
  NR == 1 {
    if ($0 != expected_header) {
      print "unexpected TSV header" > "/dev/stderr"
      exit 1
    }
    next
  }
  {
    expected_fields=(schema == 2 ? 8 : 7)
    if (NF != expected_fields || $1 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ ||
        $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/ ||
        $7 !~ /^[0-9a-f]{64}$/ || $1 < 1 || $1 > rounds) {
      print "invalid TSV row at line " NR > "/dev/stderr"
      exit 1
    }
    if (schema == 2) {
      if ($8 !~ /^-?[0-9]+$/ || $8 > fd_growth_budget) {
        print "file descriptor budget failed at line " NR > "/dev/stderr"
        exit 1
      }
      if ($2 == "flow" && $8 > flow_fd_peak) flow_fd_peak=$8
      if ($2 == "packet" && $8 > packet_fd_peak) packet_fd_peak=$8
    }
    key=$1 SUBSEP $2
    seen[key]++
    per_round[$1]++
    rows++
    if ($4 > round_timeout) {
      print "round timeout exceeded at line " NR > "/dev/stderr"
      exit 1
    }
    if ($2 == "flow") {
      if ($5 != 500 || $4 > flow_wall_budget || $6 > flow_rss_budget) {
        print "FlowOnly performance budget failed at line " NR > "/dev/stderr"
        exit 1
      }
      if ($6 > flow_peak) flow_peak=$6
    } else if ($2 == "packet") {
      if ($5 != packet_cycles || $4 > packet_wall_budget || $6 > packet_rss_budget) {
        print "PacketFlow performance budget failed at line " NR > "/dev/stderr"
        exit 1
      }
      if ($6 > packet_peak) packet_peak=$6
    } else {
      print "unknown engine at line " NR > "/dev/stderr"
      exit 1
    }
  }
  END {
    if (rows != rounds * 2) exit 1
    for (round=1; round<=rounds; round++) {
      if (per_round[round] != 2 || seen[round SUBSEP "flow"] != 1 ||
          seen[round SUBSEP "packet"] != 1) exit 1
    }
    print flow_peak, packet_peak, flow_fd_peak+0, packet_fd_peak+0
  }
' "$OUTPUT/rounds.tsv") || fail "round matrix or performance budget is invalid"
set -- $metrics
test "$#" -eq 4 || fail "could not derive peak RSS/FD values"
test "$1" -eq "$flow_peak" || fail "FlowOnly peak RSS does not match result"
test "$2" -eq "$packet_peak" || fail "PacketFlow peak RSS does not match result"
test "$3" -eq "$flow_fd_peak" || fail "FlowOnly peak FD growth does not match result"
test "$4" -eq "$packet_fd_peak" || fail "PacketFlow peak FD growth does not match result"

printf '%s\n' \
  "Isolated soak evidence verified: schema=$schema rounds=$rounds duration=${actual_duration}s flow_wall<=${FLOW_WALL_BUDGET}s packet_wall<=${PACKET_WALL_BUDGET}s flow_peak=$flow_peak packet_peak=$packet_peak flow_fd_peak=$flow_fd_peak packet_fd_peak=$packet_fd_peak"
