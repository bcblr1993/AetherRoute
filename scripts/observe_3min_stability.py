#!/usr/bin/env python3
import datetime
import json
import os
import re
import subprocess
import sys
import time

sys.stdout.reconfigure(line_buffering=True)

def run(cmd, timeout=15):
    try:
        res = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return res.stdout.strip(), res.stderr.strip(), res.returncode
    except Exception as e:
        return "", str(e), -1

def get_pids():
    app_pid = None
    tun_pid = None
    out, _, _ = run("pgrep -f '/Applications/AetherRoute.app/Contents/MacOS/AetherRoute'")
    if out:
        app_pid = int(out.splitlines()[0])
    out, _, _ = run("pgrep -f 'com.aetherroute.desktop.tunnel'")
    if out:
        tun_pid = int(out.splitlines()[0])
    return app_pid, tun_pid

def get_proc_metrics(pid, is_system_extension=False):
    if not pid:
        return None
    out, _, code = run(f"ps -p {pid} -o %cpu,rss,vsz")
    if code != 0 or not out:
        return None
    lines = out.splitlines()
    if len(lines) < 2:
        return None
    parts = lines[1].split()
    cpu = float(parts[0])
    rss_mb = round(int(parts[1]) / 1024.0, 2)
    vsz_mb = round(int(parts[2]) / 1024.0, 2)

    footprint_mb = None
    if not is_system_extension:
        vm_out, _, vm_code = run(f"vmmap -summary {pid}", timeout=8.0)
        if vm_code == 0:
            fp_match = re.search(r"Physical footprint:\s+([\d.]+)([KMGT]?)", vm_out)
            if fp_match:
                val, unit = float(fp_match.group(1)), fp_match.group(2)
                multiplier = {"K": 1/1024.0, "M": 1.0, "G": 1024.0, "T": 1024.0 * 1024.0}.get(unit, 1.0)
                footprint_mb = round(val * multiplier, 2)

    threads = 1
    th_out, _, th_code = run(f"ps -M {pid}", timeout=5.0)
    if th_code == 0:
        threads = max(1, len(th_out.splitlines()) - 1)

    out_fd, _, code_fd = run(f"lsof -p {pid} 2>/dev/null | wc -l")
    fds = int(out_fd.strip()) if code_fd == 0 and out_fd.strip().isdigit() else 0

    return {
        "pid": pid,
        "cpu": cpu,
        "rss_mb": rss_mb,
        "vsz_mb": vsz_mb,
        "footprint_mb": footprint_mb,
        "threads": threads,
        "fds": fds
    }

def check_crashes(start_iso):
    dirs = [
        os.path.expanduser("~/Library/Logs/DiagnosticReports"),
        "/Library/Logs/DiagnosticReports"
    ]
    crashes = []
    for d in dirs:
        if not os.path.exists(d):
            continue
        try:
            for fname in os.listdir(d):
                if "AetherRoute" in fname or "com.aetherroute" in fname:
                    full = os.path.join(d, fname)
                    mtime = os.path.getmtime(full)
                    if datetime.datetime.fromtimestamp(mtime, datetime.timezone.utc) >= start_iso:
                        crashes.append(full)
        except Exception:
            pass
    return crashes

def check_logs(since_seconds=35):
    predicate = 'subsystem == "com.aetherroute.desktop" && (messageType == error || messageType == fault)'
    out, _, _ = run(f"/usr/bin/log show --predicate '{predicate}' --last {since_seconds}s --style compact")
    error_lines = [l for l in out.splitlines() if l.strip() and not l.startswith("Timestamp") and not l.startswith("---")]

    all_out, _, _ = run(f"/usr/bin/log show --predicate 'subsystem == \"com.aetherroute.desktop\"' --last {since_seconds}s --style compact")
    all_lines = [l for l in all_out.splitlines() if l.strip() and not l.startswith("Timestamp") and not l.startswith("---")]

    return len(error_lines), error_lines, len(all_lines), all_lines

def probe_network():
    out, _, code = run("curl -s -o /dev/null -w '%{http_code}:%{time_total}' --connect-timeout 4 https://www.google.com")
    if code == 0 and out:
        parts = out.split(":")
        return parts[0], float(parts[1])
    return "000", -1.0

