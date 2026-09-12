#!/usr/bin/env python3
"""
Quick status checker for the Continuous Stability Observer.
Reads reports/diagnostics/continuous_stability_status.json and prints a formatted summary.
"""

import json
import os
import sys
from pathlib import Path

STATUS_FILE = Path("reports/diagnostics/continuous_stability_status.json")
ALERT_FILE = Path("reports/diagnostics/continuous_stability_alerts.log")

def main():
    if not STATUS_FILE.exists():
        print(f"Status file not found: {STATUS_FILE}. Observer may not be running yet.")
        sys.exit(1)

    try:
        with open(STATUS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"Failed to read status file: {e}")
        sys.exit(1)

    print("====================================================================")
    print(f" AetherRoute Continuous Stability Status [{data.get('lastUpdated', 'N/A')}]")
    print(f" Health Verdict: {data.get('verdict', 'UNKNOWN')}")
    print("====================================================================")

    elapsed_s = data.get("elapsedSeconds", 0)
    target_s = data.get("targetDurationSeconds", 86400)
    progress = data.get("progressPercent", 0.0)
    h = elapsed_s // 3600
    m = (elapsed_s % 3600) // 60
    s = elapsed_s % 60
    print(f"Elapsed Time: {h}h {m}m {s}s / {target_s//3600}h ({progress:.1f}%) | Samples: {data.get('totalSamples', 0)}")

    curr = data.get("currentMetrics", {})
    app = curr.get("app") or {}
    tun = curr.get("tunnel") or {}
    probe = curr.get("probe") or {}

    print("\n--- Current Process State ---")
    app_fp = f"{app.get('footprint_mb')} MB" if app.get('footprint_mb') is not None else f"{app.get('rss_mb')} MB(rss)"
    print(f"  [APP]    PID: {app.get('pid', 'N/A')} | CPU: {app.get('cpu', 0.0)}% | Footprint: {app_fp} | RSS: {app.get('rss_mb', 0.0)} MB | FDs: {app.get('fds', 0)}")
    print(f"  [TUNNEL] PID: {tun.get('pid', 'N/A')} | CPU: {tun.get('cpu', 0.0)}% | RSS: {tun.get('rss_mb', 0.0)} MB | Threads: {tun.get('threads', 0)}")
    print(f"  [PROBE]  Status: {probe.get('http_code', 'N/A')} | Latency: {probe.get('latency', -1.0):.3f}s")

    agg = data.get("aggregates", {})
    print("\n--- Aggregate Stability Metrics ---")
    print(f"  App Footprint: Initial {agg.get('appFootprintInitialMB')} MB -> Current {agg.get('appFootprintCurrentMB')} MB (Delta: {agg.get('appFootprintDeltaMB', 0.0):+0.2f} MB)")
    print(f"  Tunnel RSS:    Initial {agg.get('tunnelRSSInitialMB')} MB -> Current {agg.get('tunnelRSSCurrentMB')} MB (Delta: {agg.get('tunnelRSSDeltaMB', 0.0):+0.2f} MB)")
    print(f"  App CPU:       Avg {agg.get('avgAppCPU', 0.0)}% | Max {agg.get('maxAppCPU', 0.0)}%")
    print(f"  Tunnel CPU:    Avg {agg.get('avgTunnelCPU', 0.0)}% | Max {agg.get('maxTunnelCPU', 0.0)}%")
    print(f"  Probe Health:  Success {agg.get('probeSuccessRatePercent', 100.0)}% | Avg Latency: {agg.get('avgProbeLatencySeconds', 0.0):.3f}s")
    print(f"  Total Errors:  {agg.get('totalErrors', 0)} | Total Crashes: {agg.get('totalCrashes', 0)}")

    if ALERT_FILE.exists():
        with open(ALERT_FILE, "r", encoding="utf-8") as f:
            alerts = [l.strip() for l in f if l.strip()]
        if alerts:
            print(f"\n🚨 Recent Alerts ({len(alerts)} total):")
            for a in alerts[-5:]:
                print(f"  {a}")
        else:
            print("\n  0 alerts recorded.")
    else:
        print("\n  0 alerts recorded.")

    print("====================================================================")

if __name__ == "__main__":
    main()
