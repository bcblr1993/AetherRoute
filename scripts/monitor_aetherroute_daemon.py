#!/usr/bin/env python3
"""AetherRoute minute-by-minute runtime health, performance & incident monitor daemon.

Periodically collects deep performance metrics (CPU, Footprint, RSS, FDs, Sockets,
Dual-path latency, DNS, UTUN traffic/errors, Unified Logs, Crashes), evaluates
anomalies (memory creep, socket leaks, CPU hangs, network degradation), and
automatically captures forensic evidence snapshots into incident bundles.
"""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT_DIR = ROOT / "reports" / "monitoring"

APP_NAME = "AetherRoute"
TUNNEL_NAME = "com.aetherroute.desktop.tunnel"

PROXIED_URL = "https://www.google.com/generate_204"
DIRECT_URL = "https://www.baidu.com"
DNS_HOST = "www.google.com"

# Anomaly Thresholds
LIMITS = {
    "APP_FOOTPRINT_MB": 250.0,
    "TUNNEL_RSS_MB": 300.0,
    "MEMORY_CREEP_MB": 40.0,  # Monotonic increase threshold across window
    "APP_CLOSE_WAIT": 5,      # Unclosed sockets in app
    "SYSTEM_CLOSE_WAIT": 150, # Unclosed sockets system-wide
    "APP_FD_COUNT": 200,      # Open file descriptors
    "TUNNEL_FD_COUNT": 200,
    "CPU_PERCENT_HIGH": 35.0, # Sustained CPU
    "CPU_STRIKES": 3,         # Cycles of high CPU to trigger
    "PROXIED_TOTAL_SEC": 2.5, # Degradation threshold
    "PROXIED_TLS_SEC": 1.2,
    "PROBE_STRIKES": 2,       # Consecutive degraded samples to trigger
    "DNS_LATENCY_MS": 1000.0,
    "INCIDENT_COOLDOWN_SEC": 600, # 10 min cooldown per incident type
}


def run_command(cmd: List[str], timeout: float = 15.0) -> Tuple[int, str, str]:
    """Runs a system command returning (exit_code, stdout, stderr). Never raises."""
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
        return -1, "", f"Command timed out after {timeout}s: {' '.join(cmd)}"
    except Exception as e:
        return -1, "", str(e)


# ==============================================================================
# 1. Metric Collectors
# ==============================================================================

def inspect_processes() -> Dict[str, Optional[Dict[str, Any]]]:
    """Finds running AetherRoute app and tunnel processes and their resource consumption."""
    code, stdout, _ = run_command(["ps", "-A", "-o", "pid,ppid,%cpu,%mem,rss,vsz,command"])
    results: Dict[str, Optional[Dict[str, Any]]] = {"app": None, "tunnel": None}
    if code != 0:
        return results

    for line in stdout.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 6)
        if len(parts) < 7:
            continue
        pid_s, ppid_s, cpu_s, mem_s, rss_s, vsz_s, command = parts
        cmd_lower = command.lower()

        is_app = ("/applications/aetherroute.app" in cmd_lower or "/aetherroute" in cmd_lower) and "systemextension" not in cmd_lower
        is_tunnel = "com.aetherroute.desktop.tunnel" in cmd_lower

        if not (is_app or is_tunnel):
            continue

        try:
            pid = int(pid_s)
            cpu = float(cpu_s)
            mem = float(mem_s)
            rss_mb = round(int(rss_s) / 1024.0, 2)
            vsz_mb = round(int(vsz_s) / 1024.0, 2)
        except ValueError:
            continue

        # Open file descriptors via lsof
        fd_count = 0
        fd_code, fd_out, _ = run_command(["lsof", "-p", str(pid)], timeout=4.0)
        if fd_code == 0:
            fd_count = max(0, len(fd_out.splitlines()) - 1)

        # Thread count
        thread_count = 1
        th_code, th_out, _ = run_command(["ps", "-M", str(pid)], timeout=4.0)
        if th_code == 0:
            thread_count = max(1, len(th_out.splitlines()) - 1)

        # Physical footprint via vmmap (App process only, since tunnel is root)
        footprint_mb: Optional[float] = None
        peak_footprint_mb: Optional[float] = None
        if is_app:
            vm_code, vm_out, _ = run_command(["vmmap", "-summary", str(pid)], timeout=6.0)
            if vm_code == 0:
                fp_m = re.search(r"Physical footprint:\s+([\d.]+)([KMGT]?)", vm_out)
                if fp_m:
                    v, u = float(fp_m.group(1)), fp_m.group(2)
                    mult = {"K": 1/1024.0, "M": 1.0, "G": 1024.0, "T": 1024.0 * 1024.0}.get(u, 1.0)
                    footprint_mb = round(v * mult, 2)
                pk_m = re.search(r"Physical footprint \(peak\):\s+([\d.]+)([KMGT]?)", vm_out)
                if pk_m:
                    v, u = float(pk_m.group(1)), pk_m.group(2)
                    mult = {"K": 1/1024.0, "M": 1.0, "G": 1024.0, "T": 1024.0 * 1024.0}.get(u, 1.0)
                    peak_footprint_mb = round(v * mult, 2)

        info = {
            "pid": pid,
            "ppid": int(ppid_s),
            "name": APP_NAME if is_app else TUNNEL_NAME,
            "cpu_percent": cpu,
            "mem_percent": mem,
            "rss_mb": rss_mb,
            "vsz_mb": vsz_mb,
            "footprint_mb": footprint_mb,
            "peak_footprint_mb": peak_footprint_mb,
            "thread_count": thread_count,
            "fd_count": fd_count,
            "command": command,
        }
        if is_app and results["app"] is None:
            results["app"] = info
        elif is_tunnel and results["tunnel"] is None:
            results["tunnel"] = info

    return results


