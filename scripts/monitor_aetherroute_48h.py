#!/usr/bin/env python3
"""
AetherRoute 48-Hour Continuous Telemetry & Incident Monitor
===========================================================
Monitors the AetherRoute host desktop application, packet tunnel extension,
and transparent proxy extension every 3 minutes for 48+ hours (960+ samples).

Tracks:
1. Process Lifecycle & Resource Usage (PID, CPU, RSS, VSZ, Mach threads, FDs)
2. System Extension Integrity (systemextensionsctl status)
3. Network Data Plane (utun interface, I/O bytes, packet deltas, DNS & HTTP latency)
4. OSLog & Diagnostic Error Mining (subsystem filters, keyword scanning)
5. CrashReporter Directory Monitoring (~/Library/Logs/DiagnosticReports/)
6. Anomaly Detection & Diagnostic Snapshots (memory leaks, stalls, crashes)
7. Live Markdown Dashboard & Structured JSONL logs
"""

import argparse
import datetime
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
import urllib.error

# Ensure outputs directory can be created
DEFAULT_OUTPUT_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "outputs", "monitor_48h")
)

APP_BINARY_NAME = "AetherRoute"
TUNNEL_EXT_ID = "com.aetherroute.desktop.tunnel"
PROXY_EXT_ID = "com.aetherroute.desktop.transparent-proxy"
TUNNEL_GATEWAY_IP = "198.18.0.1"
PROBE_DNS_HOST = "apple.com"
PROBE_HTTP_URL = "https://cp.cloudflare.com/generate_204"


class IncidentSeverity:
    P1_CRITICAL = "P1_CRITICAL"
    P2_WARNING = "P2_WARNING"
    P3_NOTICE = "P3_NOTICE"


