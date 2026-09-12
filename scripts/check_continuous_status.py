#!/usr/bin/env python3
"""
Dashboard Viewer for AetherRoute Full-Spectrum Continuous Observability.
Reads reports/diagnostics/continuous_stability_status.json and presents a clean,
structured overview of Data Plane, System Resources, and Stability.
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

    verdict = data.get("verdict", "UNKNOWN")
    reasons = data.get("verdictReasons", [])
    symbol = "🟢" if verdict == "HEALTHY" else ("🟡" if verdict == "WARNING" else "🔴")

    print("==================================================================================")
    print(f" AetherRoute Full-Spectrum Observability Status [{data.get('lastUpdated', 'N/A')}]")
    print(f" Status Verdict: {symbol} {verdict} {f'({', '.join(reasons)})' if reasons else ''}")
    print("==================================================================================")

    elapsed_s = data.get("elapsedSeconds", 0)
    target_s = data.get("targetDurationSeconds", 129600)
    progress = data.get("progressPercent", 0.0)
    h = elapsed_s // 3600
    m = (elapsed_s % 3600) // 60
    s = elapsed_s % 60
    samples = data.get("totalSamples", 0)
    interval = data.get("samplingIntervalSeconds", 30)
    print(f"⏱️  Duration: {h}h {m}m {s}s / {target_s//3600}h ({progress:.1f}%) | Samples: {samples} (Every {interval}s)")

    snap = data.get("latestSnapshot", {})
    app = snap.get("app") or {}
    tun = snap.get("tunnel") or {}
    dns = snap.get("dns") or {}
    probes = snap.get("probes") or {}
    utun = snap.get("utun") or {}
    tcp = snap.get("tcp_states") or {}

    agg = data.get("aggregates", {})
    proc_agg = agg.get("process", {})
    net_agg = agg.get("network", {})
    stab_agg = agg.get("stability", {})

    print("\n--- 1. Data Plane & Network Performance ---")
    p_probe = probes.get("proxy", {})
    d_probe = probes.get("direct", {})
    print(f"  [PROXY Path]  Status: {p_probe.get('http_code', 'N/A')} ({p_probe.get('latency', -1.0):.3f}s) | "
          f"Success: {net_agg.get('proxySuccessRatePercent', 100.0):.1f}% ({net_agg.get('proxyProbesTotal', 0)} probes, avg: {net_agg.get('proxyAvgLatencySeconds', 0.0):.3f}s)")
    print(f"  [DIRECT Path] Status: {d_probe.get('http_code', 'N/A')} ({d_probe.get('latency', -1.0):.3f}s) | "
          f"Success: {net_agg.get('directSuccessRatePercent', 100.0):.1f}% ({net_agg.get('directProbesTotal', 0)} probes, avg: {net_agg.get('directAvgLatencySeconds', 0.0):.3f}s)")
    
    dns_g_lat = dns.get("google_ms", -1.0)
    dns_a_lat = dns.get("apple_ms", -1.0)
    fake_str = "Verified (198.18.0.0/15)" if dns.get("is_fake_ip") else "Non-FakeIP"
    print(f"  [DNS Health]  Google: {dns_g_lat:.2f}ms [{fake_str}] | Apple: {dns_a_lat:.2f}ms")

    if utun:
        print(f"  [TUN Device]  {utun.get('interface')} (MTU: {utun.get('mtu')}) | "
              f"Throughput: {utun.get('pps_in', 0)} pps in / {utun.get('pps_out', 0)} pps out | "
              f"Errors: in={utun.get('ierrs', 0)}, out={utun.get('oerrs', 0)}")
    else:
        print("  [TUN Device]  utun interface not active or not detected")

    print(f"  [TCP Sockets] Established: {tcp.get('ESTABLISHED', 0)} | Close-Wait: {tcp.get('CLOSE_WAIT', 0)} | "
          f"Time-Wait: {tcp.get('TIME_WAIT', 0)} | Syn-Sent: {tcp.get('SYN_SENT', 0)} | Listen: {tcp.get('LISTEN', 0)}")

    print("\n--- 2. Process Resources & Memory Drift ---")
    app_fp = f"{app.get('footprint_mb')} MB" if app.get('footprint_mb') is not None else f"{app.get('rss_mb')} MB(rss)"
    app_peak = f"(Peak: {app.get('peak_mb')} MB)" if app.get('peak_mb') is not None else ""
    fdb = app.get("fds_breakdown") or {}
    fd_str = f"{app.get('fds', 0)} (Sockets: {fdb.get('sockets', 0)}, Files: {fdb.get('files', 0)}, Pipes: {fdb.get('pipes', 0)})"
    
    print(f"  [APP]    PID: {app.get('pid', 'N/A')} | CPU: {app.get('cpu', 0.0)}% | Footprint: {app_fp} {app_peak} | Threads: {app.get('threads', 0)} | FDs: {fd_str}")
    print(f"  [TUNNEL] PID: {tun.get('pid', 'N/A')} | CPU: {tun.get('cpu', 0.0)}% | RSS: {tun.get('rss_mb', 0.0)} MB | Threads: {tun.get('threads', 0)}")
    
    slope = proc_agg.get("memorySlopeMBPerHour", 0.0)
    print(f"  [Memory Drift] Initial: {proc_agg.get('appFootprintInitialMB')} MB -> Current: {proc_agg.get('appFootprintCurrentMB')} MB "
          f"(Delta: {proc_agg.get('appFootprintDeltaMB', 0.0):+0.2f} MB, Slope: {slope:+0.2f} MB/h)")

    print("\n--- 3. Stability & Alerts ---")
    print(f"  Total Errors (os_log): {stab_agg.get('totalErrors', 0)} | "
          f"Total Crashes: {stab_agg.get('totalCrashes', 0)} | "
          f"Total Alerts: {stab_agg.get('totalAlerts', 0)} | "
          f"Sleep/Wake Events: {stab_agg.get('sleepWakeEvents', 0)}")

    if ALERT_FILE.exists():
        with open(ALERT_FILE, "r", encoding="utf-8") as f:
            alerts = [l.strip() for l in f if l.strip()]
        if alerts:
            print(f"\n🚨 Recent Alerts ({len(alerts)} total):")
            for a in alerts[-5:]:
                print(f"  {a}")
        else:
            print("  0 alerts recorded.")
    else:
        print("  0 alerts recorded.")

    print("==================================================================================")

if __name__ == "__main__":
    main()