def main():
    total_seconds = 180
    interval = 30
    steps = total_seconds // interval

    start_time = datetime.datetime.now(datetime.timezone.utc)
    print(f"=== Starting 3-Minute Stability & Performance Observation ===")
    print(f"Start Time: {start_time.isoformat()}")
    print(f"Sampling every {interval} seconds for {total_seconds} seconds total ({steps} intervals)\n")

    app_pid, tun_pid = get_pids()
    print(f"Initial Target Processes: App PID={app_pid}, Tunnel PID={tun_pid}")
    if not app_pid or not tun_pid:
        print("ERROR: AetherRoute or Tunnel is not running!")
        sys.exit(1)

    records = []

    for step in range(steps + 1):
        elapsed = step * interval
        now_str = datetime.datetime.now().strftime("%H:%M:%S")
        app_m = get_proc_metrics(app_pid, is_system_extension=False)
        tun_m = get_proc_metrics(tun_pid, is_system_extension=True)

        http_code, latency = probe_network()
        err_count, err_lines, total_logs, log_lines = check_logs(interval + 5)
        crashes = check_crashes(start_time)

        rec = {
            "elapsed_s": elapsed,
            "timestamp": now_str,
            "app": app_m,
            "tunnel": tun_m,
            "http_code": http_code,
            "latency": latency,
            "errors": err_count,
            "err_lines": err_lines,
            "total_logs": total_logs,
            "crashes": len(crashes)
        }
        records.append(rec)

        app_fp = f"{app_m['footprint_mb']}MB" if app_m and app_m['footprint_mb'] is not None else f"{app_m['rss_mb']}MB(rss)"
        app_cpu = f"{app_m['cpu']}%" if app_m else "DEAD"
        tun_rss = f"{tun_m['rss_mb']}MB" if tun_m else "DEAD"
        tun_cpu = f"{tun_m['cpu']}%" if tun_m else "DEAD"

        print(f"[{now_str}] T+{elapsed:3d}s | App CPU: {app_cpu:>5s}, Footprint: {app_fp:>8s}, FDs: {app_m['fds'] if app_m else 0:2d} | "
              f"Tunnel CPU: {tun_cpu:>5s}, RSS: {tun_rss:>7s} | Probe: {http_code} ({latency:.3f}s) | "
              f"Errors: {err_count}, Crashes: {len(crashes)}")

        if err_count > 0:
            for l in err_lines[:3]:
                print(f"   [ERR] {l}")

        if len(crashes) > 0:
            print(f"   [CRASH DETECTED] {crashes}")

        if step < steps:
            time.sleep(interval)

    print("\n=== Observation Complete: Summary & Trend Analysis ===")
    app_fps = [r["app"]["footprint_mb"] for r in records if r["app"] and r["app"]["footprint_mb"] is not None]
    tun_rsses = [r["tunnel"]["rss_mb"] for r in records if r["tunnel"]]
    app_cpus = [r["app"]["cpu"] for r in records if r["app"]]
    tun_cpus = [r["tunnel"]["cpu"] for r in records if r["tunnel"]]
    all_errors = sum(r["errors"] for r in records)
    all_crashes = sum(r["crashes"] for r in records)

    fp_delta = round(app_fps[-1] - app_fps[0], 2) if len(app_fps) >= 2 else 0.0
    tun_rss_delta = round(tun_rsses[-1] - tun_rsses[0], 2) if len(tun_rsses) >= 2 else 0.0

    print(f"App Footprint: Initial={app_fps[0] if app_fps else 'N/A'}MB, Final={app_fps[-1] if app_fps else 'N/A'}MB, Delta={fp_delta:+0.2f}MB")
    print(f"Tunnel RSS:    Initial={tun_rsses[0]}MB, Final={tun_rsses[-1]}MB, Delta={tun_rss_delta:+0.2f}MB")
    print(f"Avg App CPU:   {sum(app_cpus)/len(app_cpus):.2f}%, Max={max(app_cpus)}%")
    print(f"Avg Tun CPU:   {sum(tun_cpus)/len(tun_cpus):.2f}%, Max={max(tun_cpus)}%")
    print(f"Total Errors:  {all_errors}")
    print(f"Total Crashes: {all_crashes}")

    summary_path = "reports/diagnostics/observation_3min_summary.json"
    os.makedirs(os.path.dirname(summary_path), exist_ok=True)
    with open(summary_path, "w") as f:
        json.dump({
            "startTime": start_time.isoformat(),
            "endTime": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "durationSeconds": total_seconds,
            "records": records,
            "analysis": {
                "appFootprintDeltaMB": fp_delta,
                "tunnelRSSDeltaMB": tun_rss_delta,
                "avgAppCPU": sum(app_cpus)/len(app_cpus),
                "avgTunCPU": sum(tun_cpus)/len(tun_cpus),
                "totalErrors": all_errors,
                "totalCrashes": all_crashes,
                "verdict": "HEALTHY" if all_errors == 0 and all_crashes == 0 and abs(fp_delta) < 15.0 else "WARNING"
            }
        }, f, indent=2)
    print(f"Structured report saved to: {summary_path}")

if __name__ == "__main__":
    main()
