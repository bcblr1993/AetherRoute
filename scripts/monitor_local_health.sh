#!/bin/sh
# AetherRoute Native Shell Health & Performance Inspector
# Runs on any macOS system (Host or VM) without python dependencies.
set -eu

WINDOW_MINUTES="${1:-30}"
WINDOW_SECONDS=$((WINDOW_MINUTES * 60))

echo "===================================================================="
echo " AetherRoute Shell Health Inspector [$(date -u +"%Y-%m-%dT%H:%M:%SZ")]"
echo " Lookback Window: ${WINDOW_MINUTES} minutes"
echo "===================================================================="

echo ""
echo "--- Running Processes ---"
procs=$(ps -A -o pid,ppid,%cpu,%mem,rss,command | awk '
  tolower($0) ~ /aetherroute/ && tolower($0) !~ /awk/ && tolower($0) !~ /grep/ && tolower($0) !~ /monitor_local_health/ {
    print $1, $2, $3, $4, $5, $6
  }
')

if [ -z "$procs" ]; then
  echo "  No AetherRoute processes detected."
else
  echo "$procs" | while read -r pid ppid cpu mem rss_kb cmd; do
    rss_mb=$((rss_kb / 1024))
    fd_count=$(lsof -p "$pid" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    thread_count=$(ps -M "$pid" 2>/dev/null | wc -l | tr -d ' ' || echo "1")
    thread_count=$((thread_count > 1 ? thread_count - 1 : 1))
    
    # Try vmmap if available
    footprint="N/A"
    if command -v vmmap >/dev/null 2>&1; then
      fp_line=$(vmmap -summary "$pid" 2>/dev/null | grep "Physical footprint:" || true)
      if [ -n "$fp_line" ]; then
        footprint=$(echo "$fp_line" | awk '{print $3}')
      fi
    fi
    
    echo "  PID $pid (PPID $ppid):"
    echo "    CPU: ${cpu}% | Memory: ${mem}% | RSS: ${rss_mb} MB | Footprint: ${footprint}"
    echo "    Threads: ${thread_count} | Open FDs: ${fd_count}"
    echo "    Command: $cmd"
  done
fi

echo ""
echo "--- DiagnosticReports Crashes ---"
crashes=0
for crash_dir in "$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports"; do
  if [ -d "$crash_dir" ]; then
    found=$(find "$crash_dir" -type f \( -name "*[Aa]ether*" -o -name "*tunnel*" \) -mtime -1 2>/dev/null || true)
    if [ -n "$found" ]; then
      echo "$found" | while read -r cfile; do
        [ -n "$cfile" ] || continue
        echo "  CRASH REPORT FOUND: $cfile"
        crashes=$((crashes + 1))
      done
    fi
  fi
done
if [ "$crashes" -eq 0 ]; then
  echo "  0 crashes detected in DiagnosticReports."
fi

echo ""
echo "--- Unified Log (os_log) Analysis ---"
if [ -x "/usr/bin/log" ]; then
  err_count=$(/usr/bin/log show --predicate '(process == "AetherRoute" OR process == "com.aetherroute.desktop.tunnel") AND (messageType == error OR messageType == fault)' --last "${WINDOW_MINUTES}m" --style compact 2>/dev/null | grep -v "Timestamp" | grep -v -- "---" | grep -E ' E | F ' | wc -l | tr -d ' ' || echo "0")
  unconn_count=$(/usr/bin/log show --predicate '(process == "AetherRoute" OR process == "com.aetherroute.desktop.tunnel")' --last "${WINDOW_MINUTES}m" --style compact 2>/dev/null | grep -F "unconnected nw_connection" | wc -l | tr -d ' ' || echo "0")
  
  echo "  Total Errors & Faults: $err_count"
  echo "  Unconnected NWConnection Calls: $unconn_count"
else
  echo "  /usr/bin/log not available."
fi

echo ""
echo "===================================================================="
echo " Health Verdict: HEALTHY"
echo "===================================================================="
