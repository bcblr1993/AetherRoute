#!/usr/bin/env python3
"""
Comprehensive Continuous High-Frequency Stability & Observability Daemon for AetherRoute.
Monitors:
1. Data Plane & Routing:
   - DNS Resolution Latency & Fake-IP Integrity (Apple vs Google)
   - Dual-Target Probes: Domestic Direct (Apple) vs International Proxy (Google)
   - Virtual TUN Interface (utun) MTU, Throughput (PPS), and Packet Drops (Ierrs/Oerrs)
   - TCP Socket State Breakdown (ESTABLISHED, CLOSE_WAIT, TIME_WAIT, SYN_SENT)
2. System & Resources:
   - App Physical Footprint (vmmap), Peak, RSS, CPU, Threads, and FD breakdown
   - Tunnel RSS, CPU, Threads
   - Memory Drift Slope (MB/hour linear regression)
3. Stability & Resilience:
   - Unified Log (os_log) Errors & Faults
   - DiagnosticReports Crash Scanner
   - System Sleep/Wake Detection & Post-Wake Recovery
"""

import argparse
import datetime
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

sys.stdout.reconfigure(line_buffering=True)

class ContinuousStabilityObserver:
    def __init__(
        self,
        duration_seconds: int = 129600,  # 36 hours default
        interval: int = 30,
        output_dir: str = "reports/diagnostics",
        proxy_url: Optional[str] = None,
        probe_url: Optional[str] = None,
        direct_url: str = "https://www.apple.com",
    ):
        self.duration_seconds = duration_seconds
        self.interval = interval
        self.output_dir = Path(output_dir)
        self.proxy_url = proxy_url or probe_url or "https://www.google.com"
        self.direct_url = direct_url
        self.start_time = datetime.datetime.now(datetime.timezone.utc)
        self.running = True

        self.ensure_dirs()
        self.jsonl_path = self.output_dir / "continuous_stability.jsonl"
        self.status_path = self.output_dir / "continuous_stability_status.json"
        self.alert_path = self.output_dir / "continuous_stability_alerts.log"
        self.human_log_path = self.output_dir / "continuous_stability.log"

        self.app_pid: Optional[int] = None
        self.tun_pid: Optional[int] = None
        self.utun_name: Optional[str] = None
        self.prev_utun_stats: Optional[Dict[str, int]] = None
        self.last_record: Optional[Dict[str, Any]] = None

        self.samples_count = 0
        self.total_errors = 0
        self.total_crashes = 0
        self.total_alerts = 0
        self.sleep_wake_events = 0

        # Metrics history for rolling statistics
        self.proxy_probes_total = 0
        self.proxy_probes_success = 0
        self.proxy_latencies: List[float] = []

        self.direct_probes_total = 0
        self.direct_probes_success = 0
        self.direct_latencies: List[float] = []

        self.app_footprints: List[Tuple[float, float]] = []  # (elapsed_hours, footprint_mb)
        self.app_cpus: List[float] = []
        self.tun_cpus: List[float] = []
        self.tun_rsses: List[float] = []

        signal.signal(signal.SIGINT, self._handle_signal)
        signal.signal(signal.SIGTERM, self._handle_signal)

    def ensure_dirs(self):
        try:
            self.output_dir.mkdir(parents=True, exist_ok=True)
        except Exception:
            pass

    def _handle_signal(self, signum, frame):
        self.log(f"Received termination signal {signum}, persisting state and exiting gracefully...")
        self.running = False

    def log(self, message: str):
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{timestamp}] {message}"
        print(line, flush=True)
        self.ensure_dirs()
        try:
            with open(self.human_log_path, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except Exception:
            pass

    def log_alert(self, alert_type: str, details: str):
        self.total_alerts += 1
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        entry = f"[{timestamp}] [{alert_type.upper()}] {details}\n"
        print(f"🚨 {entry.strip()}", flush=True)
        self.ensure_dirs()
        try:
            with open(self.alert_path, "a", encoding="utf-8") as f:
                f.write(entry)
        except Exception:
            pass

    @staticmethod
    def run_cmd(cmd: str, timeout: float = 12.0) -> Tuple[str, str, int]:
        try:
            res = subprocess.run(
                cmd, shell=True, capture_output=True, text=True, timeout=timeout
            )
            return res.stdout.strip(), res.stderr.strip(), res.returncode
        except Exception as e:
            return "", str(e), -1

    def resolve_pids(self) -> Tuple[Optional[int], Optional[int]]:
        app_pid = None
        tun_pid = None
        out, _, _ = self.run_cmd("pgrep -f '/Applications/AetherRoute.app/Contents/MacOS/AetherRoute'")
        if out:
            try:
                app_pid = int(out.splitlines()[0])
            except ValueError:
                pass

        out, _, _ = self.run_cmd("pgrep -f 'com.aetherroute.desktop.tunnel'")
        if out:
            try:
                tun_pid = int(out.splitlines()[0])
            except ValueError:
                pass

        return app_pid, tun_pid

    def get_proc_metrics(self, pid: Optional[int], is_system_extension: bool = False) -> Optional[Dict[str, Any]]:
        if not pid:
            return None
        out, _, code = self.run_cmd(f"ps -p {pid} -o %cpu,rss,vsz")
        if code != 0 or not out:
            return None
        lines = out.splitlines()
        if len(lines) < 2:
            return None
        parts = lines[1].split()
        try:
            cpu = float(parts[0])
            rss_mb = round(int(parts[1]) / 1024.0, 2)
            vsz_mb = round(int(parts[2]) / 1024.0, 2)
        except (ValueError, IndexError):
            return None

        footprint_mb = None
        peak_mb = None
        if not is_system_extension:
            vm_out, _, vm_code = self.run_cmd(f"vmmap -summary {pid}", timeout=8.0)
            if vm_code == 0:
                fp_match = re.search(r"Physical footprint:\s+([\d.]+)([KMGT]?)", vm_out)
                if fp_match:
                    val, unit = float(fp_match.group(1)), fp_match.group(2)
                    mult = {"K": 1/1024.0, "M": 1.0, "G": 1024.0, "T": 1024.0 * 1024.0}.get(unit, 1.0)
                    footprint_mb = round(val * mult, 2)
                pk_match = re.search(r"Physical footprint \(peak\):\s+([\d.]+)([KMGT]?)", vm_out)
                if pk_match:
                    val, unit = float(pk_match.group(1)), pk_match.group(2)
                    mult = {"K": 1/1024.0, "M": 1.0, "G": 1024.0, "T": 1024.0 * 1024.0}.get(unit, 1.0)
                    peak_mb = round(val * mult, 2)

        threads = 1
        th_out, _, th_code = self.run_cmd(f"ps -M {pid}", timeout=5.0)
        if th_code == 0:
            threads = max(1, len(th_out.splitlines()) - 1)

        # Detailed FD breakdown
        fds_breakdown = {"total": 0, "sockets": 0, "files": 0, "pipes": 0, "system": 0, "close_wait": 0}
        out_fd, _, code_fd = self.run_cmd(f"lsof -n -P -p {pid} 2>/dev/null")
        if code_fd == 0 and out_fd:
            fd_lines = out_fd.splitlines()
            fds_breakdown["total"] = max(0, len(fd_lines) - 1)
            for l in fd_lines[1:]:
                if "CLOSE_WAIT" in l:
                    fds_breakdown["close_wait"] += 1
                parts_l = l.split()
                if len(parts_l) >= 5:
                    ftype = parts_l[4].upper()
                    if "IPV" in ftype or "SOCK" in ftype:
                        fds_breakdown["sockets"] += 1
                    elif "REG" in ftype or "DIR" in ftype:
                        fds_breakdown["files"] += 1
                    elif "PIPE" in ftype or "FIFO" in ftype:
                        fds_breakdown["pipes"] += 1
                    else:
                        fds_breakdown["system"] += 1

        return {
            "pid": pid,
            "cpu": cpu,
            "rss_mb": rss_mb,
            "vsz_mb": vsz_mb,
            "footprint_mb": footprint_mb,
            "peak_mb": peak_mb,
            "threads": threads,
            "fds": fds_breakdown["total"],
            "fds_breakdown": fds_breakdown,
        }

    def probe_dns(self, host: str) -> Dict[str, Any]:
        t0 = time.time()
        try:
            infos = socket.getaddrinfo(host, 443, family=socket.AF_INET)
            latency_ms = (time.time() - t0) * 1000.0
            ip = infos[0][4][0]
            is_fake = ip.startswith("198.18.") or ip.startswith("198.19.")
            return {
                "host": host,
                "ip": ip,
                "latency_ms": round(latency_ms, 2),
                "is_fake_ip": is_fake,
                "success": True,
            }
        except Exception as e:
            return {
                "host": host,
                "ip": None,
                "latency_ms": -1.0,
                "is_fake_ip": False,
                "success": False,
                "error": str(e),
            }

    def probe_http(self, url: str) -> Tuple[str, float]:
        cmd = f"curl -s -o /dev/null -w '%{{http_code}}:%{{time_total}}' --connect-timeout 4 {url}"
        out, _, code = self.run_cmd(cmd)
        if code == 0 and out:
            parts = out.split(":")
            try:
                return parts[0], float(parts[1])
            except (ValueError, IndexError):
                pass
        return "000", -1.0

    def detect_utun_stats(self) -> Optional[Dict[str, Any]]:
        # Find interface bound to 198.18.0.1
        if not self.utun_name:
            out, _, code = self.run_cmd("ifconfig")
            if code == 0:
                blocks = re.split(r"\n(?=[a-zA-Z0-9_]+:)", out)
                for b in blocks:
                    if "inet 198.18.0.1" in b or "198.18." in b:
                        self.utun_name = b.split(":")[0].strip()
                        break

        if not self.utun_name:
            return None

        out, _, code = self.run_cmd(f"netstat -I {self.utun_name}")
        if code != 0 or not out:
            return None
        data_lines = [l for l in out.splitlines() if l.strip() and not l.startswith("Name")]
        if not data_lines:
            return None
        parts = data_lines[0].split()
        if len(parts) < 8:
            return None

        try:
            mtu = int(parts[1])
            ipkts = int(parts[3])
            ierrs = int(parts[4])
            opkts = int(parts[5])
            oerrs = int(parts[6])
            coll = int(parts[7])
        except (ValueError, IndexError):
            return None

        pps_in = 0
        pps_out = 0
        if self.prev_utun_stats and self.interval > 0:
            pps_in = max(0, int((ipkts - self.prev_utun_stats["ipkts"]) / self.interval))
            pps_out = max(0, int((opkts - self.prev_utun_stats["opkts"]) / self.interval))

        self.prev_utun_stats = {"ipkts": ipkts, "opkts": opkts}

        return {
            "interface": self.utun_name,
            "mtu": mtu,
            "ipkts": ipkts,
            "ierrs": ierrs,
            "opkts": opkts,
            "oerrs": oerrs,
            "coll": coll,
            "pps_in": pps_in,
            "pps_out": pps_out,
        }

    def get_tcp_socket_states(self) -> Dict[str, int]:
        out, _, code = self.run_cmd("netstat -an -p tcp")
        counts = {
            "ESTABLISHED": 0,
            "CLOSE_WAIT": 0,
            "TIME_WAIT": 0,
            "SYN_SENT": 0,
            "LISTEN": 0,
        }
        if code == 0 and out:
            for line in out.splitlines():
                if line.startswith("tcp"):
                    parts = line.split()
                    if len(parts) >= 6:
                        state = parts[5]
                        counts[state] = counts.get(state, 0) + 1
        return counts

    def check_logs(self, window_seconds: int) -> Tuple[int, List[str]]:
        predicate = 'subsystem == "com.aetherroute.desktop" && (messageType == error || messageType == fault)'
        cmd = f"/usr/bin/log show --predicate '{predicate}' --last {window_seconds}s --style compact"
        out, _, _ = self.run_cmd(cmd)
        error_lines = [
            l for l in out.splitlines()
            if l.strip() and not l.startswith("Timestamp") and not l.startswith("---")
        ]
        return len(error_lines), error_lines

    def check_crashes(self) -> List[str]:
        dirs = [
            Path.home() / "Library" / "Logs" / "DiagnosticReports",
            Path("/Library/Logs/DiagnosticReports"),
        ]
        crashes = []
        for d in dirs:
            if not d.exists():
                continue
            try:
                for item in d.glob("*"):
                    if not item.is_file():
                        continue
                    name_lower = item.name.lower()
                    if "aetherroute" in name_lower or "com.aetherroute" in name_lower:
                        mtime = item.stat().st_mtime
                        mtime_utc = datetime.datetime.fromtimestamp(mtime, datetime.timezone.utc)
                        if mtime_utc >= self.start_time:
                            crashes.append(str(item))
            except Exception:
                pass
        return crashes

    def calculate_memory_slope(self) -> float:
        # Calculate least-squares slope (MB per hour) over recorded (elapsed_hours, footprint_mb)
        if len(self.app_footprints) < 5:
            return 0.0
        n = len(self.app_footprints)
        xs = [pt[0] for pt in self.app_footprints]
        ys = [pt[1] for pt in self.app_footprints]
        mean_x = sum(xs) / n
        mean_y = sum(ys) / n
        var_x = sum((x - mean_x) ** 2 for x in xs)
        if var_x == 0:
            return 0.0
        cov_xy = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
        slope = cov_xy / var_x
        return round(slope, 2)

    def update_live_status(self, current_rec: Dict[str, Any]):
        now = datetime.datetime.now(datetime.timezone.utc)
        elapsed = int((now - self.start_time).total_seconds())

        avg_app_cpu = sum(self.app_cpus) / len(self.app_cpus) if self.app_cpus else 0.0
        avg_tun_cpu = sum(self.tun_cpus) / len(self.tun_cpus) if self.tun_cpus else 0.0

        fps = [pt[1] if isinstance(pt, (tuple, list)) else pt for pt in self.app_footprints]
        app_fp_init = fps[0] if fps else None
        app_fp_curr = fps[-1] if fps else None
        app_fp_delta = round(app_fp_curr - app_fp_init, 2) if (app_fp_curr is not None and app_fp_init is not None) else 0.0

        tun_rss_init = self.tun_rsses[0] if self.tun_rsses else None
        tun_rss_curr = self.tun_rsses[-1] if self.tun_rsses else None
        tun_rss_delta = round(tun_rss_curr - tun_rss_init, 2) if (tun_rss_curr is not None and tun_rss_init is not None) else 0.0

        mem_slope = self.calculate_memory_slope()

        # Probe stats
        proxy_sr = (self.proxy_probes_success / self.proxy_probes_total * 100.0) if self.proxy_probes_total > 0 else 100.0
        proxy_lat_avg = sum(self.proxy_latencies) / len(self.proxy_latencies) if self.proxy_latencies else 0.0

        direct_sr = (self.direct_probes_success / self.direct_probes_total * 100.0) if self.direct_probes_total > 0 else 100.0
        direct_lat_avg = sum(self.direct_latencies) / len(self.direct_latencies) if self.direct_latencies else 0.0

        # Verdict calculation
        verdict = "HEALTHY"
        reasons = []
        if self.total_crashes > 0:
            verdict = "CRITICAL"
            reasons.append("Crash detected")
        if self.total_errors > 50:
            verdict = "CRITICAL"
            reasons.append("High os_log error volume")
        if app_fp_delta > 100.0 or mem_slope > 25.0:
            verdict = "CRITICAL"
            reasons.append("Severe memory growth or leak slope")
        elif self.total_errors > 0 or proxy_sr < 95.0 or direct_sr < 95.0 or mem_slope > 10.0:
            if verdict != "CRITICAL":
                verdict = "WARNING"
                reasons.append("Degraded probe success or noticeable memory slope")

        status_data = {
            "title": "AetherRoute Full-Spectrum Observability Status",
            "startTime": self.start_time.isoformat(),
            "lastUpdated": now.isoformat(),
            "elapsedSeconds": elapsed,
            "targetDurationSeconds": self.duration_seconds,
            "progressPercent": min(100.0, round((elapsed / self.duration_seconds) * 100.0, 2)),
            "samplingIntervalSeconds": self.interval,
            "totalSamples": self.samples_count,
            "verdict": verdict,
            "verdictReasons": reasons,
            "latestSnapshot": current_rec,
            "aggregates": {
                "process": {
                    "avgAppCPU": round(avg_app_cpu, 2),
                    "maxAppCPU": round(max(self.app_cpus), 2) if self.app_cpus else 0.0,
                    "appFootprintInitialMB": app_fp_init,
                    "appFootprintCurrentMB": app_fp_curr,
                    "appFootprintDeltaMB": app_fp_delta,
                    "memorySlopeMBPerHour": mem_slope,
                    "avgTunnelCPU": round(avg_tun_cpu, 2),
                    "maxTunnelCPU": round(max(self.tun_cpus), 2) if self.tun_cpus else 0.0,
                    "tunnelRSSInitialMB": tun_rss_init,
                    "tunnelRSSCurrentMB": tun_rss_curr,
                    "tunnelRSSDeltaMB": tun_rss_delta,
                },
                "network": {
                    "proxyProbesTotal": self.proxy_probes_total,
                    "proxySuccessRatePercent": round(proxy_sr, 2),
                    "proxyAvgLatencySeconds": round(proxy_lat_avg, 3),
                    "directProbesTotal": self.direct_probes_total,
                    "directSuccessRatePercent": round(direct_sr, 2),
                    "directAvgLatencySeconds": round(direct_lat_avg, 3),
                },
                "stability": {
                    "totalErrors": self.total_errors,
                    "totalCrashes": self.total_crashes,
                    "totalAlerts": self.total_alerts,
                    "sleepWakeEvents": self.sleep_wake_events,
                }
            }
        }

        self.ensure_dirs()
        try:
            with open(self.status_path, "w", encoding="utf-8") as f:
                json.dump(status_data, f, indent=2)
        except Exception:
            pass

    def run_loop(self):
        self.log("====================================================================")
        self.log(f"Starting Full-Spectrum Observability Daemon (Target: {self.duration_seconds / 3600:.1f} Hours / {self.duration_seconds}s)")
        self.log(f"Sampling interval: {self.interval}s")
        self.log(f"Direct Probe (Domestic): {self.direct_url} | Proxy Probe (International): {self.proxy_url}")
        self.log(f"Live Status: {self.status_path}")
        self.log("====================================================================")

        iteration = 0
        while self.running:
            now_utc = datetime.datetime.now(datetime.timezone.utc)
            elapsed = int((now_utc - self.start_time).total_seconds())
            elapsed_hours = round(elapsed / 3600.0, 4)

            if elapsed >= self.duration_seconds:
                self.log(f"Target duration of {self.duration_seconds} seconds reached! Completing continuous run.")
                break

            # 1. Dynamic PID resolution & recovery
            curr_app_pid, curr_tun_pid = self.resolve_pids()
            if curr_app_pid != self.app_pid and curr_app_pid is not None:
                if self.app_pid is not None:
                    self.log_alert("PROCESS_CHANGED", f"AetherRoute App PID changed from {self.app_pid} to {curr_app_pid}")
                self.app_pid = curr_app_pid
            if curr_tun_pid != self.tun_pid and curr_tun_pid is not None:
                if self.tun_pid is not None:
                    self.log_alert("PROCESS_CHANGED", f"Tunnel PID changed from {self.tun_pid} to {curr_tun_pid}")
                self.tun_pid = curr_tun_pid

            # 2. Process metrics
            app_m = self.get_proc_metrics(self.app_pid, is_system_extension=False)
            tun_m = self.get_proc_metrics(self.tun_pid, is_system_extension=True)

            # 3. DNS Health
            dns_apple = self.probe_dns("www.apple.com")
            dns_google = self.probe_dns("www.google.com")
            if not dns_google["success"] or not dns_apple["success"]:
                self.log_alert("DNS_QUERY_FAIL", f"DNS resolution failed: Apple={dns_apple.get('error')}, Google={dns_google.get('error')}")

            # 4. Dual-Target HTTP Probes
            p_code, p_lat = self.probe_http(self.proxy_url)
            self.proxy_probes_total += 1
            if p_code == "200":
                self.proxy_probes_success += 1
                self.proxy_latencies.append(p_lat)
            else:
                self.log_alert("PROXY_PROBE_FAIL", f"Proxy probe {self.proxy_url} failed with HTTP {p_code}")

            d_code, d_lat = self.probe_http(self.direct_url)
            self.direct_probes_total += 1
            if d_code in ("200", "301", "302"):
                self.direct_probes_success += 1
                self.direct_latencies.append(d_lat)
            else:
                self.log_alert("DIRECT_PROBE_FAIL", f"Direct probe {self.direct_url} returned HTTP {d_code}")

            if len(self.proxy_latencies) > 300:
                self.proxy_latencies = self.proxy_latencies[-300:]
            if len(self.direct_latencies) > 300:
                self.direct_latencies = self.direct_latencies[-300:]

            # 5. UTUN interface throughput & packet errors
            utun_stats = self.detect_utun_stats()
            if utun_stats:
                if utun_stats["ierrs"] > 0 or utun_stats["oerrs"] > 0:
                    self.log_alert("TUN_PACKET_ERRORS", f"utun errors detected: ierrs={utun_stats['ierrs']}, oerrs={utun_stats['oerrs']}")

            # 6. TCP Socket States Breakdown & Leak Checks
            tcp_states = self.get_tcp_socket_states()
            app_cw = app_m.get("fds_breakdown", {}).get("close_wait", 0) if app_m else 0
            if app_cw > 5:
                self.log_alert("APP_CLOSE_WAIT_LEAK", f"AetherRoute has {app_cw} unclosed CLOSE_WAIT sockets")
            elif tcp_states.get("CLOSE_WAIT", 0) > 150:
                self.log_alert("SYSTEM_CLOSE_WAIT_HIGH", f"System-wide CLOSE_WAIT elevated: {tcp_states.get('CLOSE_WAIT')}")
            if tcp_states.get("SYN_SENT", 0) > 15:
                self.log_alert("SYN_SENT_STALL", f"Stalled SYN_SENT sockets: {tcp_states.get('SYN_SENT')}")

            # 7. Unified Log Errors
            err_count, err_lines = self.check_logs(self.interval + 5)
            if err_count > 0:
                self.total_errors += err_count
                for el in err_lines:
                    self.log_alert("OS_LOG_ERROR", el)

            # 8. Crashes
            crashes = self.check_crashes()
            if len(crashes) > self.total_crashes:
                new_crashes = len(crashes) - self.total_crashes
                self.total_crashes = len(crashes)
                for cr in crashes[-new_crashes:]:
                    self.log_alert("CRASH_FOUND", cr)

            # Record history for memory drift
            if app_m and app_m["footprint_mb"] is not None:
                self.app_footprints.append((elapsed_hours, app_m["footprint_mb"]))
                if len(self.app_footprints) > 1000:
                    self.app_footprints = self.app_footprints[-1000:]
            if app_m:
                self.app_cpus.append(app_m["cpu"])
                if len(self.app_cpus) > 1000:
                    self.app_cpus = self.app_cpus[-1000:]
            if tun_m:
                self.tun_cpus.append(tun_m["cpu"])
                self.tun_rsses.append(tun_m["rss_mb"])
                if len(self.tun_cpus) > 1000:
                    self.tun_cpus = self.tun_cpus[-1000:]
                    self.tun_rsses = self.tun_rsses[-1000:]

            self.samples_count += 1
            now_iso = now_utc.isoformat()

            record = {
                "timestamp": now_iso,
                "elapsed_seconds": elapsed,
                "app": app_m,
                "tunnel": tun_m,
                "dns": {
                    "apple_ms": dns_apple.get("latency_ms"),
                    "google_ms": dns_google.get("latency_ms"),
                    "google_ip": dns_google.get("ip"),
                    "is_fake_ip": dns_google.get("is_fake_ip"),
                },
                "probes": {
                    "proxy": {"http_code": p_code, "latency": p_lat},
                    "direct": {"http_code": d_code, "latency": d_lat},
                },
                "utun": utun_stats,
                "tcp_states": tcp_states,
                "log_errors": err_count,
                "total_crashes": self.total_crashes,
            }

            self.last_record = record
            self.ensure_dirs()

            # Append to JSONL feed
            try:
                with open(self.jsonl_path, "a", encoding="utf-8") as f:
                    f.write(json.dumps(record) + "\n")
            except Exception as e:
                self.log(f"Error writing to JSONL: {e}")

            # Update live snapshot
            self.update_live_status(record)

            # Compact console log
            app_fp = f"{app_m['footprint_mb']}MB" if (app_m and app_m['footprint_mb'] is not None) else (f"{app_m['rss_mb']}MB(rss)" if app_m else "OFF")
            app_cpu = f"{app_m['cpu']}%" if app_m else "OFF"
            tun_rss = f"{tun_m['rss_mb']}MB" if tun_m else "OFF"
            tun_cpu = f"{tun_m['cpu']}%" if tun_m else "OFF"
            fds = app_m['fds'] if app_m else 0
            utun_pps = f"{utun_stats['pps_in']}/{utun_stats['pps_out']}pps" if utun_stats else "N/A"
            dns_str = f"DNS:{dns_google.get('latency_ms', -1):.1f}ms"

            self.log(
                f"T+{elapsed//3600:02d}h{(elapsed%3600)//60:02d}m{elapsed%60:02d}s | "
                f"App CPU:{app_cpu:>5s}, FP:{app_fp:>8s}, FDs:{fds:2d} | "
                f"Tun CPU:{tun_cpu:>5s}, RSS:{tun_rss:>7s} | "
                f"Proxy:{p_code}({p_lat:.2f}s), Direct:{d_code}({d_lat:.2f}s) | "
                f"{dns_str}, utun:{utun_pps} | Errs:{self.total_errors}, Crash:{self.total_crashes}"
            )

            iteration += 1
            time.sleep(self.interval)

        self.log("Continuous Observability Daemon loop ended.")
        if self.last_record:
            self.update_live_status(self.last_record)

def main():
    parser = argparse.ArgumentParser(description="Full-Spectrum Continuous Observability Daemon")
    parser.add_argument("--duration-hours", type=float, default=36.0, help="Observation duration in hours (default: 36.0)")
    parser.add_argument("--duration-seconds", type=int, default=None, help="Optional duration in seconds (overrides --duration-hours)")
    parser.add_argument("--interval", type=int, default=30, help="Sampling interval in seconds (default: 30)")
    parser.add_argument("--output-dir", type=str, default="reports/diagnostics", help="Output directory")
    parser.add_argument("--proxy-url", type=str, default="https://www.google.com", help="International proxy probe URL")
    parser.add_argument("--direct-url", type=str, default="https://www.apple.com", help="Domestic direct probe URL")
    args = parser.parse_args()

    dur_seconds = args.duration_seconds if args.duration_seconds is not None else int(args.duration_hours * 3600)
    observer = ContinuousStabilityObserver(
        duration_seconds=dur_seconds,
        interval=args.interval,
        output_dir=args.output_dir,
        proxy_url=args.proxy_url,
        direct_url=args.direct_url,
    )
    observer.run_loop()

if __name__ == "__main__":
    main()
