#!/bin/bash
# ==============================================================================
# AetherRoute 3-Hour Continuous Telemetry & Incident Monitor Control Script
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/outputs/monitor_3h"
PID_FILE="$OUTPUT_DIR/monitor.pid"
PYTHON_SCRIPT="$SCRIPT_DIR/monitor_aetherroute_3h.py"
SUMMARY_FILE="$OUTPUT_DIR/status_summary.json"
DASHBOARD_FILE="$OUTPUT_DIR/dashboard.md"
LOG_FILE="$OUTPUT_DIR/monitor.log"

mkdir -p "$OUTPUT_DIR"

is_running() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

case "$1" in
    start)
        if is_running; then
            PID=$(cat "$PID_FILE")
            echo "⚠️  AetherRoute 3h monitor is ALREADY running (PID: $PID)."
            echo "   View status: ./scripts/run_monitor_3h.sh status"
            echo "   View dashboard: cat outputs/monitor_3h/dashboard.md"
            exit 0
        fi

        INTERVAL=${2:-60}
        DURATION=${3:-3.0}
        TARGET_SAMPLES=$(python3 -c "print(int(float('$DURATION') * 3600 / int('$INTERVAL')))")

        echo "🚀 Starting AetherRoute 3-Hour Monitor (Interval: ${INTERVAL}s, Target: ${DURATION}h, ${TARGET_SAMPLES} samples)..."
        nohup /usr/bin/python3 "$PYTHON_SCRIPT" --interval "$INTERVAL" --duration-hours "$DURATION" --output-dir "$OUTPUT_DIR" >> "$OUTPUT_DIR/monitor_stdout.log" 2>&1 &
        BG_PID=$!

        sleep 2
        if kill -0 "$BG_PID" 2>/dev/null; then
            echo "$BG_PID" > "$PID_FILE"
            echo "✅ 3-Hour monitor successfully started in background!"
            echo "   PID: $BG_PID"
            echo "   Interval: ${INTERVAL}s (1 sample per minute)"
            echo "   Target duration: ${DURATION} hours (${TARGET_SAMPLES} samples)"
            echo "   Output directory: $OUTPUT_DIR"
            echo "   Live Dashboard: $DASHBOARD_FILE"
            echo "   Log File: $LOG_FILE"
            echo ""
            echo "To inspect live status:"
            echo "   ./scripts/run_monitor_3h.sh status"
            echo "To stop early:"
            echo "   ./scripts/run_monitor_3h.sh stop"
        else
            echo "❌ Failed to start monitor daemon. Check logs at $OUTPUT_DIR/monitor_stdout.log"
            exit 1
        fi
        ;;

    status)
        if is_running; then
            PID=$(cat "$PID_FILE")
            echo "🟢 3-Hour Monitor daemon is RUNNING (PID: $PID)"
            if [ -f "$SUMMARY_FILE" ]; then
                echo "--------------------------------------------------------"
                /usr/bin/python3 - "$SUMMARY_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    st = d.get('status', 'UNKNOWN')
    c = d.get('samples_collected', 0)
    t = d.get('target_samples', 0)
    pct = d.get('progress_percent', 0)
    upt = d.get('elapsed_hours', 0)
    inc = d.get('total_incidents', 0)
    mode = d.get('active_mode', 'unknown')
    app_rss = d.get('latest_rss_mb', {}).get('app', 0)
    app_foot = d.get('latest_footprint_mb', {}).get('app', 0)
    app_cpu = d.get('latest_cpu', {}).get('app', 0)
    prx_rss = d.get('latest_rss_mb', {}).get('proxy', 0)
    prx_cpu = d.get('latest_cpu', {}).get('proxy', 0)
    tun_rss = d.get('latest_rss_mb', {}).get('tunnel', 0)
    dns = d.get('probes', {}).get('dns_latency_ms', 'N/A')
    http = d.get('probes', {}).get('http_latency_ms', 'N/A')
    http_st = d.get('probes', {}).get('http_status', 'N/A')

    print(f"Status:           {st} (Mode: {mode})")
    print(f"Cycles Collected: {c} / {t} ({pct}%)")
    print(f"Elapsed:          {upt} hours")
    print(f"Total Incidents:  {inc}")
    print(f"App Resource:     RSS: {app_rss} MB | Footprint: {app_foot} MB | CPU: {app_cpu}%")
    if prx_rss > 0:
        print(f"Proxy Engine:     RSS: {prx_rss} MB | CPU: {prx_cpu}%")
    if tun_rss > 0:
        print(f"Tunnel Engine:    RSS: {tun_rss} MB")
    print(f"Latency Probes:   DNS: {dns} ms | HTTP: {http} ms (HTTP {http_st})")
except Exception as e:
    print("Could not parse status_summary.json:", e)
PY
                echo "--------------------------------------------------------"
            fi
            echo "📄 Live dashboard available at: $DASHBOARD_FILE"
        else
            echo "🔴 3-Hour Monitor daemon is NOT running."
            if [ -f "$SUMMARY_FILE" ]; then
                echo "Last known summary state:"
                cat "$SUMMARY_FILE"
            fi
        fi
        ;;

    dashboard)
        if [ -f "$DASHBOARD_FILE" ]; then
            cat "$DASHBOARD_FILE"
        else
            echo "No dashboard file found at $DASHBOARD_FILE"
        fi
        ;;

    stop)
        if is_running; then
            PID=$(cat "$PID_FILE")
            echo "🛑 Stopping 3-Hour monitor daemon (PID: $PID)..."
            kill -TERM "$PID" 2>/dev/null || true
            for _ in {1..10}; do
                if ! kill -0 "$PID" 2>/dev/null; then
                    break
                fi
                sleep 0.5
            done
            if kill -0 "$PID" 2>/dev/null; then
                kill -KILL "$PID" 2>/dev/null || true
            fi
            rm -f "$PID_FILE"
            echo "✅ Monitor daemon stopped."
        else
            echo "Monitor daemon is not currently running."
            rm -f "$PID_FILE"
        fi
        ;;

    report)
        echo "========================================================"
        echo "📊 AetherRoute 3-Hour Monitor Report Summary"
        echo "========================================================"
        if [ -f "$SUMMARY_FILE" ]; then
            cat "$SUMMARY_FILE"
        else
            echo "No summary file found. Run monitor first."
        fi
        if [ -f "$OUTPUT_DIR/incidents.jsonl" ]; then
            INC_COUNT=$(wc -l < "$OUTPUT_DIR/incidents.jsonl" | tr -d ' ')
            echo ""
            echo "Total Incidents Recorded: $INC_COUNT"
            if [ "$INC_COUNT" -gt 0 ]; then
                echo "Last 5 Incidents:"
                tail -n 5 "$OUTPUT_DIR/incidents.jsonl"
            fi
        fi
        ;;

    *)
        echo "Usage: $0 {start|status|dashboard|stop|report} [interval_seconds] [duration_hours]"
        echo ""
        echo "Examples:"
        echo "  $0 start           # Start 3-hour monitor (60s interval, 180 samples)"
        echo "  $0 status          # Inspect current progress, memory, CPU, and incidents"
        echo "  $0 dashboard       # View the generated Markdown dashboard"
        echo "  $0 stop            # Stop the monitor"
        echo "  $0 report          # Print full JSON summary and incident log"
        exit 1
        ;;
esac