class TelemetryCollector:
    def __init__(self, output_dir: str):
        self.output_dir = output_dir
        self.snapshots_dir = os.path.join(output_dir, "diagnostic_snapshots")
        os.makedirs(self.output_dir, exist_ok=True)
        os.makedirs(self.snapshots_dir, exist_ok=True)

        self.metrics_file = os.path.join(output_dir, "metrics.jsonl")
        self.incidents_file = os.path.join(output_dir, "incidents.jsonl")
        self.summary_file = os.path.join(output_dir, "status_summary.json")
        self.dashboard_file = os.path.join(output_dir, "dashboard.md")
        self.log_file = os.path.join(output_dir, "monitor.log")
        self.pid_file = os.path.join(output_dir, "monitor.pid")

        # Historical trackers
        self.last_netstat = None
        self.last_timestamp = None
        self.last_pids = {}
        self.rss_history = {"app": [], "tunnel": [], "proxy": []}
        self.start_time = time.time()
        self.samples_collected = 0
        self.total_incidents = 0
        self.recent_incidents = []

        # Known crash reports at start
        self.initial_crash_reports = self._scan_crash_reports()

    def log(self, message: str):
        now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{now_str}] {message}"
        print(line, flush=True)
        try:
            with open(self.log_file, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except Exception:
            pass

    def _run_cmd(self, args, timeout=10):
        try:
            p = subprocess.run(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=timeout,
            )
            return p.returncode, p.stdout.strip(), p.stderr.strip()
        except subprocess.TimeoutExpired:
            return -1, "", "Command timed out"
        except Exception as e:
            return -1, "", str(e)

    def _scan_crash_reports(self) -> set:
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

    def collect_processes(self) -> dict:
        """Collects CPU, memory, thread counts, and FDs for all AetherRoute processes."""
        processes = {
            "app": {"running": False, "pid": None, "cpu": 0.0, "rss_mb": 0.0, "vsz_mb": 0.0, "threads": 0, "fds": 0},
            "tunnel": {"running": False, "pid": None, "cpu": 0.0, "rss_mb": 0.0, "vsz_mb": 0.0, "threads": 0, "fds": 0},
            "proxy": {"running": False, "pid": None, "cpu": 0.0, "rss_mb": 0.0, "vsz_mb": 0.0, "threads": 0, "fds": 0},
        }

        # Run ps to find all candidate processes
        code, out, _ = self._run_cmd(["ps", "-eo", "pid,ppid,%cpu,%mem,rss,vsz,command"])
        if code == 0:
            for line in out.splitlines()[1:]:
                parts = line.strip().split(None, 6)
                if len(parts) < 7:
                    continue
                pid_str, ppid_str, cpu_str, mem_str, rss_str, vsz_str, cmd = parts
                cmd_lower = cmd.lower()

                target_key = None
                if "/Applications/AetherRoute.app" in cmd or (
                    "aetherroute" in cmd_lower and "systemextensions" not in cmd_lower and "monitor" not in cmd_lower and "grep" not in cmd_lower and "xcode" not in cmd_lower
                ):
                    target_key = "app"
                elif TUNNEL_EXT_ID in cmd:
                    target_key = "tunnel"
                elif PROXY_EXT_ID in cmd:
                    target_key = "proxy"

                if target_key and not processes[target_key]["running"]:
                    try:
                        pid = int(pid_str)
                        cpu = float(cpu_str)
                        rss_mb = round(int(rss_str) / 1024.0, 2)
                        vsz_mb = round(int(vsz_str) / 1024.0, 2)

                        # Thread count
                        t_code, t_out, _ = self._run_cmd(["ps", "-M", "-p", str(pid)])
                        threads = max(0, len(t_out.splitlines()) - 1) if t_code == 0 else 0

                        # Open FDs (for user app)
                        fds = 0
                        if target_key == "app":
                            f_code, f_out, _ = self._run_cmd(["lsof", "-p", str(pid)])
                            fds = max(0, len(f_out.splitlines()) - 1) if f_code == 0 else 0

                        processes[target_key] = {
                            "running": True,
                            "pid": pid,
                            "ppid": int(ppid_str),
                            "cpu": cpu,
                            "rss_mb": rss_mb,
                            "vsz_mb": vsz_mb,
                            "threads": threads,
                            "fds": fds,
                            "command": cmd[:120],
                        }
                    except Exception:
                        pass

        return processes

    def collect_system_extensions(self) -> dict:
        """Collects registration and activation state of system extensions."""
        code, out, _ = self._run_cmd(["/usr/bin/systemextensionsctl", "list"])
        status = {
            "tunnel": {"found": False, "status": "unknown", "version": ""},
            "proxy": {"found": False, "status": "unknown", "version": ""},
        }
        if code == 0:
            for line in out.splitlines():
                if TUNNEL_EXT_ID in line:
                    status["tunnel"]["found"] = True
                    m = re.search(r"\((\d+\.\d+\.\d+/[^\)]+)\)", line)
                    ver = m.group(1) if m else ""
                    if "[activated enabled]" in line:
                        status["tunnel"]["status"] = "activated enabled"
                        status["tunnel"]["version"] = ver
                    elif status["tunnel"]["status"] != "activated enabled":
                        status["tunnel"]["status"] = line.strip()
                        status["tunnel"]["version"] = ver
                elif PROXY_EXT_ID in line:
                    status["proxy"]["found"] = True
                    m = re.search(r"\((\d+\.\d+\.\d+/[^\)]+)\)", line)
                    ver = m.group(1) if m else ""
                    if "[activated enabled]" in line:
                        status["proxy"]["status"] = "activated enabled"
                        status["proxy"]["version"] = ver
                    elif status["proxy"]["status"] != "activated enabled":
                        status["proxy"]["status"] = line.strip()
                        status["proxy"]["version"] = ver
        return status

    def collect_network(self) -> dict:
        """Finds utun interface, collects I/O counters and deltas."""
        net_info = {
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

        # Find interface bound to 198.18.0.1
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
                    break

        if net_info["interface"]:
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
                                "ibytes": ibytes,
                                "obytes": obytes,
                                "ipkts": ipkts,
                                "opkts": opkts,
                            }
                        except Exception:
                            pass

        return net_info

    def probe_connectivity(self) -> dict:
        """Probes DNS resolution and HTTP endpoint through tunnel."""
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
            res = socket.getaddrinfo(PROBE_DNS_HOST, 443)
            dns_time = (time.time() - t0) * 1000
            probes["dns_latency_ms"] = round(dns_time, 2)
            probes["dns_resolved_ip"] = res[0][4][0] if res else None
            probes["dns_ok"] = True
        except Exception as e:
            probes["dns_error"] = str(e)

        # HTTP probe
        try:
            t0 = time.time()
            req = urllib.request.Request(
                PROBE_HTTP_URL,
                headers={"User-Agent": "AetherRoute-48h-Monitor/1.0"},
            )
            with urllib.request.urlopen(req, timeout=8) as resp:
                probes["http_status"] = resp.getcode()
                probes["http_ok"] = resp.getcode() in [200, 204]
            probes["http_latency_ms"] = round((time.time() - t0) * 1000, 2)
        except urllib.error.HTTPError as e:
            probes["http_status"] = e.code
            probes["http_ok"] = e.code in [200, 204]
            probes["http_latency_ms"] = round((time.time() - t0) * 1000, 2)
        except Exception as e:
            probes["http_error"] = str(e)

        return probes

    def collect_oslog_delta(self, interval_seconds: int) -> dict:
        """Queries OSLog for the past interval, extracting error counts and keyword triggers."""
        lookback = interval_seconds + 15
        predicate = 'subsystem == "com.aetherroute.desktop" OR processImagePath CONTAINS "AetherRoute" OR processImagePath CONTAINS "com.aetherroute"'
        cmd = [
            "/usr/bin/log",
            "show",
            "--last",
            f"{lookback}s",
            "--predicate",
            predicate,
            "--style",
            "json",
        ]
        code, out, _ = self._run_cmd(cmd, timeout=15)
        
        log_metrics = {
            "total_logs": 0,
            "error_count": 0,
            "fault_count": 0,
            "keyword_alerts": [],
            "sample_errors": [],
        }

        if code == 0 and out:
            try:
                events = json.loads(out)
                log_metrics["total_logs"] = len(events)
                keywords = ["panic", "assertion failed", "fatal", "crash", "leak", "corrupt", "sigsegv", "abort"]

                for ev in events:
                    mtype = ev.get("messageType")
                    msg = ev.get("eventMessage", "")
                    category = ev.get("category", "")
                    subsystem = ev.get("subsystem", "")

                    if mtype in ["Error", "Fault"]:
                        if mtype == "Error":
                            log_metrics["error_count"] += 1
                        else:
                            log_metrics["fault_count"] += 1

                        if len(log_metrics["sample_errors"]) < 10:
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

    def check_new_crashes(self) -> list:
        current_reports = self._scan_crash_reports()
        new_crashes = list(current_reports - self.initial_crash_reports)
        self.initial_crash_reports = current_reports
        return new_crashes

    def evaluate_anomalies(
        self,
        processes: dict,
        extensions: dict,
        network: dict,
        probes: dict,
        logs: dict,
        new_crashes: list,
    ) -> list:
        """Evaluates metrics against incident thresholds."""
        anomalies = []

        # 1. Process liveness
        for key, name in [("app", "Main App"), ("tunnel", "Packet Tunnel SE"), ("proxy", "Transparent Proxy SE")]:
            p = processes.get(key, {})
            if not p.get("running"):
                anomalies.append({
                    "severity": IncidentSeverity.P1_CRITICAL,
                    "type": f"PROCESS_DOWN_{key.upper()}",
                    "message": f"{name} is not running!",
                })
            else:
                # PID change detection
                old_pid = self.last_pids.get(key)
                if old_pid and old_pid != p.get("pid"):
                    anomalies.append({
                        "severity": IncidentSeverity.P1_CRITICAL,
                        "type": f"PROCESS_RESTARTED_{key.upper()}",
                        "message": f"{name} PID changed from {old_pid} to {p.get('pid')} (unexpected restart)!",
                    })
                self.last_pids[key] = p.get("pid")

        # 2. System Extension state
        if not extensions.get("tunnel", {}).get("found") or extensions.get("tunnel", {}).get("status") != "activated enabled":
            anomalies.append({
                "severity": IncidentSeverity.P1_CRITICAL,
                "type": "EXTENSION_INACTIVE_TUNNEL",
                "message": f"Tunnel extension state invalid: {extensions.get('tunnel', {}).get('status')}",
            })

        # 3. Network tunnel status & probes
        if not network.get("interface") or network.get("status") != "up":
            anomalies.append({
                "severity": IncidentSeverity.P1_CRITICAL,
                "type": "TUNNEL_INTERFACE_DOWN",
                "message": "Tunnel interface utun bound to 198.18.0.1 not found or down",
            })
        elif not probes.get("dns_ok"):
            anomalies.append({
                "severity": IncidentSeverity.P2_WARNING,
                "type": "DNS_RESOLUTION_FAILURE",
                "message": f"DNS resolution to {PROBE_DNS_HOST} failed: {probes.get('dns_error')}",
            })
        elif not probes.get("http_ok"):
            anomalies.append({
                "severity": IncidentSeverity.P2_WARNING,
                "type": "HTTP_PROBE_FAILURE",
                "message": f"HTTP probe to {PROBE_HTTP_URL} failed: status={probes.get('http_status')}, err={probes.get('http_error')}",
            })

        # 4. Crash reports
        if new_crashes:
            for crash in new_crashes:
                anomalies.append({
                    "severity": IncidentSeverity.P1_CRITICAL,
                    "type": "CRASH_REPORT_GENERATED",
                    "message": f"New crash report found: {crash}",
                })

        # 5. OSLog errors/faults
        if logs.get("fault_count", 0) > 0:
            anomalies.append({
                "severity": IncidentSeverity.P1_CRITICAL,
                "type": "OSLOG_FAULT_DETECTED",
                "message": f"Detected {logs.get('fault_count')} OSLog Fault entries in current window",
            })
        elif logs.get("error_count", 0) > 2:
            anomalies.append({
                "severity": IncidentSeverity.P2_WARNING,
                "type": "OSLOG_ERROR_BURST",
                "message": f"Detected {logs.get('error_count')} OSLog Error entries in current window",
            })

        # 6. Memory leak tracking (streak check: 5 consecutive cycles monotonic growth > 50MB)
        for key in ["app", "tunnel", "proxy"]:
            rss = processes.get(key, {}).get("rss_mb", 0)
            if rss > 0:
                hist = self.rss_history[key]
                hist.append(rss)
                if len(hist) > 5:
                    hist.pop(0)
                if len(hist) == 5:
                    is_strictly_increasing = all(hist[i] < hist[i+1] for i in range(4))
                    growth = hist[-1] - hist[0]
                    if is_strictly_increasing and growth > 50.0:
                        anomalies.append({
                            "severity": IncidentSeverity.P2_WARNING,
                            "type": f"POSSIBLE_MEMORY_LEAK_{key.upper()}",
                            "message": f"{key.upper()} RSS memory grew monotonically from {hist[0]}MB to {hist[-1]}MB (+{growth:.1f}MB over 15m)",
                        })

        return anomalies

    def capture_snapshot(self, incident: dict, raw_state: dict):
        """Captures full system diagnostic snapshot for an anomaly."""
        ts_str = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        safe_type = re.sub(r"[^a-zA-Z0-9_]", "_", incident.get("type", "ANOMALY"))
        dir_name = f"incident_{ts_str}_{safe_type}"
        snap_path = os.path.join(self.snapshots_dir, dir_name)
        os.makedirs(snap_path, exist_ok=True)

        with open(os.path.join(snap_path, "incident.json"), "w", encoding="utf-8") as f:
            json.dump({
                "incident": incident,
                "timestamp": datetime.datetime.now().isoformat(),
                "state_summary": raw_state,
            }, f, indent=2)

        _, ps_out, _ = self._run_cmd(["ps", "aux"])
        with open(os.path.join(snap_path, "process_snapshot.txt"), "w", encoding="utf-8") as f:
            f.write(ps_out)

        _, route_out, _ = self._run_cmd(["netstat", "-rn"])
        with open(os.path.join(snap_path, "routing_table.txt"), "w", encoding="utf-8") as f:
            f.write(route_out)

        _, log_out, _ = self._run_cmd([
            "/usr/bin/log", "show", "--last", "5m",
            "--predicate", 'subsystem == "com.aetherroute.desktop" OR processImagePath CONTAINS "AetherRoute"',
            "--style", "json"
        ], timeout=20)
        with open(os.path.join(snap_path, "oslog_recent.json"), "w", encoding="utf-8") as f:
            f.write(log_out)

        incident["snapshot_dir"] = snap_path
        self.log(f"ALERT: Diagnostic snapshot recorded to {snap_path}")

    def record_sample(self, interval_seconds: int) -> dict:
        """Collects all dimensions, updates outputs, detects anomalies."""
        ts = datetime.datetime.now().isoformat()
        self.samples_collected += 1

        processes = self.collect_processes()
        extensions = self.collect_system_extensions()
        network = self.collect_network()
        probes = self.probe_connectivity()
        logs = self.collect_oslog_delta(interval_seconds)
        new_crashes = self.check_new_crashes()

        sample = {
            "sample_index": self.samples_collected,
            "timestamp": ts,
            "uptime_seconds": round(time.time() - self.start_time, 1),
            "processes": processes,
            "extensions": extensions,
            "network": network,
            "probes": probes,
            "logs": {
                "total": logs["total_logs"],
                "errors": logs["error_count"],
                "faults": logs["fault_count"],
                "sample_errors": logs["sample_errors"],
            },
            "crashes": new_crashes,
        }

        anomalies = self.evaluate_anomalies(
            processes, extensions, network, probes, logs, new_crashes
        )

        sample["anomalies_count"] = len(anomalies)

        for anomaly in anomalies:
            self.total_incidents += 1
            anomaly["incident_id"] = f"INC-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}-{self.total_incidents}"
            anomaly["timestamp"] = ts
            anomaly["sample_index"] = self.samples_collected
            
            self.capture_snapshot(anomaly, sample)

            with open(self.incidents_file, "a", encoding="utf-8") as f:
                f.write(json.dumps(anomaly, ensure_ascii=False) + "\n")

            self.recent_incidents.insert(0, anomaly)
            if len(self.recent_incidents) > 10:
                self.recent_incidents.pop()

            self.log(f"[{anomaly['severity']}] {anomaly['type']}: {anomaly['message']}")

        with open(self.metrics_file, "a", encoding="utf-8") as f:
            f.write(json.dumps(sample, ensure_ascii=False) + "\n")

        self.last_timestamp = time.time()

        self.update_summary(sample)
        self.update_dashboard(sample)

        return sample

    def update_summary(self, latest_sample: dict):
        elapsed_sec = round(time.time() - self.start_time, 1)
        summary = {
            "status": "RUNNING",
            "samples_collected": self.samples_collected,
            "target_samples_48h": 960,
            "start_time": datetime.datetime.fromtimestamp(self.start_time).isoformat(),
            "last_updated": latest_sample["timestamp"],
            "elapsed_hours": round(elapsed_sec / 3600.0, 2),
            "total_incidents": self.total_incidents,
            "active_pids": {
                "app": latest_sample["processes"]["app"]["pid"],
                "tunnel": latest_sample["processes"]["tunnel"]["pid"],
                "proxy": latest_sample["processes"]["proxy"]["pid"],
            },
            "latest_metrics": {
                "app_rss_mb": latest_sample["processes"]["app"]["rss_mb"],
                "tunnel_rss_mb": latest_sample["processes"]["tunnel"]["rss_mb"],
                "dns_latency_ms": latest_sample["probes"]["dns_latency_ms"],
                "http_latency_ms": latest_sample["probes"]["http_latency_ms"],
                "tunnel_ibytes": latest_sample["network"]["ibytes"],
                "tunnel_obytes": latest_sample["network"]["obytes"],
            },
            "recent_incidents": self.recent_incidents[:5],
        }

        temp_file = self.summary_file + ".tmp"
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2, ensure_ascii=False)
        shutil.move(temp_file, self.summary_file)

    def update_dashboard(self, sample: dict):
        elapsed_sec = time.time() - self.start_time
        elapsed_str = str(datetime.timedelta(seconds=int(elapsed_sec)))
        pct = min(100.0, round((self.samples_collected / 960.0) * 100.0, 1))

        p_app = sample["processes"]["app"]
        p_tun = sample["processes"]["tunnel"]
        p_prx = sample["processes"]["proxy"]
        net = sample["network"]
        prb = sample["probes"]
        ext = sample["extensions"]

        def p_status(p):
            return "🟢 RUNNING" if p.get("running") else "🔴 STOPPED"

        def fmt_bytes(b):
            if b < 1024:
                return f"{b} B"
            elif b < 1024 * 1024:
                return f"{b/1024:.1f} KB"
            elif b < 1024 * 1024 * 1024:
                return f"{b/(1024*1024):.2f} MB"
            return f"{b/(1024*1024*1024):.2f} GB"

        incidents_table = ""
        if not self.recent_incidents:
            incidents_table = "_No anomalies recorded yet. All systems nominal._\n"
        else:
            incidents_table = "| Time | Severity | Type | Message |\n|---|---|---|---|\n"
            for inc in self.recent_incidents[:8]:
                sev_icon = "🔴" if inc["severity"] == IncidentSeverity.P1_CRITICAL else "🟡"
                t_short = inc["timestamp"].split("T")[-1][:8]
                incidents_table += f"| `{t_short}` | {sev_icon} {inc['severity']} | `{inc['type']}` | {inc['message']} |\n"

        md = f"""# AetherRoute 48-Hour Telemetry Dashboard

> **Status**: 🟢 **ACTIVE MONITORING** &nbsp;|&nbsp; **Cycles**: `{self.samples_collected} / 960` ({pct}%) &nbsp;|&nbsp; **Elapsed**: `{elapsed_str}`  
> **Last Sample**: `{sample['timestamp']}` &nbsp;|&nbsp; **Total Incidents**: `{self.total_incidents}`

---

## 1. Process & Extension Health

| Component | Status | PID | CPU % | RSS Memory | Mach Threads | Open FDs | SystemExtension State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Main App** (`AetherRoute`) | {p_status(p_app)} | `{p_app.get('pid') or '-'}` | `{p_app.get('cpu', 0.0)}%` | `{p_app.get('rss_mb', 0.0)} MB` | `{p_app.get('threads', 0)}` | `{p_app.get('fds', 0)}` | N/A (Host App) |
| **Packet Tunnel** (`.tunnel`) | {p_status(p_tun)} | `{p_tun.get('pid') or '-'}` | `{p_tun.get('cpu', 0.0)}%` | `{p_tun.get('rss_mb', 0.0)} MB` | `{p_tun.get('threads', 0)}` | `-` | `{ext.get('tunnel', {}).get('status', '-')}` |
| **Transparent Proxy** (`.transparent-proxy`) | {p_status(p_prx)} | `{p_prx.get('pid') or '-'}` | `{p_prx.get('cpu', 0.0)}%` | `{p_prx.get('rss_mb', 0.0)} MB` | `{p_prx.get('threads', 0)}` | `-` | `{ext.get('proxy', {}).get('status', '-')}` |

---

## 2. Network Data Plane & Liveness Probes

| Dimension | Value | Details |
| :--- | :--- | :--- |
| **Active Tunnel Interface** | `{net.get('interface') or 'None'}` | IP: `{net.get('ip') or 'None'}` (Status: `{net.get('status')}`) |
| **Cumulative Throughput** | In: `{fmt_bytes(net.get('ibytes', 0))}` &nbsp;\|&nbsp; Out: `{fmt_bytes(net.get('obytes', 0))}` | Total: `{fmt_bytes(net.get('ibytes', 0) + net.get('obytes', 0))}` |
| **Delta Rate (Last 3m)** | In: `{fmt_bytes(net.get('rate_ibytes_sec', 0))}/s` &nbsp;\|&nbsp; Out: `{fmt_bytes(net.get('rate_obytes_sec', 0))}/s` | ΔIn: `{fmt_bytes(net.get('delta_ibytes', 0))}` / ΔOut: `{fmt_bytes(net.get('delta_obytes', 0))}` |
| **DNS Probe** (`apple.com`) | `{'🟢 OK' if prb.get('dns_ok') else '🔴 FAIL'}` &nbsp;(`{prb.get('dns_latency_ms')} ms`) | FakeIP: `{prb.get('dns_resolved_ip') or prb.get('dns_error')}` |
| **HTTP Egress Probe** (`cloudflare.com/204`) | `{'🟢 OK' if prb.get('http_ok') else '🔴 FAIL'}` &nbsp;(`{prb.get('http_latency_ms')} ms`) | HTTP Status: `{prb.get('http_status') or prb.get('http_error')}` |

---

## 3. Telemetry & Log Activity (Past 3 Minutes)

- **OSLog Entries Analyzed**: `{sample['logs']['total']}`
- **OSLog Error Count**: `{sample['logs']['errors']}`
- **OSLog Fault Count**: `{sample['logs']['faults']}`
- **New Crash Reports Detected**: `{len(sample['crashes'])}`

---

## 4. Incidents & Anomaly Log

{incidents_table}

---
_Data automatically polled every 180s by `scripts/monitor_aetherroute_48h.py`. Next sample in ~3 minutes._
"""
        temp_file = self.dashboard_file + ".tmp"
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(md)
        shutil.move(temp_file, self.dashboard_file)