def inspect_tcp_and_sockets(app_pid: Optional[int] = None) -> Dict[str, Any]:
    """Queries system-wide and app-specific TCP socket states."""
    tcp_states = {"ESTABLISHED": 0, "CLOSE_WAIT": 0, "TIME_WAIT": 0, "SYN_SENT": 0, "FIN_WAIT": 0, "LISTEN": 0}
    c_tcp, out_tcp, _ = run_command(["netstat", "-an", "-p", "tcp"], timeout=5.0)
    if c_tcp == 0:
        for line in out_tcp.splitlines():
            if line.startswith("tcp"):
                parts = line.split()
                if len(parts) >= 6:
                    st = parts[5]
                    if st.startswith("FIN_WAIT"):
                        st = "FIN_WAIT"
                    tcp_states[st] = tcp_states.get(st, 0) + 1

    app_close_wait = 0
    if app_pid:
        c_lsof, out_lsof, _ = run_command(["lsof", "-n", "-P", "-p", str(app_pid)], timeout=5.0)
        if c_lsof == 0 and out_lsof:
            for l in out_lsof.splitlines():
                if "CLOSE_WAIT" in l:
                    app_close_wait += 1

    return {
        "states": tcp_states,
        "app_close_wait": app_close_wait,
    }


def inspect_utun() -> Optional[Dict[str, Any]]:
    """Identifies the active 198.18.0.1 Fake-IP utun device and reads packet statistics."""
    c_if, out_if, _ = run_command(["ifconfig"], timeout=4.0)
    if c_if != 0:
        return None

    utun_name = None
    blocks = re.split(r"\n(?=[a-zA-Z0-9_]+:)", out_if)
    for b in blocks:
        if "inet 198.18." in b or "inet 198.19." in b:
            utun_name = b.split(":")[0].strip()
            break

    if not utun_name:
        return None

    c_ns, out_ns, _ = run_command(["netstat", "-I", utun_name], timeout=4.0)
    if c_ns == 0:
        for line in out_ns.splitlines():
            line_s = line.strip()
            if line_s and not line_s.startswith("Name") and not line_s.startswith("Address"):
                parts = line_s.split()
                if len(parts) >= 7:
                    try:
                        return {
                            "interface": utun_name,
                            "mtu": int(parts[1]),
                            "ipkts": int(parts[3]),
                            "ierrs": int(parts[4]),
                            "opkts": int(parts[5]),
                            "oerrs": int(parts[6]),
                        }
                    except (ValueError, IndexError):
                        pass
    return {"interface": utun_name, "mtu": 1500, "ipkts": 0, "ierrs": 0, "opkts": 0, "oerrs": 0}


