#!/usr/bin/env python3
"""AetherRoute local runtime health, performance, crash and log monitor.

Inspects running AetherRoute processes, memory footprint, crashes in
DiagnosticReports, and unified system logs (os_log) over a configurable window
(default 30 minutes). Produces structured diagnostic JSON reports and health evaluations.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

APP_PROCESS_NAME = "AetherRoute"
TUNNEL_PROCESS_NAME = "com.aetherroute.desktop.tunnel"
DEFAULT_WINDOW_SECONDS = 1800  # 30 minutes


def run_command(cmd: List[str], timeout: float = 30.0) -> Tuple[int, str, str]:
    """Runs a shell command and returns (exit_code, stdout, stderr)."""
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return -1, "", f"Command timed out after {timeout} seconds: {' '.join(cmd)}"
    except Exception as e:
        return -1, "", str(e)


def find_aetherroute_processes() -> List[Dict[str, Any]]:
    """Finds running AetherRoute and tunnel processes with stats."""
    code, stdout, _ = run_command(["ps", "-A", "-o", "pid,ppid,%cpu,%mem,rss,vsz,command"])
    if code != 0:
        return []

    processes = []
    for line in stdout.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 6)
        if len(parts) < 7:
            continue
        pid, ppid, cpu, mem, rss_kb, vsz_kb, command = parts
        cmd_lower = command.lower()

        is_app = "/applications/aetherroute.app" in cmd_lower or "/aetherroute" in cmd_lower
        is_tunnel = "com.aetherroute.desktop.tunnel" in cmd_lower

        if not (is_app or is_tunnel):
            continue

        # Distinguish App vs Tunnel
        p_type = "tunnel" if is_tunnel else "app"
        name = TUNNEL_PROCESS_NAME if is_tunnel else APP_PROCESS_NAME

        try:
            pid_int = int(pid)
            cpu_float = float(cpu)
            mem_float = float(mem)
            rss_mb = round(int(rss_kb) / 1024.0, 2)
            vsz_mb = round(int(vsz_kb) / 1024.0, 2)
        except ValueError:
            continue

        # Count open file descriptors via lsof
        fd_count = 0
        fd_code, fd_out, _ = run_command(["lsof", "-p", str(pid_int)], timeout=5.0)
        if fd_code == 0:
            fd_count = max(0, len(fd_out.splitlines()) - 1)

        # Count threads via ps -M
        thread_count = 1
        th_code, th_out, _ = run_command(["ps", "-M", str(pid_int)], timeout=5.0)
        if th_code == 0:
            thread_count = max(1, len(th_out.splitlines()) - 1)

        # Query physical footprint via vmmap if possible
        footprint_mb: Optional[float] = None
        peak_footprint_mb: Optional[float] = None
        vm_code, vm_out, _ = run_command(["vmmap", "-summary", str(pid_int)], timeout=8.0)
        if vm_code == 0:
            fp_match = re.search(r"Physical footprint:\s+([\d.]+)([KMGT]?)", vm_out)
            if fp_match:
                val, unit = float(fp_match.group(1)), fp_match.group(2)
                multiplier = {"K": 1/1024.0, "M": 1.0, "G": 1024.0, "T": 1024.0 * 1024.0}.get(unit, 1.0)
                footprint_mb = round(val * multiplier, 2)
            peak_match = re.search(r"Physical footprint \(peak\):\s+([\d.]+)([KMGT]?)", vm_out)
            if peak_match:
                val, unit = float(peak_match.group(1)), peak_match.group(2)
                multiplier = {"K": 1/1024.0, "M": 1.0, "G": 1024.0, "T": 1024.0 * 1024.0}.get(unit, 1.0)
                peak_footprint_mb = round(val * multiplier, 2)

        processes.append({
            "pid": pid_int,
            "ppid": int(ppid),
            "type": p_type,
            "name": name,
            "command": command,
            "cpu_percent": cpu_float,
            "memory_percent": mem_float,
            "rss_mb": rss_mb,
            "vsz_mb": vsz_mb,
            "footprint_mb": footprint_mb,
            "peak_footprint_mb": peak_footprint_mb,
            "thread_count": thread_count,
            "open_fd_count": fd_count,
        })
    return processes


def scan_crashes(window_seconds: int = DEFAULT_WINDOW_SECONDS) -> List[Dict[str, Any]]:
    """Scans DiagnosticReports for AetherRoute crashes in the given window."""
    cutoff = time.time() - window_seconds
    search_dirs = [
        Path.home() / "Library" / "Logs" / "DiagnosticReports",
        Path("/Library/Logs/DiagnosticReports"),
    ]

    crashes = []
    for s_dir in search_dirs:
        if not s_dir.exists():
            continue
        try:
            for item in s_dir.glob("*"):
                if not item.is_file():
                    continue
                name_lower = item.name.lower()
                if not ("aether" in name_lower or "tunnel" in name_lower):
                    continue
                if not (item.suffix in (".ips", ".crash")):
                    continue
                try:
                    mtime = item.stat().st_mtime
                    if mtime < cutoff:
                        continue
                except OSError:
                    continue

                # Parse crash snippet
                summary = parse_crash_file(item)
                crashes.append(summary)
        except OSError:
            continue

    return crashes


def parse_crash_file(path: Path) -> Dict[str, Any]:
    """Extracts high-level information from an Apple crash report (.ips / .crash)."""
    info: Dict[str, Any] = {
        "file": str(path),
        "filename": path.name,
        "mtime": datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc).isoformat(),
        "exception_type": "Unknown",
        "termination_reason": "Unknown",
        "faulting_thread": None,
        "snippet": "",
    }
    try:
        content = path.read_text(encoding="utf-8", errors="replace")
        # Try JSON IPS format
        if content.startswith("{") and "app_name" in content:
            try:
                data = json.loads(content.split("\n", 1)[0])
                info["exception_type"] = data.get("exception", {}).get("type", "Unknown")
                info["termination_reason"] = data.get("termination", {}).get("indicator", "Unknown")
                info["faulting_thread"] = data.get("faultingThread")
                info["snippet"] = content[:1000]
                return info
            except Exception:
                pass

        # Standard crash text parsing
        for line in content.splitlines()[:100]:
            if line.startswith("Exception Type:"):
                info["exception_type"] = line.split(":", 1)[1].strip()
            elif line.startswith("Termination Reason:"):
                info["termination_reason"] = line.split(":", 1)[1].strip()
            elif "Crashed Thread:" in line:
                info["faulting_thread"] = line.strip()

        info["snippet"] = "\n".join(content.splitlines()[:30])
    except Exception as e:
        info["error"] = str(e)

    return info


def inspect_unified_logs(window_seconds: int = DEFAULT_WINDOW_SECONDS) -> Dict[str, Any]:
    """Queries macOS unified log for AetherRoute errors and warnings."""
    # Format window in minutes
    window_minutes = max(1, int(window_seconds / 60))
    time_arg = f"{window_minutes}m"

    predicate = (
        '(process == "AetherRoute" OR process == "com.aetherroute.desktop.tunnel") '
        'AND (messageType == error OR messageType == fault)'
    )

    cmd = [
        "/usr/bin/log",
        "show",
        "--predicate",
        predicate,
        "--last",
        time_arg,
        "--style",
        "compact",
    ]

    code, stdout, stderr = run_command(cmd, timeout=40.0)

    log_summary: Dict[str, Any] = {
        "window_minutes": window_minutes,
        "total_errors": 0,
        "total_faults": 0,
        "nw_unconnected_calls": 0,
        "tcp_copy_failures": 0,
        "adapter_send_failures": 0,
        "sample_entries": [],
    }

    if code != 0:
        log_summary["query_error"] = stderr or f"Exit code {code}"
        return log_summary

    lines = stdout.splitlines()
    samples = []

    for line in lines:
        line_clean = line.strip()
        if not line_clean or line_clean.startswith("Timestamp") or line_clean.startswith("---"):
            continue

        if " E " in line or " [Error] " in line:
            log_summary["total_errors"] += 1
        elif " F " in line or " [Fault] " in line:
            log_summary["total_faults"] += 1

        if "on unconnected nw_connection" in line:
            log_summary["nw_unconnected_calls"] += 1
        if "tcp_copy" in line and "failed" in line:
            log_summary["tcp_copy_failures"] += 1
        if "dispatcher_adapter_send_failed" in line:
            log_summary["adapter_send_failures"] += 1

        if len(samples) < 25:
            samples.append(line_clean)

    log_summary["sample_entries"] = samples
    return log_summary


def inspect_network_health(app_pid: Optional[int] = None) -> Dict[str, Any]:
    """Probes DNS, dual routing paths, utun device, and TCP socket states."""
    import socket

    # 1. DNS
    dns_res = {}
    for host in ("www.google.com", "www.apple.com"):
        t0 = time.time()
        try:
            infos = socket.getaddrinfo(host, 443, family=socket.AF_INET)
            lat = (time.time() - t0) * 1000.0
            ip = infos[0][4][0]
            is_fake = ip.startswith("198.18.") or ip.startswith("198.19.")
            dns_res[host] = {"ip": ip, "latency_ms": round(lat, 2), "is_fake_ip": is_fake, "ok": True}
        except Exception as e:
            dns_res[host] = {"ip": None, "latency_ms": -1.0, "is_fake_ip": False, "ok": False, "error": str(e)}

    # 2. Dual-target HTTP probes
    probes = {}
    for name, url in (("proxy", "https://www.google.com"), ("direct", "https://www.apple.com")):
        code, out, _ = run_command(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}:%{time_total}", "--connect-timeout", "4", url])
        if code == 0 and out:
            parts = out.split(":")
            try:
                probes[name] = {"http_code": parts[0], "latency": round(float(parts[1]), 3)}
            except Exception:
                probes[name] = {"http_code": "000", "latency": -1.0}
        else:
            probes[name] = {"http_code": "000", "latency": -1.0}

    # 3. UTUN Interface
    utun_stats = None
    c_if, out_if, _ = run_command(["ifconfig"])
    if c_if == 0:
        blocks = re.split(r"\n(?=[a-zA-Z0-9_]+:)", out_if)
        utun_name = None
        for b in blocks:
            if "inet 198.18.0.1" in b or "198.18." in b:
                utun_name = b.split(":")[0].strip()
                break
        if utun_name:
            c_ns, out_ns, _ = run_command(["netstat", "-I", utun_name])
            if c_ns == 0:
                data_lines = [l for l in out_ns.splitlines() if l.strip() and not l.startswith("Name")]
                if data_lines:
                    p = data_lines[0].split()
                    if len(p) >= 8:
                        try:
                            utun_stats = {
                                "interface": utun_name,
                                "mtu": int(p[1]),
                                "ipkts": int(p[3]),
                                "ierrs": int(p[4]),
                                "opkts": int(p[5]),
                                "oerrs": int(p[6]),
                            }
                        except Exception:
                            pass

    # 4. TCP Socket states
    tcp_states = {"ESTABLISHED": 0, "CLOSE_WAIT": 0, "TIME_WAIT": 0, "SYN_SENT": 0, "LISTEN": 0}
    c_tcp, out_tcp, _ = run_command(["netstat", "-an", "-p", "tcp"])
    if c_tcp == 0:
        for l in out_tcp.splitlines():
            if l.startswith("tcp"):
                parts = l.split()
                if len(parts) >= 6:
                    st = parts[5]
                    tcp_states[st] = tcp_states.get(st, 0) + 1

    app_close_wait = 0
    if app_pid:
        c_cw, out_cw, _ = run_command(["lsof", "-n", "-P", "-p", str(app_pid)])
        if c_cw == 0 and out_cw:
            app_close_wait = len([l for l in out_cw.splitlines() if "CLOSE_WAIT" in l])

    return {
        "dns": dns_res,
        "probes": probes,
        "utun": utun_stats,
        "tcp_states": tcp_states,
        "app_close_wait": app_close_wait,
    }


def evaluate_health(
    processes: List[Dict[str, Any]],
    crashes: List[Dict[str, Any]],
    logs: Dict[str, Any],
    network: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Computes overall health score and specific actionable findings."""
    issues = []
    status = "HEALTHY"

    # 1. Process presence
    app_procs = [p for p in processes if p["type"] == "app"]
    tunnel_procs = [p for p in processes if p["type"] == "tunnel"]

    if not app_procs:
        issues.append("AetherRoute UI application is not running.")
    if not tunnel_procs:
        issues.append("AetherRoute Network Extension tunnel is not active.")

    # 2. Crash checks
    if crashes:
        status = "CRITICAL"
        issues.append(f"Detected {len(crashes)} crash report(s) in DiagnosticReports!")

    # 3. Memory checks
    for proc in processes:
        p_name = proc["name"]
        pid = proc["pid"]
        fp = proc.get("footprint_mb")
        rss = proc.get("rss_mb", 0)
        fd = proc.get("open_fd_count", 0)

        # Footprint threshold: 300MB
        if fp is not None and fp > 300.0:
            if status != "CRITICAL":
                status = "WARNING"
            issues.append(f"{p_name} (PID {pid}) physical footprint is high: {fp}MB > 300MB.")
        elif rss > 400.0:
            if status != "CRITICAL":
                status = "WARNING"
            issues.append(f"{p_name} (PID {pid}) RSS memory is high: {rss}MB > 400MB.")

        # File descriptor leak check
        if fd > 250:
            if status != "CRITICAL":
                status = "WARNING"
            issues.append(f"{p_name} (PID {pid}) open file descriptor count is high: {fd} FDs.")

        # CPU check
        cpu = proc.get("cpu_percent", 0.0)
        if cpu > 40.0:
            if status != "CRITICAL":
                status = "WARNING"
            issues.append(f"{p_name} (PID {pid}) CPU usage is elevated: {cpu}%.")

    # 4. Log errors check
    total_errs = logs.get("total_errors", 0) + logs.get("total_faults", 0)
    if total_errs > 50:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"High error count in logs: {total_errs} errors/faults in last {logs.get('window_minutes')}m.")

    if logs.get("nw_unconnected_calls", 0) > 0:
        issues.append(
            f"Detected {logs['nw_unconnected_calls']} CFNetwork unconnected nw_connection error calls."
        )

    if network:
        utun = network.get("utun")
        if utun and (utun.get("ierrs", 0) > 0 or utun.get("oerrs", 0) > 0):
            if status != "CRITICAL":
                status = "WARNING"
            issues.append(f"Virtual TUN interface packet errors: ierrs={utun.get('ierrs')}, oerrs={utun.get('oerrs')}.")
        tcp = network.get("tcp_states", {})
        app_close_wait = network.get("app_close_wait", 0)
        if app_close_wait > 5:
            if status != "CRITICAL":
                status = "WARNING"
            issues.append(f"AetherRoute has {app_close_wait} unclosed CLOSE_WAIT sockets.")
        elif tcp.get("CLOSE_WAIT", 0) > 200:
            if status != "CRITICAL":
                status = "WARNING"
            issues.append(f"System-wide CLOSE_WAIT TCP sockets critically elevated: {tcp.get('CLOSE_WAIT')}.")
        p_probe = network.get("probes", {}).get("proxy", {})
        if p_probe.get("http_code") != "200":
            if status != "CRITICAL":
                status = "WARNING"
            issues.append(f"Proxy connectivity probe failed: HTTP {p_probe.get('http_code')}.")

    if not issues:
        issues.append("All runtime health checks passed cleanly.")

    return {
        "status": status,
        "issues": issues,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def perform_health_check(
    window_seconds: int = DEFAULT_WINDOW_SECONDS,
    json_out_path: Optional[str] = None,
    quiet: bool = False,
) -> Dict[str, Any]:
    """Runs a complete health diagnostic cycle and produces report."""
    processes = find_aetherroute_processes()
    crashes = scan_crashes(window_seconds=window_seconds)
    logs = inspect_unified_logs(window_seconds=window_seconds)
    app_procs = [p for p in processes if p["type"] == "app"]
    app_pid = app_procs[0]["pid"] if app_procs else None
    network = inspect_network_health(app_pid=app_pid)
    evaluation = evaluate_health(processes, crashes, logs, network=network)

    report = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "window_seconds": window_seconds,
        "verdict": evaluation["status"],
        "issues": evaluation["issues"],
        "processes": processes,
        "crashes": crashes,
        "logs": logs,
        "network": network,
    }

    if json_out_path:
        out_file = Path(json_out_path)
        out_file.parent.mkdir(parents=True, exist_ok=True)
        out_file.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

    if not quiet:
        print_summary(report)

    return report