def run_loop(collector: TelemetryCollector, interval_seconds: int, duration_hours: float):
    target_samples = int((duration_hours * 3600) / interval_seconds)
    collector.log(f"Starting AetherRoute continuous monitor: interval={interval_seconds}s, duration={duration_hours}h ({target_samples} cycles)")

    with open(collector.pid_file, "w", encoding="utf-8") as f:
        f.write(str(os.getpid()))

    running = True

    def sig_handler(signum, frame):
        nonlocal running
        collector.log(f"Caught signal {signum}, initiating graceful shutdown...")
        running = False

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    while running and collector.samples_collected < target_samples:
        t_cycle_start = time.time()
        try:
            sample = collector.record_sample(interval_seconds)
            collector.log(
                f"Sample #{sample['sample_index']}/{target_samples} | "
                f"App RSS: {sample['processes']['app']['rss_mb']}MB | "
                f"Tun RSS: {sample['processes']['tunnel']['rss_mb']}MB | "
                f"DNS: {sample['probes']['dns_latency_ms']}ms | "
                f"HTTP: {sample['probes']['http_latency_ms']}ms | "
                f"Anomalies: {sample['anomalies_count']}"
            )
        except Exception as e:
            collector.log(f"ERROR in record_sample: {e}")

        spent = time.time() - t_cycle_start
        to_sleep = max(1.0, interval_seconds - spent)
        
        end_sleep = time.time() + to_sleep
        while running and time.time() < end_sleep:
            time.sleep(min(1.0, end_sleep - time.time()))

    if os.path.isfile(collector.pid_file):
        try:
            os.remove(collector.pid_file)
        except Exception:
            pass

    collector.log(f"Monitor completed: {collector.samples_collected} samples collected. All metrics stored in {collector.output_dir}.")


def main():
    parser = argparse.ArgumentParser(description="AetherRoute 48-Hour Continuous Telemetry Monitor")
    parser.add_argument("--interval", type=int, default=180, help="Sampling interval in seconds (default: 180)")
    parser.add_argument("--duration-hours", type=float, default=48.0, help="Duration in hours (default: 48)")
    parser.add_argument("--output-dir", type=str, default=DEFAULT_OUTPUT_DIR, help="Output directory path")
    parser.add_argument("--once", action="store_true", help="Run a single sample and exit (for dry-run verification)")

    args = parser.parse_args()

    collector = TelemetryCollector(args.output_dir)

    if args.once:
        print("Running single baseline dry-run verification...")
        sample = collector.record_sample(args.interval)
        print(json.dumps(sample, indent=2, ensure_ascii=False))
        print(f"\nDry-run completed successfully! Outputs written to {args.output_dir}")
        sys.exit(0)

    run_loop(collector, args.interval, args.duration_hours)


if __name__ == "__main__":
    main()
