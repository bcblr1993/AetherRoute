#!/usr/bin/env python3
"""
AetherRoute 3-Hour Real-Time Health, Resource & Incident Monitor
================================================================
Monitors AetherRoute host application, packet tunnel extension, and
transparent proxy extension every 1 minute for 3 hours (180 samples).

Collects:
1. Process Lifecycle & Resource Usage:
   - PID, PPID, %CPU, CPUTime, RSS (MB), PhysFootprint (MB), VSZ (MB), Mach Threads, Open FDs
2. Dynamic Network Mode & Data Plane:
   - Auto-detects TUN mode vs Transparent Proxy mode
   - Interface byte/packet deltas, transfer rates
   - Dual-probe latency: DNS resolution (apple.com) & HTTP connectivity (Cloudflare generate_204)
3. Socket States:
   - Gateway TCP states (ESTABLISHED, CLOSE_WAIT, TIME_WAIT, SYN_SENT, etc.)
4. Host System Telemetry:
   - Load averages (1m, 5m, 15m), swap usage
5. Error & Log Mining:
   - Unified OSLog real-time window delta with benign teardown noise filtering
   - App Group log monitoring (~/Library/Group Containers/group.com.aetherroute.desktop)
   - CrashReporter detection (~/Library/Logs/DiagnosticReports)
6. Real-Time Anomaly & Incident Detection:
   - Sustained high CPU (>30% for 3+ cycles)
   - Memory creep / linear regression slope (>15 MB/h over window)
   - Unexpected process restarts / crashes
   - Gateway socket leaks (excessive CLOSE_WAIT)
   - Network connectivity timeouts
7. Output Artifacts:
   - metrics.jsonl & metrics.csv (time-series metrics)
   - incidents.jsonl (structured incident log)
   - status_summary.json (live status)
   - dashboard.md (live auto-refreshing Markdown dashboard)
   - diagnostic_snapshots/ (forensic dumps on incidents)
"""

import argparse
import csv
import datetime
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

DEFAULT_OUTPUT_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "outputs", "monitor_3h")
)

APP_BINARY_NAME = "AetherRoute"
INSTALLED_APP_BINARY = "/Applications/AetherRoute.app/Contents/MacOS/AetherRoute"
TUNNEL_EXT_ID = "com.aetherroute.desktop.tunnel"
PROXY_EXT_ID = "com.aetherroute.desktop.transparent-proxy"
TUNNEL_GATEWAY_IP = "198.18.0.1"

DNS_PROBE_HOST = "apple.com"
HTTP_PROBE_URL = "https://cp.cloudflare.com/generate_204"

# Memory slope analysis parameters
MEMORY_HISTORY_MAX_SAMPLES = 180
MEMORY_MIN_SPAN_HOURS = 0.5  # Need at least 30 mins to calculate trend
MEMORY_SLOPE_THRESHOLD_MB_PER_H = 15.0
MEMORY_GROWTH_THRESHOLD_MB = 25.0


def _least_squares_slope(samples: List[Tuple[float, float]]) -> float:
    """Calculates linear slope (MB/hour) across (elapsed_hours, megabytes) samples."""
    count = len(samples)
    if count < 2:
        return 0.0
    mean_x = sum(x for x, _ in samples) / count
    mean_y = sum(y for _, y in samples) / count
    numerator = sum((x - mean_x) * (y - mean_y) for x, y in samples)
    denominator = sum((x - mean_x) ** 2 for x, _ in samples)
    return numerator / denominator if denominator else 0.0


class IncidentSeverity:
    P1_CRITICAL = "P1_CRITICAL"
    P2_WARNING = "P2_WARNING"
    P3_NOTICE = "P3_NOTICE"