def print_summary(report: Dict[str, Any]) -> None:
    """Prints a clean human-readable summary to stdout."""
    verdict = report["verdict"]
    color = "\033[92m" if verdict == "HEALTHY" else ("\033[93m" if verdict == "WARNING" else "\033[91m")
    reset = "\033[0m"

    print("=" * 68)
    print(f" AetherRoute Runtime Health Inspector [{report['timestamp']}]")
    print(f" Status: {color}{verdict}{reset}")
    print("=" * 68)

    if "network" in report and report["network"]:
        net = report["network"]
        print("\n--- Data Plane & Network Performance ---")
        p_pr = net.get("probes", {}).get("proxy", {})
        d_pr = net.get("probes", {}).get("direct", {})
        print(f"  [PROXY]  HTTP {p_pr.get('http_code', 'N/A')} ({p_pr.get('latency', -1.0):.3f}s) | [DIRECT] HTTP {d_pr.get('http_code', 'N/A')} ({d_pr.get('latency', -1.0):.3f}s)")
        dns = net.get("dns", {})
        g_dns = dns.get("www.google.com", {})
        a_dns = dns.get("www.apple.com", {})
        fake_str = f"Fake-IP: {g_dns.get('ip')}" if g_dns.get("is_fake_ip") else f"IP: {g_dns.get('ip')}"
        print(f"  [DNS]    Google: {g_dns.get('latency_ms', -1):.1f}ms [{fake_str}] | Apple: {a_dns.get('latency_ms', -1):.1f}ms")
        utun = net.get("utun")
        if utun:
            print(f"  [UTUN]   {utun.get('interface')} (MTU {utun.get('mtu')}) | Ipkts: {utun.get('ipkts')}, Opkts: {utun.get('opkts')}, Errors: in={utun.get('ierrs')}/out={utun.get('oerrs')}")
        tcp = net.get("tcp_states", {})
        print(f"  [TCP]    Established: {tcp.get('ESTABLISHED', 0)} | Close-Wait: {tcp.get('CLOSE_WAIT', 0)} | Time-Wait: {tcp.get('TIME_WAIT', 0)} | Syn-Sent: {tcp.get('SYN_SENT', 0)}")

    print("\n--- Running Processes ---")
    if not report["processes"]:
        print("  No AetherRoute processes detected.")
    else:
        for p in report["processes"]:
            fp_str = f"{p['footprint_mb']} MB" if p.get("footprint_mb") is not None else "N/A"
            peak_str = f"{p['peak_footprint_mb']} MB" if p.get("peak_footprint_mb") is not None else "N/A"
            print(f"  [{p['type'].upper()}] {p['name']} (PID: {p['pid']})")
            print(f"    CPU: {p['cpu_percent']}% | Threads: {p['thread_count']} | Open FDs: {p['open_fd_count']}")
            print(f"    Footprint: {fp_str} (Peak: {peak_str}) | RSS: {p['rss_mb']} MB | VSZ: {p['vsz_mb']} MB")

    print("\n--- DiagnosticReports Crashes ---")
    if not report["crashes"]:
        print("  0 crashes detected in the last window.")
    else:
        for c in report["crashes"]:
            print(f"  CRASH: {c['filename']} at {c['mtime']}")
            print(f"    Type: {c.get('exception_type')} | Reason: {c.get('termination_reason')}")

    print("\n--- Unified Log (os_log) Analysis ---")
    logs = report["logs"]
    print(f"  Window: {logs.get('window_minutes', 30)} minutes")
    print(f"  Total Errors: {logs.get('total_errors', 0)} | Faults: {logs.get('total_faults', 0)}")
    print(f"  Unconnected NWConnection Calls: {logs.get('nw_unconnected_calls', 0)}")
    print(f"  TCP Copy Failures: {logs.get('tcp_copy_failures', 0)} | Adapter Send Failures: {logs.get('adapter_send_failures', 0)}")

    print("\n--- Health Findings & Verdict ---")
    for issue in report["issues"]:
        print(f"  • {issue}")
    print("=" * 68)