def probe_path(url: str, timeout: int = 6) -> Dict[str, Any]:
    """Curls an endpoint measuring connect, appconnect (tls), and total times."""
    cmd = [
        "curl", "--noproxy", "*", "-sS", "-o", "/dev/null",
        "-w", "%{time_connect} %{time_appconnect} %{time_total} %{http_code}",
        "--max-time", str(timeout), url
    ]
    code, stdout, _ = run_command(cmd, timeout=timeout + 2.0)
    if code != 0 or not stdout:
        return {"ok": False, "http_code": "000", "connect_s": 0.0, "tls_s": 0.0, "total_s": float(timeout)}

    parts = stdout.strip().split()
    if len(parts) != 4:
        return {"ok": False, "http_code": "000", "connect_s": 0.0, "tls_s": 0.0, "total_s": float(timeout)}

    conn, tls, total, http_code = parts
    try:
        c_f, t_f, tot_f = float(conn), float(tls), float(total)
    except ValueError:
        return {"ok": False, "http_code": http_code, "connect_s": 0.0, "tls_s": 0.0, "total_s": float(timeout)}

    is_ok = http_code in ("200", "204")
    return {
        "ok": is_ok,
        "http_code": http_code,
        "connect_s": round(c_f, 4),
        "tls_s": round(t_f, 4),
        "total_s": round(tot_f, 4),
    }


def probe_dns(host: str = DNS_HOST) -> Dict[str, Any]:
    """Resolves a host name, validating Fake-IP mapping and DNS latency."""
    t0 = time.time()
    try:
        infos = socket.getaddrinfo(host, 443, family=socket.AF_INET)
        lat = (time.time() - t0) * 1000.0
        ip = infos[0][4][0]
        is_fake = ip.startswith("198.18.") or ip.startswith("198.19.")
        return {
            "ok": True,
            "host": host,
            "ip": ip,
            "is_fake_ip": is_fake,
            "latency_ms": round(lat, 2),
            "error": None,
        }
    except Exception as e:
        return {
            "ok": False,
            "host": host,
            "ip": None,
            "is_fake_ip": False,
            "latency_ms": -1.0,
            "error": str(e),
        }


def inspect_unified_logs(window_minutes: int = 1) -> Dict[str, Any]:
    """Scrapes Unified Log (os_log) for errors and faults in AetherRoute subsystem/processes."""
    predicate = (
        '(process == "AetherRoute" OR process == "com.aetherroute.desktop.tunnel" '
        'OR subsystem == "com.aetherroute.desktop") '
        'AND (messageType == error OR messageType == fault)'
    )
    cmd = [
        "/usr/bin/log", "show",
        "--predicate", predicate,
        "--last", f"{window_minutes}m",
        "--style", "compact",
    ]
    code, stdout, stderr = run_command(cmd, timeout=20.0)

    summary: Dict[str, Any] = {
        "total_errors": 0,
        "total_faults": 0,
        "nw_unconnected_calls": 0,
        "tcp_copy_failures": 0,
        "adapter_send_failures": 0,
        "panics_or_asserts": 0,
        "samples": [],
    }

    if code != 0 or not stdout:
        return summary

    for line in stdout.splitlines():
        clean = line.strip()
        if not clean or clean.startswith("Timestamp") or clean.startswith("---"):
            continue
        if " E " in clean or " [Error] " in clean:
            summary["total_errors"] += 1
        elif " F " in clean or " [Fault] " in clean:
            summary["total_faults"] += 1

        clean_lower = clean.lower()
        if "on unconnected nw_connection" in clean_lower:
            summary["nw_unconnected_calls"] += 1
        if "tcp_copy" in clean_lower and "failed" in clean_lower:
            summary["tcp_copy_failures"] += 1
        if "dispatcher_adapter_send_failed" in clean_lower:
            summary["adapter_send_failures"] += 1
        if "panic" in clean_lower or "assertion" in clean_lower:
            summary["panics_or_asserts"] += 1

        if len(summary["samples"]) < 20:
            summary["samples"].append(clean)

    return summary


def scan_recent_crashes(cutoff_timestamp: float) -> List[Dict[str, Any]]:
    """Scans system and user DiagnosticReports for AetherRoute crashes since timestamp."""
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
                name_l = item.name.lower()
                if not ("aether" in name_l or "tunnel" in name_l):
                    continue
                if not item.suffix in (".ips", ".crash"):
                    continue
                try:
                    if item.stat().st_mtime >= cutoff_timestamp:
                        crashes.append({
                            "file": str(item),
                            "name": item.name,
                            "mtime": item.stat().st_mtime,
                        })
                except OSError:
                    continue
        except OSError:
            continue
    return crashes


