#!/usr/bin/env python3
"""5-minute periodic monitoring checker and analysis recorder.

Reads recent metric samples, detects short-term anomalies or micro-drifts,
appends an analytical record to reports/monitoring/5min_analysis.log,
updates reports/monitoring/REPORT.md, and outputs a human-readable summary.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from generate_monitor_report import (
    parse_metrics_csv,
    parse_incidents,
    analyze_metrics,
    generate_markdown,
    safe_float,
    safe_int,
    percentile,
)

DEFAULT_DIR = ROOT / "reports" / "monitoring"


def run_5min_check(out_dir: Path) -> dict:
    csv_path = out_dir / "metrics_minute.csv"
    inc_path = out_dir / "incidents.jsonl"
    log_path = out_dir / "5min_analysis.log"
    report_path = out_dir / "REPORT.md"

    rows = parse_metrics_csv(csv_path)
    incidents = parse_incidents(inc_path)
    total_analysis = analyze_metrics(rows, incidents)

    # Re-generate overall REPORT.md
    md_content = generate_markdown(total_analysis)
    report_path.write_text(md_content, encoding="utf-8")

    now_iso = datetime.now(timezone.utc).isoformat()
    now_local = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    if not rows:
        return {"status": "NO_DATA", "message": "No metric data found."}

    # Focus on the most recent window (last 5 samples)
    recent_rows = rows[-5:]
    window_count = len(recent_rows)

    app_cpus = [safe_float(r.get("app_cpu")) for r in recent_rows]
    tun_cpus = [safe_float(r.get("tunnel_cpu")) for r in recent_rows]
    app_fps = [safe_float(r.get("app_footprint_mb")) for r in recent_rows if r.get("app_footprint_mb")]
    tun_rss = [safe_float(r.get("tunnel_rss_mb")) for r in recent_rows]
    prx_totals = [safe_float(r.get("proxy_total_s")) for r in recent_rows]
    prx_oks = [r.get("proxy_ok") in ("True", "true", "1") for r in recent_rows]
    app_cws = [safe_int(r.get("app_close_wait")) for r in recent_rows]
    flags_list = [r.get("anomaly_flags", "NONE") for r in recent_rows if r.get("anomaly_flags", "NONE") != "NONE"]

    latest = recent_rows[-1]
    prev_baseline = recent_rows[0]

    fp_start = app_fps[0] if app_fps else 0.0
    fp_end = app_fps[-1] if app_fps else 0.0
    fp_delta = fp_end - fp_start

    tun_start = tun_rss[0] if tun_rss else 0.0
    tun_end = tun_rss[-1] if tun_rss else 0.0
    tun_delta = tun_end - tun_start

    app_cpu_avg = sum(app_cpus) / window_count if window_count else 0.0
    tun_cpu_avg = sum(tun_cpus) / window_count if window_count else 0.0
    prx_avg = sum(prx_totals) / window_count if window_count else 0.0
    prx_avail = (sum(prx_oks) / window_count * 100.0) if window_count else 0.0
    max_cw = max(app_cws) if app_cws else 0

    # Determine 5-minute health verdict
    window_verdict = "HEALTHY"
    findings = []

    if prx_avail < 100.0:
        window_verdict = "WARNING"
        findings.append(f"Proxy availability dropped to {prx_avail:.1f}% in last 5m")
    if prx_avg > 1.5:
        window_verdict = "WARNING"
        findings.append(f"Proxy latency elevated: avg {prx_avg:.2f}s")
    if fp_delta > 15.0:
        window_verdict = "WARNING"
        findings.append(f"App footprint increased +{fp_delta:.1f}MB in last 5m")
    if max_cw >= 3:
        window_verdict = "WARNING"
        findings.append(f"App has unclosed CLOSE_WAIT sockets: {max_cw}")
    if tun_cpu_avg > 25.0:
        window_verdict = "WARNING"
        findings.append(f"Tunnel CPU elevated: avg {tun_cpu_avg:.1f}%")
    if flags_list:
        window_verdict = "WARNING"
        findings.append(f"Triggered flags: {'; '.join(set(flags_list))}")

    if not findings:
        findings.append("All metrics within baseline limits, zero socket leaks, stable latency.")

    # Format log entry
    log_entry = (
        f"[{now_local}] 5-Minute Analysis Check #{len(rows)}\n"
        f"  Verdict: {window_verdict} (Total samples: {len(rows)}, Elapsed: {total_analysis['duration_hours']}h)\n"
        f"  App Memory: {fp_end:.1f} MB (5m delta: {fp_delta:+.2f} MB) | App CPU avg: {app_cpu_avg:.1f}%\n"
        f"  Tunnel RSS: {tun_end:.1f} MB (5m delta: {tun_delta:+.2f} MB) | Tun CPU avg: {tun_cpu_avg:.1f}%\n"
        f"  Network: Proxy Avail {prx_avail:.1f}%, Latency avg {prx_avg:.3f}s | App Close-Wait: {max_cw}\n"
        f"  Findings: {'; '.join(findings)}\n"
        f"--------------------------------------------------------------------------------\n"
    )

    with open(log_path, "a", encoding="utf-8") as f:
        f.write(log_entry)

    summary = {
        "timestamp_local": now_local,
        "total_samples": len(rows),
        "elapsed_hours": total_analysis["duration_hours"],
        "window_verdict": window_verdict,
        "app_footprint_mb": fp_end,
        "app_footprint_delta_5m": fp_delta,
        "app_cpu_avg": round(app_cpu_avg, 2),
        "tunnel_rss_mb": tun_end,
        "tunnel_rss_delta_5m": tun_delta,
        "tunnel_cpu_avg": round(tun_cpu_avg, 2),
        "proxy_avail_pct": prx_avail,
        "proxy_latency_avg_s": round(prx_avg, 3),
        "app_close_wait_max": max_cw,
        "findings": findings,
    }
    return summary


def main():
    parser = argparse.ArgumentParser(description="5-minute monitoring analysis check")
    parser.add_argument("--dir", type=str, default=str(DEFAULT_DIR))
    args = parser.parse_args()

    out_dir = Path(args.dir)
    res = run_5min_check(out_dir)

    color_emoji = "🟢" if res.get("window_verdict") == "HEALTHY" else "🟡"
    print("=" * 72)
    print(f" AetherRoute 5-Minute Health Audit [{res.get('timestamp_local')}]")
    print(f" Status: {color_emoji} {res.get('window_verdict')} (Sample #{res.get('total_samples')}, {res.get('elapsed_hours')}h elapsed)")
    print("=" * 72)
    print(f" • App Footprint : {res.get('app_footprint_mb')} MB ({res.get('app_footprint_delta_5m'):+.2f} MB in 5m) | CPU: {res.get('app_cpu_avg')}%")
    print(f" • Tunnel RSS    : {res.get('tunnel_rss_mb')} MB ({res.get('tunnel_rss_delta_5m'):+.2f} MB in 5m) | CPU: {res.get('tunnel_cpu_avg')}%")
    print(f" • Proxy DataPath: Avail {res.get('proxy_avail_pct')}% | Latency: {res.get('proxy_latency_avg_s')}s")
    print(f" • Socket Leaks  : CLOSE_WAIT = {res.get('app_close_wait_max')}")
    print(f" • Findings      : {'; '.join(res.get('findings', []))}")
    print("=" * 72)
    print(f"Recorded to: {out_dir}/5min_analysis.log and {out_dir}/REPORT.md")


if __name__ == "__main__":
    main()