class TelemetryCollector3H:
    def __init__(self, output_dir: str, interval: int = 60, duration_hours: float = 3.0):
        self.output_dir = output_dir
        self.interval = interval
        self.duration_hours = duration_hours
        self.target_samples = max(1, int((duration_hours * 3600) / interval))
        self.snapshots_dir = os.path.join(output_dir, "diagnostic_snapshots")

        os.makedirs(self.output_dir, exist_ok=True)
        os.makedirs(self.snapshots_dir, exist_ok=True)

        self.metrics_jsonl = os.path.join(output_dir, "metrics.jsonl")
        self.metrics_csv = os.path.join(output_dir, "metrics.csv")
        self.incidents_jsonl = os.path.join(output_dir, "incidents.jsonl")
        self.summary_file = os.path.join(output_dir, "status_summary.json")
        self.dashboard_file = os.path.join(output_dir, "dashboard.md")
        self.log_file = os.path.join(output_dir, "monitor.log")
        self.pid_file = os.path.join(output_dir, "monitor.pid")

        # Runtime trackers
        self.start_time = time.time()
        self.samples_collected = 0
        self.total_incidents = 0
        self.recent_incidents: List[Dict[str, Any]] = []

        self.last_netstat = None
        self.last_timestamp = None
        self.last_pids: Dict[str, Optional[int]] = {}
        self.high_cpu_counters: Dict[str, int] = {"app": 0, "tunnel": 0, "proxy": 0}
        self.memory_history: Dict[str, List[Tuple[float, float]]] = {"app": [], "tunnel": [], "proxy": []}
        self.probe_failure_strikes = 0

        # Scan initial crash reports to detect newly generated ones
        self.initial_crash_reports = self._scan_crash_reports()

        # Track app group log positions
        self.appgroup_log_positions: Dict[str, int] = {}
        log_dir = os.path.expanduser(
            "~/Library/Group Containers/group.com.aetherroute.desktop/Library/Application Support/AetherRoute/Logs"
        )
        if os.path.isdir(log_dir):
            for fname in os.listdir(log_dir):
                if fname.endswith(".log"):
                    fpath = os.path.join(log_dir, fname)
                    try:
                        self.appgroup_log_positions[fpath] = os.path.getsize(fpath)
                    except Exception:
                        pass

        # CSV Header
        self._init_csv()

    def _init_csv(self):
        if not os.path.exists(self.metrics_csv):
            headers = [
                "timestamp", "sample_index", "elapsed_sec", "mode",
                "app_running", "app_pid", "app_cpu", "app_rss_mb", "app_footprint_mb", "app_threads", "app_fds",
                "tunnel_running", "tunnel_pid", "tunnel_cpu", "tunnel_rss_mb",
                "proxy_running", "proxy_pid", "proxy_cpu", "proxy_rss_mb",
                "dns_latency_ms", "dns_ok", "http_latency_ms", "http_ok", "http_status",
                "tcp_established", "tcp_close_wait", "tcp_time_wait",
                "load_1m", "swap_mb", "oslog_errors", "oslog_faults", "anomalies_count"
            ]
            with open(self.metrics_csv, "w", newline="", encoding="utf-8") as f:
                writer = csv.writer(f)
                writer.writerow(headers)

    def log(self, message: str):
        now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{now_str}] {message}"
        print(line, flush=True)
        try:
            with open(self.log_file, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except Exception:
            pass

    def _run_cmd(self, args: List[str], timeout: float = 12.0) -> Tuple[int, str, str]:
        try:
            p = subprocess.run(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=timeout,
            )
            stdout = p.stdout.decode("utf-8", errors="replace").strip()
            stderr = p.stderr.decode("utf-8", errors="replace").strip()
            return p.returncode, stdout, stderr
        except subprocess.TimeoutExpired:
            return -1, "", f"Command timed out after {timeout}s: {' '.join(args)}"
        except Exception as e:
            return -1, "", str(e)

    def _scan_crash_reports(self) -> Set[str]:
        reports = set()
        dirs = [
            os.path.expanduser("~/Library/Logs/DiagnosticReports"),
            "/Library/Logs/DiagnosticReports",
        ]
        for d in dirs:
            if not os.path.isdir(d):
                continue
            try:
                for entry in os.listdir(d):
                    if "aetherroute" in entry.lower():
                        reports.add(os.path.join(d, entry))
            except Exception:
                pass
        return reports

    def get_phys_footprint_mb(self, pid: int) -> float:
        code, out, _ = self._run_cmd(["/usr/bin/footprint", "-p", str(pid)], timeout=8.0)
        if code != 0:
            return 0.0
        for line in out.splitlines():
            if "phys_footprint:" in line:
                parts = line.split()
                try:
                    val = float(parts[-2])
                    unit = parts[-1].upper()
                    if unit.startswith("G"):
                        val *= 1024.0
                    elif unit.startswith("K"):
                        val /= 1024.0
                    return round(val, 2)
                except (IndexError, ValueError):
                    return 0.0
        return 0.0

    def collect_processes(self) -> Dict[str, Dict[str, Any]]:
        processes = {
            "app": {"running": False, "pid": None, "ppid": None, "cpu": 0.0, "cputime": "", "rss_mb": 0.0, "footprint_mb": 0.0, "vsz_mb": 0.0, "threads": 0, "fds": 0, "command": ""},
            "tunnel": {"running": False, "pid": None, "ppid": None, "cpu": 0.0, "cputime": "", "rss_mb": 0.0, "footprint_mb": 0.0, "vsz_mb": 0.0, "threads": 0, "fds": 0, "command": ""},
            "proxy": {"running": False, "pid": None, "ppid": None, "cpu": 0.0, "cputime": "", "rss_mb": 0.0, "footprint_mb": 0.0, "vsz_mb": 0.0, "threads": 0, "fds": 0, "command": ""},
        }

        code, out, _ = self._run_cmd(["ps", "-eo", "pid,ppid,%cpu,cputime,rss,vsz,command"])
        if code == 0:
            for line in out.splitlines()[1:]:
                parts = line.strip().split(None, 6)
                if len(parts) < 7:
                    continue
                pid_str, ppid_str, cpu_str, cputime_str, rss_str, vsz_str, cmd = parts
                cmd_clean = cmd.strip()

                target_key = None
                if cmd_clean == INSTALLED_APP_BINARY or (cmd_clean.endswith("/MacOS/AetherRoute") and "SystemExtensions" not in cmd_clean):
                    target_key = "app"
                elif "/Library/SystemExtensions/" in cmd_clean and cmd_clean.endswith(f"/Contents/MacOS/{TUNNEL_EXT_ID}"):
                    target_key = "tunnel"
                elif "/Library/SystemExtensions/" in cmd_clean and cmd_clean.endswith(f"/Contents/MacOS/{PROXY_EXT_ID}"):
                    target_key = "proxy"

                if target_key and not processes[target_key]["running"]:
                    try:
                        pid = int(pid_str)
                        cpu = float(cpu_str)
                        rss_mb = round(int(rss_str) / 1024.0, 2)
                        vsz_mb = round(int(vsz_str) / 1024.0, 2)

                        # Thread count
                        t_code, t_out, _ = self._run_cmd(["ps", "-M", "-p", str(pid)], timeout=3.0)
                        threads = max(0, len(t_out.splitlines()) - 1) if t_code == 0 else 0

                        # FDs count
                        fds = 0
                        f_code, f_out, _ = self._run_cmd(["lsof", "-p", str(pid)], timeout=4.0)
                        if f_code == 0:
                            fds = max(0, len(f_out.splitlines()) - 1)

                        footprint_mb = self.get_phys_footprint_mb(pid)

                        processes[target_key] = {
                            "running": True,
                            "pid": pid,
                            "ppid": int(ppid_str),
                            "cpu": cpu,
                            "cputime": cputime_str,
                            "rss_mb": rss_mb,
                            "footprint_mb": footprint_mb,
                            "vsz_mb": vsz_mb,
                            "threads": threads,
                            "fds": fds,
                            "command": cmd_clean[:120],
                        }
                    except Exception:
                        pass

        return processes

    def collect_system_extensions(self) -> Dict[str, Dict[str, Any]]:
        status = {
            "tunnel": {"found": False, "status": "unknown", "version": ""},
            "proxy": {"found": False, "status": "unknown", "version": ""},
        }
        code, out, _ = self._run_cmd(["/usr/bin/systemextensionsctl", "list"])
        if code == 0:
            for line in out.splitlines():
                if TUNNEL_EXT_ID in line:
                    status["tunnel"]["found"] = True
                    m = re.search(r"\((\d+\.\d+\.\d+/[^\)]+)\)", line)
                    if m:
                        status["tunnel"]["version"] = m.group(1)
                    if "[activated enabled]" in line:
                        status["tunnel"]["status"] = "activated enabled"
                elif PROXY_EXT_ID in line:
                    status["proxy"]["found"] = True
                    m = re.search(r"\((\d+\.\d+\.\d+/[^\)]+)\)", line)
                    if m:
                        status["proxy"]["version"] = m.group(1)
                    if "[activated enabled]" in line:
                        status["proxy"]["status"] = "activated enabled"
        return status

    def collect_network(self, processes: Dict[str, Any]) -> Dict[str, Any]:
        net_info = {
            "mode": "unknown",
            "interface": None,
            "ip": None,
            "status": "down",
            "ibytes": 0,
            "obytes": 0,
            "ipkts": 0,
            "opkts": 0,
            "ierrs": 0,
            "oerrs": 0,
            "delta_ibytes": 0,
            "delta_obytes": 0,
            "rate_ibytes_sec": 0.0,
            "rate_obytes_sec": 0.0,
        }

        # Check for TUN interface bound to 198.18.0.1
        code, out, _ = self._run_cmd(["ifconfig"])
        if code == 0:
            current_iface = None
            for line in out.splitlines():
                if re.match(r"^[a-zA-Z0-9]+:", line):
                    current_iface = line.split(":")[0]
                elif TUNNEL_GATEWAY_IP in line and current_iface:
                    net_info["interface"] = current_iface
                    net_info["ip"] = TUNNEL_GATEWAY_IP
                    net_info["status"] = "up"
                    net_info["mode"] = "tun"
                    break

        # If not TUN, check if Transparent Proxy process is active
        if net_info["mode"] != "tun" and processes.get("proxy", {}).get("running"):
            net_info["mode"] = "transparent"
            net_info["status"] = "up"
            net_info["interface"] = "transparent_proxy"

        # If interface was found in TUN mode, collect byte counters
        if net_info["interface"] and net_info["interface"] != "transparent_proxy":
            n_code, n_out, _ = self._run_cmd(["netstat", "-I", net_info["interface"], "-b"])
            if n_code == 0:
                lines = n_out.splitlines()
                if len(lines) >= 2:
                    parts = lines[1].split()
                    if len(parts) >= 10:
                        try:
                            ipkts = int(parts[3])
                            ierrs = int(parts[4])
                            ibytes = int(parts[5])
                            opkts = int(parts[6])
                            oerrs = int(parts[7])
                            obytes = int(parts[8])

                            net_info["ipkts"] = ipkts
                            net_info["ierrs"] = ierrs
                            net_info["ibytes"] = ibytes
                            net_info["opkts"] = opkts
                            net_info["oerrs"] = oerrs
                            net_info["obytes"] = obytes

                            if self.last_netstat and self.last_timestamp:
                                time_delta = max(1.0, time.time() - self.last_timestamp)
                                delta_in = max(0, ibytes - self.last_netstat.get("ibytes", ibytes))
                                delta_out = max(0, obytes - self.last_netstat.get("obytes", obytes))
                                net_info["delta_ibytes"] = delta_in
                                net_info["delta_obytes"] = delta_out
                                net_info["rate_ibytes_sec"] = round(delta_in / time_delta, 2)
                                net_info["rate_obytes_sec"] = round(delta_out / time_delta, 2)

                            self.last_netstat = {
                                "ibytes": ibytes, "obytes": obytes, "ipkts": ipkts, "opkts": opkts
                            }
                        except Exception:
                            pass

        return net_info

    def probe_connectivity(self) -> Dict[str, Any]:
        probes = {
            "dns_latency_ms": None,
            "dns_resolved_ip": None,
            "dns_ok": False,
            "dns_error": None,
            "http_latency_ms": None,
            "http_status": None,
            "http_ok": False,
            "http_error": None,
        }

        # DNS probe
        try:
            t0 = time.time()
            res = socket.getaddrinfo(DNS_PROBE_HOST, 443)
            dns_time = (time.time() - t0) * 1000.0
            probes["dns_latency_ms"] = round(dns_time, 2)
            probes["dns_resolved_ip"] = res[0][4][0] if res else None
            probes["dns_ok"] = True
        except Exception as e:
            probes["dns_error"] = str(e)

        # HTTP probe
        try:
            t0 = time.time()
            req = urllib.request.Request(
                HTTP_PROBE_URL,
                headers={"User-Agent": "AetherRoute-3h-Monitor/1.0"},
            )
            with urllib.request.urlopen(req, timeout=5.0) as resp:
                code = resp.getcode()
                probes["http_status"] = code
                probes["http_ok"] = (code in [200, 204])
            probes["http_latency_ms"] = round((time.time() - t0) * 1000.0, 2)
        except urllib.error.HTTPError as e:
            probes["http_status"] = e.code
            probes["http_ok"] = (e.code in [200, 204])
            probes["http_latency_ms"] = round((time.time() - t0) * 1000.0, 2)
        except Exception as e:
            probes["http_error"] = str(e)

        return probes

    def collect_tcp_states(self) -> Dict[str, int]:
        states: Dict[str, int] = {}
        code, out, _ = self._run_cmd(["netstat", "-an", "-p", "tcp"])
        if code == 0:
            for line in out.splitlines():
                if TUNNEL_GATEWAY_IP in line or "7890" in line or "7891" in line:
                    parts = line.split()
                    if len(parts) >= 6:
                        st = parts[5]
                        states[st] = states.get(st, 0) + 1
        return states

    def collect_system(self) -> Dict[str, Any]:
        sys_info = {
            "load_1m": 0.0,
            "load_5m": 0.0,
            "load_15m": 0.0,
            "swap_used_mb": 0.0,
        }
        code, out, _ = self._run_cmd(["uptime"])
        if code == 0:
            m = re.search(r'load averages?:\s+([\d\.]+)\s+([\d\.]+)\s+([\d\.]+)', out)
            if m:
                sys_info["load_1m"] = float(m.group(1))
                sys_info["load_5m"] = float(m.group(2))
                sys_info["load_15m"] = float(m.group(3))
        code, out, _ = self._run_cmd(["sysctl", "-n", "vm.swapusage"])
        if code == 0:
            m = re.search(r'used\s*=\s*([\d\.]+)M', out)
            if m:
                sys_info["swap_used_mb"] = float(m.group(1))
        return sys_info

    def collect_oslog_delta(self, interval_seconds: int) -> Dict[str, Any]:
        lookback = interval_seconds + 5
        predicate = 'subsystem == "com.aetherroute.desktop" OR processImagePath CONTAINS "AetherRoute" OR processImagePath CONTAINS "com.aetherroute"'
        cmd = [
            "/usr/bin/log", "show", "--last", f"{lookback}s",
            "--predicate", predicate, "--style", "json"
        ]
        code, out, _ = self._run_cmd(cmd, timeout=12.0)

        log_metrics = {
            "total_logs": 0,
            "error_count": 0,
            "fault_count": 0,
            "sample_errors": [],
            "keyword_alerts": [],
        }

        # Benign noise patterns that represent routine closed sockets or browser cancellations
        benign_patterns = [
            "flow is closed for writes",
            "Failed to write flow Data",
            "broken pipe",
            "connection reset by peer",
        ]

        keywords = ["panic", "assertion failed", "fatal", "crash", "leak", "corrupt", "sigsegv", "abort"]

        if code == 0 and out:
            try:
                events = json.loads(out)
                log_metrics["total_logs"] = len(events)

                for ev in events:
                    mtype = ev.get("messageType")
                    msg = ev.get("eventMessage", "")
                    subsystem = ev.get("subsystem", "")
                    category = ev.get("category", "")

                    # Check benign noise
                    if any(bp.lower() in msg.lower() for bp in benign_patterns):
                        continue

                    if mtype in ["Error", "Fault"]:
                        if mtype == "Error":
                            log_metrics["error_count"] += 1
                        else:
                            log_metrics["fault_count"] += 1

                        if len(log_metrics["sample_errors"]) < 8:
                            log_metrics["sample_errors"].append({
                                "time": ev.get("timestamp"),
                                "type": mtype,
                                "category": category,
                                "subsystem": subsystem,
                                "message": msg[:200],
                            })

                    msg_lower = msg.lower()
                    for kw in keywords:
                        if kw in msg_lower:
                            log_metrics["keyword_alerts"].append({
                                "keyword": kw,
                                "time": ev.get("timestamp"),
                                "message": msg[:200],
                            })
                            break
            except Exception:
                pass

        return log_metrics

    def check_new_crashes(self) -> List[str]:
        current = self._scan_crash_reports()
        new_ones = list(current - self.initial_crash_reports)
        self.initial_crash_reports = current
        return new_ones

    def evaluate_anomalies(
        self,
        processes: Dict[str, Any],
        extensions: Dict[str, Any],
        network: Dict[str, Any],
        probes: Dict[str, Any],
        logs: Dict[str, Any],
        new_crashes: List[str],
        tcp_states: Dict[str, int],
    ) -> List[Dict[str, Any]]:
        anomalies: List[Dict[str, Any]] = []

        # 1. Main app liveness & unexpected restarts
        app = processes.get("app", {})
        if not app.get("running"):
            anomalies.append({
                "severity": IncidentSeverity.P1_CRITICAL,
                "type": "PROCESS_DOWN_APP",
                "message": "AetherRoute main desktop application is NOT running!",
            })
        else:
            old_pid = self.last_pids.get("app")
            if old_pid and old_pid != app.get("pid"):
                anomalies.append({
                    "severity": IncidentSeverity.P1_CRITICAL,
                    "type": "PROCESS_RESTARTED_APP",
                    "message": f"AetherRoute main app unexpectedly restarted! PID changed from {old_pid} to {app.get('pid')}",
                })
            self.last_pids["app"] = app.get("pid")

        # 2. Extension liveness
        tunnel = processes.get("tunnel", {})
        proxy = processes.get("proxy", {})
        if not tunnel.get("running") and not proxy.get("running"):
            anomalies.append({
                "severity": IncidentSeverity.P2_WARNING,
                "type": "NO_ACTIVE_EXTENSION",
                "message": "Neither Packet Tunnel nor Transparent Proxy extension process is currently active.",
            })

        # 3. Network Mode & Connectivity
        if network.get("mode") == "tun" and network.get("status") != "up":
            anomalies.append({
                "severity": IncidentSeverity.P1_CRITICAL,
                "type": "TUNNEL_INTERFACE_DOWN",
                "message": "TUN mode is configured but utun interface bound to 198.18.0.1 is down!",
            })

        # Network latency and connectivity failure strikes
        if not probes.get("dns_ok") or not probes.get("http_ok"):
            self.probe_failure_strikes += 1
            if self.probe_failure_strikes >= 2:
                anomalies.append({
                    "severity": IncidentSeverity.P2_WARNING,
                    "type": "NETWORK_PROBE_FAILURE",
                    "message": f"Consecutive network probe failure ({self.probe_failure_strikes}x): DNS ok={probes.get('dns_ok')}, HTTP ok={probes.get('http_ok')}",
                })
        else:
            self.probe_failure_strikes = 0

        # Latency spike warning
        if probes.get("http_latency_ms") and probes.get("http_latency_ms") > 3000.0:
            anomalies.append({
                "severity": IncidentSeverity.P3_NOTICE,
                "type": "HTTP_LATENCY_SPIKE",
                "message": f"HTTP probe latency elevated: {probes.get('http_latency_ms')} ms",
            })

        # 4. Crash reports
        if new_crashes:
            for crash in new_crashes:
                anomalies.append({
                    "severity": IncidentSeverity.P1_CRITICAL,
                    "type": "CRASH_REPORT_GENERATED",
                    "message": f"New crash report found: {crash}",
                })

        # 5. OSLog faults & errors
        if logs.get("fault_count", 0) > 0:
            anomalies.append({
                "severity": IncidentSeverity.P1_CRITICAL,
                "type": "OSLOG_FAULT_DETECTED",
                "message": f"Detected {logs.get('fault_count')} OSLog Fault entries in current window",
            })
        elif logs.get("error_count", 0) > 5:
            anomalies.append({
                "severity": IncidentSeverity.P2_WARNING,
                "type": "OSLOG_ERROR_BURST",
                "message": f"Detected {logs.get('error_count')} filtered OSLog Error entries in current window",
            })

        # 6. Memory growth analysis (least squares slope)
        elapsed_hours = (time.time() - self.start_time) / 3600.0
        for key in ["app", "tunnel", "proxy"]:
            proc = processes.get(key, {})
            mb = proc.get("footprint_mb", 0) or proc.get("rss_mb", 0)
            if mb <= 0:
                continue
            hist = self.memory_history[key]
            hist.append((elapsed_hours, mb))
            if len(hist) > MEMORY_HISTORY_MAX_SAMPLES:
                hist.pop(0)

            span = hist[-1][0] - hist[0][0]
            if span >= MEMORY_MIN_SPAN_HOURS:
                slope = _least_squares_slope(hist)
                growth = hist[-1][1] - min(v for _, v in hist)
                if slope > MEMORY_SLOPE_THRESHOLD_MB_PER_H and growth > MEMORY_GROWTH_THRESHOLD_MB:
                    anomalies.append({
                        "severity": IncidentSeverity.P2_WARNING,
                        "type": f"MEMORY_CREEP_{key.upper()}",
                        "message": f"{key.upper()} memory rose {growth:.1f}MB to {hist[-1][1]:.1f}MB ({slope:.1f}MB/h sustained)",
                    })

        # 7. Sustained High CPU (> 30% for 3+ consecutive samples)
        for key in ["app", "tunnel", "proxy"]:
            cpu_val = processes.get(key, {}).get("cpu", 0.0)
            if cpu_val > 30.0:
                self.high_cpu_counters[key] += 1
                if self.high_cpu_counters[key] >= 3:
                    anomalies.append({
                        "severity": IncidentSeverity.P2_WARNING,
                        "type": f"SUSTAINED_HIGH_CPU_{key.upper()}",
                        "message": f"{key.upper()} CPU is high: {cpu_val:.1f}% for {self.high_cpu_counters[key]} consecutive cycles",
                    })
            else:
                self.high_cpu_counters[key] = 0

        # 8. Sockets CLOSE_WAIT accumulation
        close_wait = tcp_states.get("CLOSE_WAIT", 0)
        if close_wait > 20:
            anomalies.append({
                "severity": IncidentSeverity.P2_WARNING,
                "type": "TCP_CLOSE_WAIT_LEAK",
                "message": f"Excessive CLOSE_WAIT sockets detected: {close_wait}",
            })

        return anomalies

    def capture_diagnostic_snapshot(self, incident: Dict[str, Any], sample: Dict[str, Any]):
        t_str = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        itype = incident.get("type", "UNKNOWN")
        snap_dir = os.path.join(self.snapshots_dir, f"incident_{t_str}_{itype}")
        os.makedirs(snap_dir, exist_ok=True)

        # Write incident metadata
        with open(os.path.join(snap_dir, "incident.json"), "w", encoding="utf-8") as f:
            json.dump({"incident": incident, "sample": sample}, f, indent=2, ensure_ascii=False)

        # Dump ps
        _, ps_out, _ = self._run_cmd(["ps", "-aux"])
        with open(os.path.join(snap_dir, "ps.txt"), "w", encoding="utf-8") as f:
            f.write(ps_out)

        # Dump lsof if app is running
        app_pid = sample.get("processes", {}).get("app", {}).get("pid")
        if app_pid:
            _, lsof_out, _ = self._run_cmd(["lsof", "-p", str(app_pid)], timeout=5.0)
            with open(os.path.join(snap_dir, f"lsof_app_{app_pid}.txt"), "w", encoding="utf-8") as f:
                f.write(lsof_out)

        # Dump netstat
        _, net_out, _ = self._run_cmd(["netstat", "-an"], timeout=5.0)
        with open(os.path.join(snap_dir, "netstat.txt"), "w", encoding="utf-8") as f:
            f.write(net_out)

        self.log(f"ALERT: Forensic snapshot captured to {snap_dir}")

    def record_sample(self, interval_seconds: int) -> Dict[str, Any]:
        self.samples_collected += 1
        now = datetime.datetime.now()
        timestamp_iso = now.isoformat()
        elapsed_sec = round(time.time() - self.start_time, 1)

        processes = self.collect_processes()
        extensions = self.collect_system_extensions()
        network = self.collect_network(processes)
        probes = self.probe_connectivity()
        tcp_states = self.collect_tcp_states()
        system_stats = self.collect_system()
        logs = self.collect_oslog_delta(interval_seconds)
        new_crashes = self.check_new_crashes()

        anomalies = self.evaluate_anomalies(
            processes, extensions, network, probes, logs, new_crashes, tcp_states
        )

        sample = {
            "sample_index": self.samples_collected,
            "timestamp": timestamp_iso,
            "elapsed_seconds": elapsed_sec,
            "processes": processes,
            "extensions": extensions,
            "network": network,
            "probes": probes,
            "tcp_states": tcp_states,
            "system": system_stats,
            "logs": logs,
            "crashes": new_crashes,
            "anomalies": anomalies,
            "anomalies_count": len(anomalies),
        }

        # Process anomalies & incidents
        for a in anomalies:
            self.total_incidents += 1
            incident_entry = {
                "incident_id": self.total_incidents,
                "sample_index": self.samples_collected,
                "timestamp": timestamp_iso,
                "severity": a["severity"],
                "type": a["type"],
                "message": a["message"],
            }
            self.recent_incidents.append(incident_entry)
            if len(self.recent_incidents) > 50:
                self.recent_incidents.pop(0)

            # Write to incidents.jsonl
            with open(self.incidents_jsonl, "a", encoding="utf-8") as f:
                f.write(json.dumps(incident_entry, ensure_ascii=False) + "\n")

            self.log(f"⚠️ [{a['severity']}] {a['type']}: {a['message']}")
            if a["severity"] in [IncidentSeverity.P1_CRITICAL, IncidentSeverity.P2_WARNING]:
                self.capture_diagnostic_snapshot(a, sample)

        # Write to metrics.jsonl
        with open(self.metrics_jsonl, "a", encoding="utf-8") as f:
            f.write(json.dumps(sample, ensure_ascii=False) + "\n")

        # Write to metrics.csv
        app_p = processes["app"]
        tun_p = processes["tunnel"]
        prx_p = processes["proxy"]
        csv_row = [
            timestamp_iso, self.samples_collected, elapsed_sec, network.get("mode", "unknown"),
            app_p.get("running"), app_p.get("pid"), app_p.get("cpu"), app_p.get("rss_mb"), app_p.get("footprint_mb"), app_p.get("threads"), app_p.get("fds"),
            tun_p.get("running"), tun_p.get("pid"), tun_p.get("cpu"), tun_p.get("rss_mb"),
            prx_p.get("running"), prx_p.get("pid"), prx_p.get("cpu"), prx_p.get("rss_mb"),
            probes.get("dns_latency_ms"), probes.get("dns_ok"), probes.get("http_latency_ms"), probes.get("http_ok"), probes.get("http_status"),
            tcp_states.get("ESTABLISHED", 0), tcp_states.get("CLOSE_WAIT", 0), tcp_states.get("TIME_WAIT", 0),
            system_stats.get("load_1m"), system_stats.get("swap_used_mb"), logs.get("error_count"), logs.get("fault_count"), len(anomalies)
        ]
        with open(self.metrics_csv, "a", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(csv_row)

        self.last_timestamp = time.time()

        # Update summary and dashboard
        self._update_status_summary(sample)
        self._update_dashboard(sample)

        return sample

    def _update_status_summary(self, latest_sample: Dict[str, Any]):
        elapsed_hours = round((time.time() - self.start_time) / 3600.0, 2)
        pct = round((self.samples_collected / self.target_samples) * 100.0, 1)
        summary = {
            "status": "RUNNING" if self.samples_collected < self.target_samples else "COMPLETED",
            "start_time": datetime.datetime.fromtimestamp(self.start_time).isoformat(),
            "last_updated": latest_sample["timestamp"],
            "elapsed_hours": elapsed_hours,
            "samples_collected": self.samples_collected,
            "target_samples": self.target_samples,
            "progress_percent": pct,
            "total_incidents": self.total_incidents,
            "active_mode": latest_sample.get("network", {}).get("mode", "unknown"),
            "latest_cpu": {
                "app": latest_sample["processes"]["app"]["cpu"],
                "tunnel": latest_sample["processes"]["tunnel"]["cpu"],
                "proxy": latest_sample["processes"]["proxy"]["cpu"],
            },
            "latest_rss_mb": {
                "app": latest_sample["processes"]["app"]["rss_mb"],
                "tunnel": latest_sample["processes"]["tunnel"]["rss_mb"],
                "proxy": latest_sample["processes"]["proxy"]["rss_mb"],
            },
            "latest_footprint_mb": {
                "app": latest_sample["processes"]["app"]["footprint_mb"],
            },
            "probes": latest_sample["probes"],
            "recent_incidents": self.recent_incidents[-10:],
        }
        with open(self.summary_file, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2, ensure_ascii=False)

    def _update_dashboard(self, latest_sample: Dict[str, Any]):
        p = latest_sample["processes"]
        net = latest_sample["network"]
        prb = latest_sample["probes"]
        sys_s = latest_sample["system"]
        elapsed_h = round((time.time() - self.start_time) / 3600.0, 2)
        pct = round((self.samples_collected / self.target_samples) * 100.0, 1)

        health_icon = "🟢 HEALTHY" if latest_sample["anomalies_count"] == 0 else "🔴 INCIDENT DETECTED"
        if self.total_incidents > 0 and latest_sample["anomalies_count"] == 0:
            health_icon = "🟡 HEALTHY (History has incidents)"

        dns_str = f"{prb['dns_latency_ms']} ms" if prb.get("dns_latency_ms") else "FAIL"
        http_str = f"{prb['http_latency_ms']} ms (HTTP {prb['http_status']})" if prb.get("http_latency_ms") else "FAIL"

        incident_table = ""
        if self.recent_incidents:
            incident_table = "\n### Recent Incidents\n| # | Time | Severity | Type | Message |\n|---|---|---|---|---|\n"
            for inc in reversed(self.recent_incidents[-8:]):
                t_short = inc["timestamp"].split("T")[-1][:8]
                incident_table += f"| {inc['incident_id']} | {t_short} | `{inc['severity']}` | `{inc['type']}` | {inc['message']} |\n"
        else:
            incident_table = "\n*No incidents detected yet. All health gates nominal.*\n"

        content = f"""# AetherRoute 3-Hour Continuous Telemetry Dashboard

**Health Status:** {health_icon}  
**Progress:** {self.samples_collected} / {self.target_samples} samples ({pct}%) | **Elapsed:** {elapsed_h} / {self.duration_hours} hours  
**Last Updated:** `{latest_sample['timestamp']}` | **Active Mode:** `{net.get('mode', 'unknown')}`

---

### Process Resource Footprint
| Process | Status | PID | CPU (%) | RSS (MB) | PhysFootprint | Mach Threads | Open FDs |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Main App** | {"🟢 Up" if p["app"]["running"] else "🔴 Down"} | `{p["app"]["pid"]}` | `{p["app"]["cpu"]}%` | `{p["app"]["rss_mb"]} MB` | `{p["app"]["footprint_mb"]} MB` | `{p["app"]["threads"]}` | `{p["app"]["fds"]}` |
| **Packet Tunnel** | {"🟢 Up" if p["tunnel"]["running"] else "⚪️ Idle"} | `{p["tunnel"]["pid"]}` | `{p["tunnel"]["cpu"]}%` | `{p["tunnel"]["rss_mb"]} MB` | - | `{p["tunnel"]["threads"]}` | `{p["tunnel"]["fds"]}` |
| **Transparent Proxy** | {"🟢 Up" if p["proxy"]["running"] else "⚪️ Idle"} | `{p["proxy"]["pid"]}` | `{p["proxy"]["cpu"]}%` | `{p["proxy"]["rss_mb"]} MB` | - | `{p["proxy"]["threads"]}` | `{p["proxy"]["fds"]}` |

---

### Network Data Plane & Connectivity
- **Active Mode:** `{net.get('mode', 'unknown')}` | **Status:** `{net.get('status', 'unknown')}`
- **DNS Latency (`apple.com`):** `{dns_str}`
- **HTTP Latency (`generate_204`):** `{http_str}`
- **Gateway Sockets:** `{json.dumps(latest_sample['tcp_states'])}`
- **System Load Average:** `{sys_s['load_1m']}, {sys_s['load_5m']}, {sys_s['load_15m']}` | **Swap Used:** `{sys_s['swap_used_mb']} MB`

---

### Total Incidents: {self.total_incidents}
{incident_table}

---
*Telemetry log stored at `outputs/monitor_3h/monitor.log`*
"""
        with open(self.dashboard_file, "w", encoding="utf-8") as f:
            f.write(content)


def run_loop(collector: TelemetryCollector3H, interval_seconds: int, duration_hours: float):
    target_samples = collector.target_samples
    running = True

    def sig_handler(signum, frame):
        nonlocal running
        collector.log(f"Received signal {signum}, initiating graceful shutdown...")
        running = False

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    collector.log(f"Starting 3-Hour monitor loop: interval={interval_seconds}s, duration={duration_hours}h, target_samples={target_samples}")

    while running and collector.samples_collected < target_samples:
        t_start = time.time()
        try:
            sample = collector.record_sample(interval_seconds)
            p = sample["processes"]
            tun_or_prx_rss = p["proxy"]["rss_mb"] if p["proxy"]["running"] else p["tunnel"]["rss_mb"]
            collector.log(
                f"Sample #{sample['sample_index']}/{target_samples} | "
                f"Mode: {sample['network']['mode']} | "
                f"App RSS: {p['app']['rss_mb']}MB (CPU: {p['app']['cpu']}%) | "
                f"Engine RSS: {tun_or_prx_rss}MB | "
                f"DNS: {sample['probes']['dns_latency_ms']}ms | "
                f"HTTP: {sample['probes']['http_latency_ms']}ms | "
                f"Anomalies: {sample['anomalies_count']}"
            )
        except Exception as e:
            collector.log(f"ERROR during sample collection: {e}")

        spent = time.time() - t_start
        to_sleep = max(1.0, interval_seconds - spent)
        end_sleep = time.time() + to_sleep
        while running and time.time() < end_sleep:
            time.sleep(min(1.0, end_sleep - time.time()))

    if os.path.isfile(collector.pid_file):
        try:
            os.remove(collector.pid_file)
        except Exception:
            pass

    collector.log(f"✅ Monitor finished: {collector.samples_collected} samples collected. All results saved to {collector.output_dir}.")


def main():
    parser = argparse.ArgumentParser(description="AetherRoute 3-Hour Continuous Telemetry Monitor")
    parser.add_argument("--interval", type=int, default=60, help="Sampling interval in seconds (default: 60)")
    parser.add_argument("--duration-hours", type=float, default=3.0, help="Duration in hours (default: 3.0)")
    parser.add_argument("--output-dir", type=str, default=DEFAULT_OUTPUT_DIR, help="Output directory path")
    parser.add_argument("--once", action="store_true", help="Run a single sample and exit (dry-run)")

    args = parser.parse_args()

    collector = TelemetryCollector3H(args.output_dir, interval=args.interval, duration_hours=args.duration_hours)

    if args.once:
        print(f"Running single baseline dry-run verification (mode awareness, probes, logs)...")
        sample = collector.record_sample(args.interval)
        print(json.dumps(sample, indent=2, ensure_ascii=False))
        print(f"\nDry run completed! Dashboard: {collector.dashboard_file}")
        sys.exit(0)

    run_loop(collector, args.interval, args.duration_hours)


if __name__ == "__main__":
    main()