# ==============================================================================
# 2. Anomaly Detection & Incident Forensics
# ==============================================================================

class AnomalyEngine:
    def __init__(self):
        self.history: List[Dict[str, Any]] = []
        self.strike_counts: Dict[str, int] = {
            "cpu_app": 0,
            "cpu_tunnel": 0,
            "proxy_degraded": 0,
        }
        self.last_incident_time: Dict[str, float] = {}

    def update_and_detect(
        self,
        sample: Dict[str, Any],
        crashes: List[Dict[str, Any]],
    ) -> Tuple[str, List[str], List[str]]:
        """Evaluates health status: returns (verdict, issues, anomaly_flags)."""
        self.history.append(sample)
        if len(self.history) > 120:  # Retain last 2 hours of history
            self.history.pop(0)

        issues: List[str] = []
        flags: List[str] = []
        verdict = "HEALTHY"

        app = sample.get("app")
        tunnel = sample.get("tunnel")
        net = sample.get("network", {})
        dns = sample.get("dns", {})
        logs = sample.get("logs", {})

        # 1. Process presence & lifecycle
        if not app:
            verdict = "CRITICAL"
            issues.append("AetherRoute UI Application process is not running.")
            flags.append("PROCESS_APP_MISSING")
        if not tunnel:
            verdict = "CRITICAL"
            issues.append("AetherRoute Tunnel System Extension process is not running.")
            flags.append("PROCESS_TUNNEL_MISSING")

        # Check PID continuity
        if len(self.history) >= 2:
            prev = self.history[-2]
            if app and prev.get("app") and app["pid"] != prev["app"]["pid"]:
                verdict = "CRITICAL"
                issues.append(f"AetherRoute App process restarted (Old PID: {prev['app']['pid']} -> New PID: {app['pid']})")
                flags.append("APP_PID_RESTARTED")
            if tunnel and prev.get("tunnel") and tunnel["pid"] != prev["tunnel"]["pid"]:
                verdict = "CRITICAL"
                issues.append(f"AetherRoute Tunnel process restarted (Old PID: {prev['tunnel']['pid']} -> New PID: {tunnel['pid']})")
                flags.append("TUNNEL_PID_RESTARTED")

        # 2. Crashes
        if crashes:
            verdict = "CRITICAL"
            issues.append(f"Detected {len(crashes)} new crash report(s) in DiagnosticReports!")
            flags.append("CRASH_DETECTED")

        # 3. CPU high sustained
        if app:
            if app["cpu_percent"] >= LIMITS["CPU_PERCENT_HIGH"]:
                self.strike_counts["cpu_app"] += 1
            else:
                self.strike_counts["cpu_app"] = 0

            if self.strike_counts["cpu_app"] >= LIMITS["CPU_STRIKES"]:
                if verdict != "CRITICAL":
                    verdict = "WARNING"
                issues.append(f"App CPU sustained high: {app['cpu_percent']}% for {self.strike_counts['cpu_app']} min")
                flags.append("CPU_APP_SUSTAINED_HIGH")

        if tunnel:
            if tunnel["cpu_percent"] >= LIMITS["CPU_PERCENT_HIGH"]:
                self.strike_counts["cpu_tunnel"] += 1
            else:
                self.strike_counts["cpu_tunnel"] = 0

            if self.strike_counts["cpu_tunnel"] >= LIMITS["CPU_STRIKES"]:
                if verdict != "CRITICAL":
                    verdict = "WARNING"
                issues.append(f"Tunnel CPU sustained high: {tunnel['cpu_percent']}% for {self.strike_counts['cpu_tunnel']} min")
                flags.append("CPU_TUNNEL_SUSTAINED_HIGH")

        # 4. Memory footprint thresholds & creep (leak) detection
        if app:
            fp = app.get("footprint_mb")
            rss = app.get("rss_mb", 0.0)
            target_mem = fp if fp is not None else rss
            if target_mem > LIMITS["APP_FOOTPRINT_MB"]:
                if verdict != "CRITICAL":
                    verdict = "WARNING"
                issues.append(f"App memory footprint elevated: {target_mem} MB > {LIMITS['APP_FOOTPRINT_MB']} MB")
                flags.append("APP_MEMORY_HIGH")

            # Check memory creep trend (last 15-30 samples) using strictly consistent metric type
            valid_fps = [h["app"]["footprint_mb"] for h in self.history[-30:] if h.get("app") and h["app"].get("footprint_mb") is not None]
            recent_mems = valid_fps if len(valid_fps) >= 15 else [
                h["app"]["rss_mb"] for h in self.history[-30:] if h.get("app") and h["app"].get("rss_mb") is not None
            ]
            if len(recent_mems) >= 15:
                # Monotonic creep check: end - start > creep threshold and slope positive
                delta = recent_mems[-1] - recent_mems[0]
                if delta >= LIMITS["MEMORY_CREEP_MB"]:
                    # Compute linear slope
                    n = len(recent_mems)
                    x_mean = (n - 1) / 2.0
                    y_mean = sum(recent_mems) / n
                    num = sum((i - x_mean) * (recent_mems[i] - y_mean) for i in range(n))
                    den = sum((i - x_mean) ** 2 for i in range(n))
                    slope = (num / den) if den > 0 else 0
                    if slope > 0.5:  # Steadily rising > 0.5 MB/min
                        if verdict != "CRITICAL":
                            verdict = "WARNING"
                        issues.append(f"Possible memory leak detected: App footprint increased +{delta:.1f} MB in last {n}m (slope={slope:.2f}MB/min)")
                        flags.append("MEMORY_LEAK_WARNING")

        if tunnel and tunnel["rss_mb"] > LIMITS["TUNNEL_RSS_MB"]:
            if verdict != "CRITICAL":
                verdict = "WARNING"
            issues.append(f"Tunnel RSS elevated: {tunnel['rss_mb']} MB > {LIMITS['TUNNEL_RSS_MB']} MB")
            flags.append("TUNNEL_MEMORY_HIGH")

        # 5. Socket leaks & file descriptors
        app_close_wait = net.get("app_close_wait", 0)
        if app_close_wait >= LIMITS["APP_CLOSE_WAIT"]:
            if verdict != "CRITICAL":
                verdict = "WARNING"
            issues.append(f"Socket leak: App has {app_close_wait} unclosed CLOSE_WAIT sockets")
            flags.append("SOCKET_LEAK_CLOSE_WAIT")

        if app and app.get("fd_count", 0) >= LIMITS["APP_FD_COUNT"]:
            if verdict != "CRITICAL":
                verdict = "WARNING"
            issues.append(f"App open file descriptors high: {app['fd_count']} FDs")
            flags.append("FD_COUNT_HIGH")

        # 6. Data Plane Probes (Differential Analysis)
        p_probe = net.get("proxy_probe", {})
        d_probe = net.get("direct_probe", {})
        p_ok = p_probe.get("ok", False)
        p_tot = p_probe.get("total_s", 0.0)
        p_tls = p_probe.get("tls_s", 0.0)
        d_ok = d_probe.get("ok", False)

        is_proxy_degraded = (not p_ok) or p_tot > LIMITS["PROXIED_TOTAL_SEC"] or p_tls > LIMITS["PROXIED_TLS_SEC"]
        # Direct probe is control: only strike if direct is fine (not host network down)
        if is_proxy_degraded and d_ok:
            self.strike_counts["proxy_degraded"] += 1
        else:
            self.strike_counts["proxy_degraded"] = 0

        if self.strike_counts["proxy_degraded"] >= LIMITS["PROBE_STRIKES"]:
            if verdict != "CRITICAL":
                verdict = "WARNING"
            issues.append(f"Proxy path degraded ({self.strike_counts['proxy_degraded']} strikes): total={p_tot:.2f}s, code={p_probe.get('http_code')}")
            flags.append("PROXY_PATH_DEGRADED")
        elif not p_ok and not d_ok:
            issues.append("Host network appears offline (both proxy and direct probes timed out).")

        # 7. DNS Check
        if not dns.get("ok", False) or dns.get("latency_ms", 0) > LIMITS["DNS_LATENCY_MS"]:
            if verdict != "CRITICAL":
                verdict = "WARNING"
            issues.append(f"DNS probe degraded: latency={dns.get('latency_ms')}ms, error={dns.get('error')}")
            flags.append("DNS_DEGRADED")

        # 8. Virtual TUN errors
        utun = net.get("utun")
        if utun and (utun.get("ierrs", 0) > 0 or utun.get("oerrs", 0) > 0):
            if verdict != "CRITICAL":
                verdict = "WARNING"
            issues.append(f"UTUN packet errors reported: in_errs={utun.get('ierrs')}, out_errs={utun.get('oerrs')}")
            flags.append("UTUN_PACKET_ERRORS")

        # 9. Logs critical errors
        if logs.get("panics_or_asserts", 0) > 0:
            verdict = "CRITICAL"
            issues.append(f"Detected {logs['panics_or_asserts']} panic/assert logs in unified log!")
            flags.append("PANIC_LOG_DETECTED")
        elif (logs.get("total_errors", 0) + logs.get("total_faults", 0)) > 30:
            if verdict != "CRITICAL":
                verdict = "WARNING"
            issues.append(f"High error frequency: {logs['total_errors']} errors/faults in last minute")
            flags.append("HIGH_LOG_ERRORS")

        if not issues:
            issues.append("All operational checks normal.")

        return verdict, issues, flags

    def should_capture_incident(self, flag: str, now: float) -> bool:
        """Enforces incident cooldown so we don't snapshot repeatedly on the same failure."""
        last = self.last_incident_time.get(flag, 0.0)
        if now - last >= LIMITS["INCIDENT_COOLDOWN_SEC"]:
            self.last_incident_time[flag] = now
            return True
        return False