def main() -> int:
    parser = argparse.ArgumentParser(description="AetherRoute local runtime health monitor")
    parser.add_argument("--once", action="store_true", help="Run once and exit")
    parser.add_argument("--interval", type=int, default=DEFAULT_WINDOW_SECONDS, help="Inspection interval in seconds (default: 1800)")
    parser.add_argument("--window", type=int, default=DEFAULT_WINDOW_SECONDS, help="Log/crash lookback window in seconds (default: 1800)")
    parser.add_argument("--json-out", type=str, default=None, help="Path to write JSON report")
    parser.add_argument("--quiet", action="store_true", help="Do not print terminal summary")
    args = parser.parse_args()

    reports_dir = Path("reports/diagnostics")
    reports_dir.mkdir(parents=True, exist_ok=True)

    if args.once:
        default_out = args.json_out or str(reports_dir / f"health_report_{int(time.time())}.json")
        report = perform_health_check(
            window_seconds=args.window,
            json_out_path=default_out,
            quiet=args.quiet,
        )
        return 0 if report["verdict"] in ("HEALTHY", "WARNING") else 1

    print(f"Starting AetherRoute monitor loop (Interval: {args.interval}s, Window: {args.window}s)...")
    try:
        while True:
            timestamp = int(time.time())
            out_path = args.json_out or str(reports_dir / f"health_report_{timestamp}.json")
            perform_health_check(
                window_seconds=args.window,
                json_out_path=out_path,
                quiet=args.quiet,
            )
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nMonitor stopped by user.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
