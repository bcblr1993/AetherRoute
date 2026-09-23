#!/usr/bin/env bash
# ==============================================================================
# AetherRoute 1-Minute Performance & Anomaly Monitor Control Script
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${ROOT_DIR}/reports/monitoring"
PID_FILE="${OUT_DIR}/monitor.pid"
LOG_FILE="${OUT_DIR}/monitor.log"

mkdir -p "${OUT_DIR}"

usage() {
    echo "Usage: $0 {start|stop|status|report|once|tail|clean} [options]"
    echo ""
    echo "Commands:"
    echo "  start [hours]   Start minute-by-minute monitor daemon in background (default: indefinite, or specify hours e.g. 24)"
    echo "  stop            Stop running monitor daemon and generate final report"
    echo "  status          Show monitor daemon running status and latest metrics"
    echo "  report          Generate Markdown analysis report from collected metrics"
    echo "  once            Perform a single inspection immediately and print health verdict"
    echo "  tail            Tail monitor logs in real-time"
    echo "  clean           Archive current monitoring records to start fresh"
    exit 1
}

is_running() {
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid=$(cat "${PID_FILE}")
        if ps -p "${pid}" > /dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

cmd_start() {
    if is_running; then
        local pid
        pid=$(cat "${PID_FILE}")
        echo "Monitor daemon is already running (PID: ${pid})."
        exit 0
    fi

    local hours="${1:-0}"
    local py_script="${SCRIPT_DIR}/monitor_aetherroute_daemon.py"
    local cmd="python3 -u ${py_script} --output-dir ${OUT_DIR} --interval 60"
    if [[ "${hours}" != "0" ]]; then
        cmd="${cmd} --hours ${hours}"
    fi

    echo "Starting AetherRoute 1-minute monitor daemon..."
    nohup ${cmd} > "${LOG_FILE}" 2>&1 &
    local new_pid=$!
    echo "${new_pid}" > "${PID_FILE}"

    sleep 2
    if ps -p "${new_pid}" > /dev/null 2>&1; then
        echo "✅ Monitor daemon started successfully (PID: ${new_pid})."
        echo "   Logs: ${LOG_FILE}"
        echo "   Metrics CSV: ${OUT_DIR}/metrics_minute.csv"
        if [[ "${hours}" != "0" ]]; then
            echo "   Auto-stop planned after: ${hours} hour(s)"
        fi
    else
        echo "❌ Failed to start monitor daemon. Check log:"
        tail -n 20 "${LOG_FILE}"
        rm -f "${PID_FILE}"
        exit 1
    fi
}

cmd_stop() {
    if ! is_running; then
        echo "Monitor daemon is not running."
        rm -f "${PID_FILE}"
        exit 0
    fi

    local pid
    pid=$(cat "${PID_FILE}")
    echo "Stopping monitor daemon (PID: ${pid})..."
    kill -TERM "${pid}" 2>/dev/null || true

    local count=0
    while ps -p "${pid}" > /dev/null 2>&1; do
        sleep 1
        count=$((count + 1))
        if [[ ${count} -ge 10 ]]; then
            echo "Force killing (PID: ${pid})..."
            kill -9 "${pid}" 2>/dev/null || true
            break
        fi
    done

    rm -f "${PID_FILE}"
    echo "✅ Monitor daemon stopped."
    echo "Generating latest summary report..."
    python3 "${SCRIPT_DIR}/generate_monitor_report.py" --dir "${OUT_DIR}"
}

cmd_status() {
    echo "================================================================================"
    if is_running; then
        local pid
        pid=$(cat "${PID_FILE}")
        echo " Monitor Daemon: 🟢 RUNNING (PID: ${pid})"
    else
        echo " Monitor Daemon: ⚪ STOPPED"
    fi
    echo "================================================================================"

    local csv_file="${OUT_DIR}/metrics_minute.csv"
    if [[ -f "${csv_file}" ]]; then
        local total_lines
        total_lines=$(wc -l < "${csv_file}")
        local samples=$((total_lines - 1))
        echo " Total Samples Recorded: ${samples}"
        echo ""
        echo "--- Last 5 Samples from metrics_minute.csv ---"
        tail -n 5 "${csv_file}" | awk -F"," '{printf "  [%s] Verdict:%-7s AppCPU:%-4s AppFP:%-6s TunCPU:%-4s TunRSS:%-6s PrxTotal:%-6s CW:%s Flags:%s\n", $1, $3, $6, $8, $12, $13, $24, $16, $4}'
    else
        echo " No metrics recorded yet."
    fi

    local inc_file="${OUT_DIR}/incidents.jsonl"
    if [[ -f "${inc_file}" ]]; then
        local inc_count
        inc_count=$(wc -l < "${inc_file}")
        echo ""
        echo " Incidents Logged: ${inc_count}"
        if [[ ${inc_count} -gt 0 ]]; then
            tail -n 3 "${inc_file}"
        fi
    fi
    echo "================================================================================"
}

cmd_report() {
    python3 "${SCRIPT_DIR}/generate_monitor_report.py" --dir "${OUT_DIR}"
}

cmd_once() {
    python3 "${SCRIPT_DIR}/monitor_aetherroute_daemon.py" --once --output-dir "${OUT_DIR}"
}

cmd_tail() {
    if [[ ! -f "${LOG_FILE}" ]]; then
        touch "${LOG_FILE}"
    fi
    tail -f "${LOG_FILE}"
}

cmd_clean() {
    if is_running; then
        echo "Please stop the daemon before cleaning."
        exit 1
    fi
    local stamp
    stamp=$(date +"%Y%m%d_%H%M%S")
    local backup_dir="${ROOT_DIR}/reports/archive_monitoring_${stamp}"
    echo "Archiving current monitoring records to: ${backup_dir}"
    mkdir -p "${backup_dir}"
    mv "${OUT_DIR}"/* "${backup_dir}/" 2>/dev/null || true
    echo "✅ Cleaned. Next start will begin with fresh metrics."
}

ACTION="${1:-}"
case "${ACTION}" in
    start)
        cmd_start "${2:-0}"
        ;;
    stop)
        cmd_stop
        ;;
    status)
        cmd_status
        ;;
    report)
        cmd_report
        ;;
    once)
        cmd_once
        ;;
    tail)
        cmd_tail
        ;;
    clean)
        cmd_clean
        ;;
    *)
        usage
        ;;
esac
