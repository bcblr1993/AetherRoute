#!/bin/bash
# ==============================================================================
# AetherRoute 48-Hour Continuous Telemetry & Incident Monitor Control Script
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/outputs/monitor_48h"
PID_FILE="$OUTPUT_DIR/monitor.pid"
PYTHON_SCRIPT="$SCRIPT_DIR/monitor_aetherroute_48h.py"
SUMMARY_FILE="$OUTPUT_DIR/status_summary.json"
DASHBOARD_FILE="$OUTPUT_DIR/dashboard.md"
LOG_FILE="$OUTPUT_DIR/monitor.log"

mkdir -p "$OUTPUT_DIR"

is_running() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

case "$1" in
    start)
        if is_running; then
            echo "⚠️  AetherRoute monitor is ALREADY running (PID: $(cat "$PID_FILE"))."
            echo "   View status: ./scripts/run_monitor.sh status"
            echo "   View dashboard: cat outputs/monitor_48h/dashboard.md"
            exit 0
        fi

        INTERVAL=${2:-300}
        DURATION=${3:-48}
        TARGET_SAMPLES=$(( DURATION * 3600 / INTERVAL ))
        INTERVAL_MIN=$(( INTERVAL / 60 ))

        echo "🚀 Starting AetherRoute ${DURATION}-Hour Continuous Monitor..."
        nohup /usr/bin/python3 "$PYTHON_SCRIPT" --interval "$INTERVAL" --duration-hours "$DURATION" --output-dir "$OUTPUT_DIR" >> "$OUTPUT_DIR/monitor_stdout.log" 2>&1 &
        BG_PID=$!

        sleep 2
        if kill -0 "$BG_PID" 2>/dev/null; then
            echo "$BG_PID" > "$PID_FILE"
            echo "✅ Monitor successfully started in background!"
            echo "   PID: $BG_PID"
            echo "   Interval: ${INTERVAL}s (${INTERVAL_MIN} minutes)"
            echo "   Target duration: ${DURATION} hours (${TARGET_SAMPLES} samples)"
            echo "   Outputs: $OUTPUT_DIR"
            echo "   Live Dashboard: $DASHBOARD_FILE"
        else
            echo "❌ Failed to start monitor daemon. Check logs at $OUTPUT_DIR/monitor_stdout.log"
            exit 1
        fi
        ;;

    status)
        if is_running; then
            PID=$(cat "$PID_FILE")
            echo "🟢 Monitor daemon is RUNNING (PID: $PID)"
            if [ -f "$SUMMARY_FILE" ]; then
                echo "--------------------------------------------------------"
                /usr/bin/python3 -c '
import json, sys
try:
    with open("'"$SUMMARY_FILE"'") as f:
        d = json.load(f)
    sc = d.get("samples_collected", 0)
    target = d.get("target_samples_48h", 576)
    interval = d.get("interval_seconds", 300)
    eh = d.get("elapsed_hours", 0)
    last_up = d.get("last_updated", "N/A")
    inc = d.get("total_incidents", 0)
    pids = d.get("active_pids", {})
    pid_app = pids.get("app")
    pid_tun = pids.get("tunnel")
    pid_prx = pids.get("proxy")
    m = d.get("latest_metrics", {})
    app_rss = m.get("app_rss_mb", 0)
    tun_rss = m.get("tunnel_rss_mb", 0)
    dns_lat = m.get("dns_latency_ms", 0)
    http_lat = m.get("http_latency_ms", 0)
    print(f"Cycles:          {sc} / {target} ({eh:.2f}h elapsed, interval {interval}s)")
    print(f"Last updated:    {last_up}")
    print(f"Total Incidents: {inc}")
    print(f"PIDs:            App={pid_app} | Tunnel={pid_tun} | Proxy={pid_prx}")
    print(f"App RSS Memory:  {app_rss} MB")
    print(f"Tunnel RSS:      {tun_rss} MB")
    print(f"DNS Latency:     {dns_lat} ms")
    print(f"HTTP Latency:    {http_lat} ms")
except Exception as e:
    print(f"Error reading summary: {e}")
'
                echo "--------------------------------------------------------"
            fi
        else
            echo "⚪ Monitor daemon is NOT running."
            if [ -f "$SUMMARY_FILE" ]; then
                echo "Last recorded state was in $SUMMARY_FILE"
            fi
        fi
        ;;

    stop)
        if is_running; then
            PID=$(cat "$PID_FILE")
            echo "🛑 Stopping AetherRoute monitor (PID: $PID)..."
            kill -TERM "$PID" 2>/dev/null
            for i in {1..10}; do
                if ! kill -0 "$PID" 2>/dev/null; then
                    break
                fi
                sleep 1
            done
            if kill -0 "$PID" 2>/dev/null; then
                echo "⚠️  Process did not stop cleanly, sending SIGKILL..."
                kill -9 "$PID" 2>/dev/null
            fi
            rm -f "$PID_FILE"
            echo "✅ Monitor stopped."
        else
            echo "⚪ Monitor is not running."
            rm -f "$PID_FILE"
        fi
        ;;

    dashboard)
        if [ -f "$DASHBOARD_FILE" ]; then
            cat "$DASHBOARD_FILE"
        else
            echo "Dashboard file not found at $DASHBOARD_FILE"
        fi
        ;;

    once)
        /usr/bin/python3 "$PYTHON_SCRIPT" --once --output-dir "$OUTPUT_DIR"
        ;;

    logs)
        tail -n 30 "$LOG_FILE"
        ;;

    *)
        echo "Usage: $0 {start|status|stop|dashboard|once|logs}"
        exit 1
        ;;
esac
