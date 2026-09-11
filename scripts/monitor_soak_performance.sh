#!/bin/sh
set -eu

SOAK_DIR=${1:-}
if [ -z "$SOAK_DIR" ]; then
  echo "usage: $0 /path/to/soak-output-dir" >&2
  exit 1
fi

METRICS_CSV="$SOAK_DIR/performance_metrics.csv"
METRICS_LOG="$SOAK_DIR/performance_metrics.log"

echo "timestamp,round,engine,wall_seconds,cycles,max_rss_mb,fd_growth,system_load" > "$METRICS_CSV"
echo "=== Soak Performance Monitoring Started at $(date -u '+%Y-%m-%dT%H:%M:%SZ') ===" > "$METRICS_LOG"

ROUNDS_FILE="$SOAK_DIR/rounds.tsv"

# Wait for rounds.tsv to be created
while [ ! -f "$ROUNDS_FILE" ]; do
  sleep 2
done

last_line_count=1

while :; do
  current_lines=$(wc -l < "$ROUNDS_FILE" 2>/dev/null || echo 0)
  if [ "$current_lines" -gt "$last_line_count" ]; then
    # Process new rounds
    tail -n +$((last_line_count + 1)) "$ROUNDS_FILE" | while IFS="$(printf '\t')" read -r round engine completed_utc wall_seconds cycles max_rss_bytes result_sha256 fd_growth; do
      [ -n "$round" ] || continue
      max_rss_mb=$(awk "BEGIN {printf \"%.2f\", $max_rss_bytes / 1048576}")
      load=$(uptime | awk -F'load averages?: ' '{print $2}' | awk '{print $1}')
      ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      
      echo "$ts,$round,$engine,$wall_seconds,$cycles,$max_rss_mb,$fd_growth,$load" >> "$METRICS_CSV"
      printf '[%s] Round %-5s (%-7s) Wall: %3ss | Cycles: %4s | RSS: %6s MB | FD Growth: %2s | Load: %s\n' \
        "$ts" "$round" "$engine" "$wall_seconds" "$cycles" "$max_rss_mb" "$fd_growth" "$load" >> "$METRICS_LOG"
    done
    last_line_count=$current_lines
  fi

  # Check if soak finished (result.txt created)
  if [ -f "$SOAK_DIR/result.txt" ]; then
    echo "=== Soak Test Completed at $(date -u '+%Y-%m-%dT%H:%M:%SZ') ===" >> "$METRICS_LOG"
    break
  fi

  sleep 10
done
