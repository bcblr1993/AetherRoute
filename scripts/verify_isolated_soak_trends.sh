#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-}
MIN_DURATION=${AETHERROUTE_SOAK_TREND_MIN_DURATION_SECONDS:-86400}
RSS_SLOPE_BUDGET=${AETHERROUTE_SOAK_RSS_SLOPE_BUDGET_BYTES_PER_HOUR:-1048576}

fail() {
  echo "Isolated soak trend failed: $*" >&2
  exit 1
}

case "$OUTPUT" in
  /*) ;;
  '') echo "usage: verify_isolated_soak_trends.sh /absolute/output/directory" >&2; exit 64 ;;
  *) OUTPUT="$PWD/$OUTPUT" ;;
esac
for pair in \
  "AETHERROUTE_SOAK_TREND_MIN_DURATION_SECONDS:$MIN_DURATION" \
  "AETHERROUTE_SOAK_RSS_SLOPE_BUDGET_BYTES_PER_HOUR:$RSS_SLOPE_BUDGET"
do
  label=${pair%%:*}
  value=${pair#*:}
  case "$value" in
    ''|*[!0-9]*) fail "$label must be an unsigned integer" ;;
  esac
done
test "$MIN_DURATION" -ge 60 && test "$MIN_DURATION" -le 93600 \
  || fail "minimum duration must be between 60 and 93600 seconds"
test "$RSS_SLOPE_BUDGET" -gt 0 \
  || fail "RSS slope budget must be positive"

"$ROOT/scripts/verify_isolated_soak_result.sh" "$OUTPUT" >/dev/null

field() {
  file=$1
  key=$2
  count=$(awk -F= -v key="$key" '$1 == key {count++} END {print count+0}' "$file")
  test "$count" -eq 1 || fail "$file must contain exactly one $key field"
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print}' "$file"
}

actual_duration=$(field "$OUTPUT/result.txt" actual_duration_seconds)
rounds=$(field "$OUTPUT/result.txt" rounds)
test "$actual_duration" -ge "$MIN_DURATION" \
  || fail "duration ${actual_duration}s is below required ${MIN_DURATION}s"
test "$rounds" -ge 20 \
  || fail "at least 20 complete rounds are required for trend analysis"

metrics=$(awk -F '\t' -v duration="$actual_duration" -v rounds="$rounds" '
  NR == 1 {next}
  $2 == "flow" {
    flow_count++
    flow_round[flow_count]=$1
    flow_rss[flow_count]=$6
  }
  $2 == "packet" {
    packet_count++
    packet_round[packet_count]=$1
    packet_rss[packet_count]=$6
  }
  function slope(count, x, y, start, samples, sum_x, sum_y, sum_xx,
                 sum_xy, sample_index, denominator, bytes_per_round,
                 seconds_per_round, bytes_per_hour) {
    start=int(count * 0.05) + 1
    if (start < 2) start=2
    for (sample_index=start; sample_index<=count; sample_index++) {
      samples++
      sum_x+=x[sample_index]
      sum_y+=y[sample_index]
      sum_xx+=x[sample_index] * x[sample_index]
      sum_xy+=x[sample_index] * y[sample_index]
    }
    if (samples < 10) return -1
    denominator=samples * sum_xx - sum_x * sum_x
    if (denominator <= 0) return -1
    bytes_per_round=(samples * sum_xy - sum_x * sum_y) / denominator
    seconds_per_round=duration / rounds
    if (seconds_per_round <= 0) return -1
    bytes_per_hour=bytes_per_round * 3600 / seconds_per_round
    if (bytes_per_hour < 0) bytes_per_hour=0
    return int(bytes_per_hour + 0.5)
  }
  END {
    if (flow_count != rounds || packet_count != rounds) exit 1
    flow_slope=slope(flow_count, flow_round, flow_rss)
    packet_slope=slope(packet_count, packet_round, packet_rss)
    if (flow_slope < 0 || packet_slope < 0) exit 1
    warmup_rows=int(rounds * 0.05)
    if (warmup_rows < 1) warmup_rows=1
    print flow_slope, packet_slope, warmup_rows, rounds-warmup_rows
  }
' "$OUTPUT/rounds.tsv") || fail "could not derive RSS trends"
set -- $metrics
test "$#" -eq 4 || fail "trend analysis returned incomplete metrics"
flow_slope=$1
packet_slope=$2
warmup_rows=$3
analyzed_rows=$4
test "$flow_slope" -le "$RSS_SLOPE_BUDGET" \
  || fail "FlowOnly RSS slope ${flow_slope} B/hour exceeds ${RSS_SLOPE_BUDGET}"
test "$packet_slope" -le "$RSS_SLOPE_BUDGET" \
  || fail "PacketFlow RSS slope ${packet_slope} B/hour exceeds ${RSS_SLOPE_BUDGET}"

printf '%s\n' \
  "Isolated soak trends verified: duration=${actual_duration}s rounds=$rounds warmup_rows=$warmup_rows analyzed_rows=$analyzed_rows flow_rss_slope_bytes_per_hour=$flow_slope packet_rss_slope_bytes_per_hour=$packet_slope budget=$RSS_SLOPE_BUDGET"