def capture_incident_evidence(
    incident_dir: Path,
    flag: str,
    verdict: str,
    issues: List[str],
    sample: Dict[str, Any],
) -> Path:
    """Captures deep diagnostic evidence (sample stack, lsof FDs, log dump, vmmap)."""
    incident_dir.mkdir(parents=True, exist_ok=True)

    app = sample.get("app")
    app_pid = app["pid"] if app else None

    # 1. Summary JSON
    summary = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "flag": flag,
        "verdict": verdict,
        "issues": issues,
        "sample": sample,
    }
    (incident_dir / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")

    # 2. Thread stack dump via `sample`
    if app_pid:
        sample_file = incident_dir / "thread_sample.txt"
        run_command(["sample", str(app_pid), "2", "10", "-file", str(sample_file)], timeout=8.0)

    # 3. Lsof handles and open sockets
    if app_pid:
        _, lsof_out, _ = run_command(["lsof", "-n", "-P", "-p", str(app_pid)], timeout=5.0)
        (incident_dir / "open_files_lsof.txt").write_text(lsof_out, encoding="utf-8")

    # 4. vmmap memory breakdown
    if app_pid:
        _, vm_out, _ = run_command(["vmmap", "-summary", str(app_pid)], timeout=8.0)
        (incident_dir / "vmmap_summary.txt").write_text(vm_out, encoding="utf-8")

    # 5. Recent unified logs (last 5 minutes)
    cmd_log = [
        "/usr/bin/log", "show",
        "--predicate", 'process == "AetherRoute" OR process == "com.aetherroute.desktop.tunnel" OR subsystem == "com.aetherroute.desktop"',
        "--last", "5m",
        "--style", "compact",
    ]
    _, log_out, _ = run_command(cmd_log, timeout=15.0)
    (incident_dir / "recent_errors.log").write_text(log_out, encoding="utf-8")

    return incident_dir


# ==============================================================================
# 3. Output Writers & Formatting
# ==============================================================================

CSV_HEADERS = [
    "timestamp_iso",
    "epoch",
    "verdict",
    "anomaly_flags",
    "app_pid",
    "app_cpu",
    "app_rss_mb",
    "app_footprint_mb",
    "app_threads",
    "app_fds",
    "tunnel_pid",
    "tunnel_cpu",
    "tunnel_rss_mb",
    "tunnel_threads",
    "tunnel_fds",
    "app_close_wait",
    "tcp_established",
    "tcp_close_wait",
    "tcp_time_wait",
    "proxy_ok",
    "proxy_http_code",
    "proxy_conn_s",
    "proxy_tls_s",
    "proxy_total_s",
    "direct_ok",
    "direct_http_code",
    "direct_total_s",
    "dns_ok",
    "dns_latency_ms",
    "dns_is_fake_ip",
    "utun_name",
    "utun_ipkts",
    "utun_opkts",
    "utun_ierrs",
    "utun_oerrs",
    "log_errors_1m",
    "log_faults_1m",
    "log_unconnected_calls",
    "log_tcp_copy_errs",
]


def write_csv_row(csv_path: Path, sample: Dict[str, Any], verdict: str, flags: List[str]) -> None:
    file_exists = csv_path.exists()
    app = sample.get("app") or {}
    tun = sample.get("tunnel") or {}
    net = sample.get("network") or {}
    tcp = net.get("tcp_states") or {}
    prx = net.get("proxy_probe") or {}
    drt = net.get("direct_probe") or {}
    dns = sample.get("dns") or {}
    utn = net.get("utun") or {}
    log = sample.get("logs") or {}

    row = [
        sample["timestamp_iso"],
        sample["epoch"],
        verdict,
        ";".join(flags) if flags else "NONE",
        app.get("pid", ""),
        app.get("cpu_percent", ""),
        app.get("rss_mb", ""),
        app.get("footprint_mb", ""),
        app.get("thread_count", ""),
        app.get("fd_count", ""),
        tun.get("pid", ""),
        tun.get("cpu_percent", ""),
        tun.get("rss_mb", ""),
        tun.get("thread_count", ""),
        tun.get("fd_count", ""),
        net.get("app_close_wait", ""),
        tcp.get("ESTABLISHED", 0),
        tcp.get("CLOSE_WAIT", 0),
        tcp.get("TIME_WAIT", 0),
        prx.get("ok", False),
        prx.get("http_code", ""),
        prx.get("connect_s", ""),
        prx.get("tls_s", ""),
        prx.get("total_s", ""),
        drt.get("ok", False),
        drt.get("http_code", ""),
        drt.get("total_s", ""),
        dns.get("ok", False),
        dns.get("latency_ms", ""),
        dns.get("is_fake_ip", False),
        utn.get("interface", ""),
        utn.get("ipkts", ""),
        utn.get("opkts", ""),
        utn.get("ierrs", ""),
        utn.get("oerrs", ""),
        log.get("total_errors", 0),
        log.get("total_faults", 0),
        log.get("nw_unconnected_calls", 0),
        log.get("tcp_copy_failures", 0),
    ]

    with open(csv_path, "a", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        if not file_exists:
            writer.writerow(CSV_HEADERS)
        writer.writerow(row)


def write_jsonl_row(jsonl_path: Path, sample: Dict[str, Any]) -> None:
    with open(jsonl_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(sample, ensure_ascii=False) + "\n")


def log_incident_entry(incidents_jsonl: Path, entry: Dict[str, Any]) -> None:
    with open(incidents_jsonl, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def print_terminal_line(sample: Dict[str, Any], verdict: str, issues: List[str], flags: List[str]) -> None:
    t_str = datetime.fromtimestamp(sample["epoch"]).strftime("%H:%M:%S")
    app = sample.get("app") or {}
    tun = sample.get("tunnel") or {}
    net = sample.get("network") or {}
    prx = net.get("proxy_probe") or {}
    drt = net.get("direct_probe") or {}
    dns = sample.get("dns") or {}

    color = "\033[92m" if verdict == "HEALTHY" else ("\033[93m" if verdict == "WARNING" else "\033[91m")
    reset = "\033[0m"

    app_fp = f"{app.get('footprint_mb')}M" if app.get("footprint_mb") is not None else f"{app.get('rss_mb', 0)}M(rss)"
    tun_rss = f"{tun.get('rss_mb', 0)}M"
    p_stat = f"{prx.get('total_s', -1):.2f}s({prx.get('http_code', 'err')})"
    d_stat = f"{drt.get('total_s', -1):.2f}s({drt.get('http_code', 'err')})"
    cw = net.get("app_close_wait", 0)

    summary = (
        f"[{t_str}] {color}[{verdict:<7}]{reset} "
        f"App(CPU:{app.get('cpu_percent', 0):>4.1f}% FP:{app_fp:>6} FD:{app.get('fd_count', 0):>3}) | "
        f"Tun(CPU:{tun.get('cpu_percent', 0):>4.1f}% RSS:{tun_rss:>5}) | "
        f"Net(CW:{cw} Prx:{p_stat:>8} Dir:{d_stat:>8} DNS:{dns.get('latency_ms', -1):>4.0f}ms)"
    )
    if flags:
        summary += f" | {color}Alert: {';'.join(flags)}{reset}"
    print(summary)


# ==============================================================================
# 4. Main Execution Engine
# ==============================================================================

def perform_single_sample(
    engine: AnomalyEngine,
    output_dir: Path,
    last_crash_check: float,
) -> Tuple[Dict[str, Any], str, List[str], List[str]]:
    now_ts = time.time()
    iso_str = datetime.now(timezone.utc).isoformat()

    # Collectors
    processes = inspect_processes()
    app_pid = processes["app"]["pid"] if processes["app"] else None
    tcp_info = inspect_tcp_and_sockets(app_pid=app_pid)
    utun_info = inspect_utun()
    proxy_probe = probe_path(PROXIED_URL)
    direct_probe = probe_path(DIRECT_URL)
    dns_probe = probe_dns(DNS_HOST)
    logs_info = inspect_unified_logs(window_minutes=1)
    crashes = scan_recent_crashes(cutoff_timestamp=last_crash_check)

    sample = {
        "timestamp_iso": iso_str,
        "epoch": int(now_ts),
        "app": processes["app"],
        "tunnel": processes["tunnel"],
        "network": {
            "tcp_states": tcp_info["states"],
            "app_close_wait": tcp_info["app_close_wait"],
            "utun": utun_info,
            "proxy_probe": proxy_probe,
            "direct_probe": direct_probe,
        },
        "dns": dns_probe,
        "logs": logs_info,
    }

    verdict, issues, flags = engine.update_and_detect(sample, crashes)
    sample["verdict"] = verdict
    sample["issues"] = issues
    sample["anomaly_flags"] = flags

    # Persistence
    csv_path = output_dir / "metrics_minute.csv"
    jsonl_path = output_dir / "timeseries.jsonl"
    incidents_path = output_dir / "incidents.jsonl"

    write_csv_row(csv_path, sample, verdict, flags)
    write_jsonl_row(jsonl_path, sample)

    # Trigger forensic incident capture if needed
    for flag in flags:
        if engine.should_capture_incident(flag, now_ts):
            stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            inc_dir = output_dir / "incidents" / f"{stamp}_{flag}"
            capture_incident_evidence(inc_dir, flag, verdict, issues, sample)
            log_incident_entry(incidents_path, {
                "timestamp": iso_str,
                "flag": flag,
                "verdict": verdict,
                "issues": issues,
                "incident_dir": str(inc_dir),
            })
            print(f"  \033[95m[INCIDENT CAPTURED]\033[0m Evidence snapshot saved to: {inc_dir}")

    return sample, verdict, issues, flags


def main() -> int:
    parser = argparse.ArgumentParser(description="AetherRoute 1-minute runtime performance and anomaly monitor daemon.")
    parser.add_argument("--interval", type=int, default=60, help="Sampling interval in seconds (default: 60)")
    parser.add_argument("--hours", type=float, default=0, help="Total hours to run (0 = run indefinitely until Ctrl-C)")
    parser.add_argument("--output-dir", type=str, default=str(DEFAULT_OUT_DIR), help=f"Directory to save metrics (default: {DEFAULT_OUT_DIR})")
    parser.add_argument("--once", action="store_true", help="Take a single sample and display complete health check")
    parser.add_argument("--quiet", action="store_true", help="Quiet output (suppress standard per-minute line)")
    args = parser.parse_args()

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    engine = AnomalyEngine()
    start_time = time.time()
    last_crash_check = start_time - 3600  # Scan past 1 hour initially
    deadline = start_time + (args.hours * 3600.0) if args.hours > 0 else None

    if args.once:
        sample, verdict, issues, flags = perform_single_sample(engine, out_dir, last_crash_check)
        print_terminal_line(sample, verdict, issues, flags)
        print("\n--- Detailed Health Findings ---")
        for iss in issues:
            print(f"  • {iss}")
        return 0 if verdict in ("HEALTHY", "WARNING") else 1

    print(f"================================================================================")
    print(f" AetherRoute Monitor Daemon Started")
    print(f" Output Directory : {out_dir}")
    print(f" Sampling Rate    : Every {args.interval}s (1 minute)")
    print(f" Planned Duration : {'Indefinite (Ctrl-C to stop)' if args.hours == 0 else f'{args.hours} hours'}")
    print(f"================================================================================")

    try:
        while True:
            t0 = time.time()
            if deadline and t0 >= deadline:
                print(f"\nCompleted specified duration of {args.hours} hours. Exiting.")
                break

            sample, verdict, issues, flags = perform_single_sample(engine, out_dir, last_crash_check)
            last_crash_check = t0

            if not args.quiet:
                print_terminal_line(sample, verdict, issues, flags)

            elapsed = time.time() - t0
            sleep_time = max(1.0, args.interval - elapsed)
            time.sleep(sleep_time)

    except KeyboardInterrupt:
        print("\nMonitoring stopped by user.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
