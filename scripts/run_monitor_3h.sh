#!/bin/bash
# ==============================================================================
# AetherRoute 3-Hour Continuous Telemetry & Incident Monitor (v1.0.17)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/outputs/monitor_3h_v1.0.17"
PID_FILE="$OUTPUT_DIR/monitor.pid"
PYTHON_SCRIPT="$SCRIPT_DIR/monitor_aetherroute_10h.py"
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
            echo "⚠️  AetherRoute 3h monitor is ALREADY running (PID: $(cat "$PID_FILE"))."
            echo "   View status: ./scripts/run_monitor_3h.sh status"
            echo "   View dashboard: cat outputs/monitor_3h_v1.0.17/dashboard.md"
            exit 0
        fi

        INTERVAL=${2:-120}
        DURATION=${3:-3}
        TARGET_SAMPLES=$(( DURATION * 3600 / INTERVAL ))
        INTERVAL_MIN=$(( INTERVAL / 60 ))

        echo "🚀 Starting AetherRoute v1.0.17 ${DURATION}-Hour Continuous Monitor (interval: ${INTERVAL}s / ${INTERVAL_MIN}m)..."
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
                /usr/bin/python3 - "$SUMMARY_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    c = d.get('samples_collected', 0)
    t = d.get('target_samples', 0)
    pct = d.get('progress_percent', 0)
    upt = d.get('uptime_hours', 0)
    st = d.get('start_time', '')
    inc = d.get('total_incidents', 0)
    app_rss = d.get('latest_rss_mb', {}).get('app', 0)
    app_foot = d.get('latest_footprint_mb', {}).get('app', 0)
    app_cpu = d.get('latest_cpu', {}).get('app', 0)
    tun_rss = d.get('latest_rss_mb', {}).get('tunnel', 0)
    tun_cpu = d.get('latest_cpu', {}).get('tunnel', 0)
    prx_rss = d.get('latest_rss_mb', {}).get('proxy', 0)
    tcp = d.get('latest_tcp_states', {})
    print(f"Cycles Collected: {c} / {t} ({pct}%)")
    print(f"Elapsed:          {upt} hours (Started: {st})")
    print(f"Total Incidents:  {inc}")
    print(f"App RSS:          {app_rss} MB (Footprint: {app_foot} MB, CPU: {app_cpu}%)")
    print(f"Tunnel RSS:       {tun_rss} MB (CPU: {tun_cpu}%)")
    print(f"Proxy RSS:        {prx_rss} MB")
    print(f"TCP Gateway:      {tcp}")
except Exception as e:
    print("Could not parse status_summary.json:", e)
PY
                echo "--------------------------------------------------------"
            fi
            echo "Live dashboard available at: outputs/monitor_3h_v1.0.17/dashboard.md"
        else
            echo "🔴 Monitor daemon is NOT running."
            if [ -f "$SUMMARY_FILE" ]; then
                echo "Last known state:"
                cat "$SUMMARY_FILE"
            fi
        fi
        ;;

    stop)
        if is_running; then
            PID=$(cat "$PID_FILE")
            echo "🛑 Stopping monitor daemon (PID: $PID)..."
            kill -15 "$PID" 2>/dev/null || kill -9 "$PID" 2>/dev/null
            sleep 1
            if ! kill -0 "$PID" 2>/dev/null; then
                rm -f "$PID_FILE"
                echo "✅ Monitor daemon stopped."
            else
                kill -9 "$PID" 2>/dev/null
                rm -f "$PID_FILE"
                echo "⚠️ Force killed monitor daemon."
            fi
        else
            echo "⚠️ Monitor daemon is not running."
            rm -f "$PID_FILE"
        fi
        ;;

    dashboard)
        if [ -f "$DASHBOARD_FILE" ]; then
            cat "$DASHBOARD_FILE"
        else
            echo "No dashboard file found at $DASHBOARD_FILE."
        fi
        ;;

    reset)
        $0 stop
        echo "🧹 Cleaning monitor data at $OUTPUT_DIR..."
        rm -rf "$OUTPUT_DIR"/*
        echo "✅ Output directory reset."
        ;;

    *)
        echo "Usage: $0 {start|status|stop|dashboard|reset} [interval_seconds] [duration_hours]"
        echo "Example: $0 start 120 10    # Start 10-hour monitor with 2-minute interval"
        exit 1
        ;;
esac
