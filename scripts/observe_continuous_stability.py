#!/usr/bin/env python3
"""
Continuous High-Frequency Stability & Performance Observer for AetherRoute.
Designed to run continuously for 24+ hours with 30-second sampling intervals.
Records App Footprint, RSS, CPU, Threads, FDs, Tunnel metrics, Unified Log errors,
DiagnosticReports crashes, and external connectivity latency.
"""

import argparse
import datetime
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

sys.stdout.reconfigure(line_buffering=True)

class ContinuousStabilityObserver:
    def __init__(
        self,
        duration_seconds: int = 86400,
        interval: int = 30,
        output_dir: str = "reports/diagnostics",
        probe_url: str = "https://www.google.com",
    ):
        self.duration_seconds = duration_seconds
        self.interval = interval
        self.output_dir = Path(output_dir)
        self.probe_url = probe_url
        self.start_time = datetime.datetime.now(datetime.timezone.utc)
        self.running = True

        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.jsonl_path = self.output_dir / "continuous_stability.jsonl"
        self.status_path = self.output_dir / "continuous_stability_status.json"
        self.alert_path = self.output_dir / "continuous_stability_alerts.log"
        self.human_log_path = self.output_dir / "continuous_stability.log"

        self.app_pid: Optional[int] = None
        self.tun_pid: Optional[int] = None
        self.samples_count = 0
        self.total_errors = 0
        self.total_crashes = 0
        self.total_probes = 0
        self.successful_probes = 0
        self.latencies: List[float] = []
        self.app_footprints: List[float] = []
        self.app_cpus: List[float] = []
        self.tun_cpus: List[float] = []
        self.tun_rsses: List[float] = []

        signal.signal(signal.SIGINT, self._handle_signal)
        signal.signal(signal.SIGTERM, self._handle_signal)

    def _handle_signal(self, signum, frame):
        self.log(f"Received termination signal {signum}, saving final snapshot and exiting...")
        self.running = False

    def log(self, message: str):
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{timestamp}] {message}"
        print(line, flush=True)
        try:
            with open(self.human_log_path, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except Exception:
            pass

    def log_alert(self, alert_type: str, details: str):
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        entry = f"[{timestamp}] [{alert_type.upper()}] {details}\n"
        print(f"🚨 {entry.strip()}", flush=True)
        try:
            with open(self.alert_path, "a", encoding="utf-8") as f:
                f.write(entry)
        except Exception:
            pass

    @staticmethod
    def run_cmd(cmd: str, timeout: float = 15.0) -> Tuple[str, str, int]:
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
        if not is_system_extension:
            vm_out, _, vm_code = self.run_cmd(f"vmmap -summary {pid}", timeout=8.0)
            if vm_code == 0:
                fp_match = re.search(r"Physical footprint:\s+([\d.]+)([KMGT]?)", vm_out)
                if fp_match:
                    val, unit = float(fp_match.group(1)), fp_match.group(2)
                    multiplier = {"K": 1/1024.0, "M": 1.0, "G": 1024.0, "T": 1024.0 * 1024.0}.get(unit, 1.0)
                    footprint_mb = round(val * multiplier, 2)

        threads = 1
        th_out, _, th_code = self.run_cmd(f"ps -M {pid}", timeout=5.0)
        if th_code == 0:
            threads = max(1, len(th_out.splitlines()) - 1)

        out_fd, _, code_fd = self.run_cmd(f"lsof -p {pid} 2>/dev/null | wc -l")
        fds = int(out_fd.strip()) if code_fd == 0 and out_fd.strip().isdigit() else 0

        return {
            "pid": pid,
            "cpu": cpu,
            "rss_mb": rss_mb,
            "vsz_mb": vsz_mb,
            "footprint_mb": footprint_mb,
            "threads": threads,
            "fds": fds,
        }

    def probe_network(self) -> Tuple[str, float]:
        cmd = f"curl -s -o /dev/null -w '%{{http_code}}:%{{time_total}}' --connect-timeout 4 {self.probe_url}"
        out, _, code = self.run_cmd(cmd)
        if code == 0 and out:
            parts = out.split(":")
            try:
                return parts[0], float(parts[1])
            except (ValueError, IndexError):
                pass
        return "000", -1.0

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

    def update_live_status(self, current_rec: Dict[str, Any]):
        now = datetime.datetime.now(datetime.timezone.utc)
        elapsed = int((now - self.start_time).total_seconds())

        avg_app_cpu = sum(self.app_cpus) / len(self.app_cpus) if self.app_cpus else 0.0
        avg_tun_cpu = sum(self.tun_cpus) / len(self.tun_cpus) if self.tun_cpus else 0.0
        app_fp_init = self.app_footprints[0] if self.app_footprints else None
        app_fp_curr = self.app_footprints[-1] if self.app_footprints else None
        app_fp_delta = round(app_fp_curr - app_fp_init, 2) if (app_fp_curr is not None and app_fp_init is not None) else 0.0
        tun_rss_init = self.tun_rsses[0] if self.tun_rsses else None
        tun_rss_curr = self.tun_rsses[-1] if self.tun_rsses else None
        tun_rss_delta = round(tun_rss_curr - tun_rss_init, 2) if (tun_rss_curr is not None and tun_rss_init is not None) else 0.0

        avg_lat = sum(self.latencies) / len(self.latencies) if self.latencies else 0.0
        probe_success_rate = (self.successful_probes / self.total_probes * 100.0) if self.total_probes > 0 else 100.0

        verdict = "HEALTHY"
        if self.total_crashes > 0 or self.total_errors > 50 or (app_fp_delta > 100.0):
            verdict = "CRITICAL"
        elif self.total_errors > 0 or probe_success_rate < 95.0 or (app_fp_delta > 30.0):
            verdict = "WARNING"

        status_data = {
            "startTime": self.start_time.isoformat(),
            "lastUpdated": now.isoformat(),
            "elapsedSeconds": elapsed,
            "targetDurationSeconds": self.duration_seconds,
            "progressPercent": min(100.0, round((elapsed / self.duration_seconds) * 100.0, 2)),
            "samplingIntervalSeconds": self.interval,
            "totalSamples": self.samples_count,
            "verdict": verdict,
            "currentMetrics": current_rec,
            "aggregates": {
                "avgAppCPU": round(avg_app_cpu, 2),
                "maxAppCPU": round(max(self.app_cpus), 2) if self.app_cpus else 0.0,
                "appFootprintInitialMB": app_fp_init,
                "appFootprintCurrentMB": app_fp_curr,
                "appFootprintDeltaMB": app_fp_delta,
                "avgTunnelCPU": round(avg_tun_cpu, 2),
                "maxTunnelCPU": round(max(self.tun_cpus), 2) if self.tun_cpus else 0.0,
                "tunnelRSSInitialMB": tun_rss_init,
                "tunnelRSSCurrentMB": tun_rss_curr,
                "tunnelRSSDeltaMB": tun_rss_delta,
                "totalErrors": self.total_errors,
                "totalCrashes": self.total_crashes,
                "totalProbes": self.total_probes,
                "probeSuccessRatePercent": round(probe_success_rate, 2),
                "avgProbeLatencySeconds": round(avg_lat, 3),
            }
        }

        try:
            with open(self.status_path, "w", encoding="utf-8") as f:
                json.dump(status_data, f, indent=2)
        except Exception:
            pass

    def run_loop(self):
        self.log("====================================================================")
        self.log(f"Starting Continuous Stability Observer (Target: {self.duration_seconds / 3600:.1f} Hours / {self.duration_seconds}s)")
        self.log(f"Sampling interval: {self.interval}s | Probe: {self.probe_url}")
        self.log(f"JSONL Feed: {self.jsonl_path}")
        self.log(f"Live Status: {self.status_path}")
        self.log("====================================================================")

        iteration = 0
        while self.running:
            now_utc = datetime.datetime.now(datetime.timezone.utc)
            elapsed = int((now_utc - self.start_time).total_seconds())

            if elapsed >= self.duration_seconds:
                self.log(f"Target duration of {self.duration_seconds} seconds reached! Completing continuous run.")
                break

            # Dynamic PID resolution & recovery
            curr_app_pid, curr_tun_pid = self.resolve_pids()
            if curr_app_pid != self.app_pid and curr_app_pid is not None:
                if self.app_pid is not None:
                    self.log_alert("PROCESS_CHANGED", f"AetherRoute PID changed from {self.app_pid} to {curr_app_pid}")
                self.app_pid = curr_app_pid
            if curr_tun_pid != self.tun_pid and curr_tun_pid is not None:
                if self.tun_pid is not None:
                    self.log_alert("PROCESS_CHANGED", f"Tunnel PID changed from {self.tun_pid} to {curr_tun_pid}")
                self.tun_pid = curr_tun_pid

            app_m = self.get_proc_metrics(self.app_pid, is_system_extension=False)
            tun_m = self.get_proc_metrics(self.tun_pid, is_system_extension=True)

            http_code, latency = self.probe_network()
            self.total_probes += 1
            if http_code == "200":
                self.successful_probes += 1
                self.latencies.append(latency)
            else:
                self.log_alert("NETWORK_FAIL", f"Probe to {self.probe_url} failed with HTTP {http_code}")

            # Keep latency window manageable
            if len(self.latencies) > 500:
                self.latencies = self.latencies[-500:]

            err_count, err_lines = self.check_logs(self.interval + 5)
            if err_count > 0:
                self.total_errors += err_count
                for el in err_lines:
                    self.log_alert("OS_LOG_ERROR", el)

            crashes = self.check_crashes()
            if len(crashes) > self.total_crashes:
                new_crashes = len(crashes) - self.total_crashes
                self.total_crashes = len(crashes)
                for cr in crashes[-new_crashes:]:
                    self.log_alert("CRASH_FOUND", cr)

            if app_m and app_m["footprint_mb"] is not None:
                self.app_footprints.append(app_m["footprint_mb"])
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
                "probe": {
                    "http_code": http_code,
                    "latency": latency,
                },
                "log_errors": err_count,
                "total_crashes": self.total_crashes,
            }

            # Append to JSONL feed
            try:
                with open(self.jsonl_path, "a", encoding="utf-8") as f:
                    f.write(json.dumps(record) + "\n")
            except Exception as e:
                self.log(f"Error writing to JSONL: {e}")

            self.last_record = record
            # Update live snapshot
            self.update_live_status(record)

            # Terminal log every cycle
            app_fp = f"{app_m['footprint_mb']}MB" if (app_m and app_m['footprint_mb'] is not None) else (f"{app_m['rss_mb']}MB(rss)" if app_m else "N/A")
            app_cpu = f"{app_m['cpu']}%" if app_m else "OFF"
            tun_rss = f"{tun_m['rss_mb']}MB" if tun_m else "OFF"
            tun_cpu = f"{tun_m['cpu']}%" if tun_m else "OFF"
            fds = app_m['fds'] if app_m else 0

            self.log(
                f"T+{elapsed//3600:02d}h{(elapsed%3600)//60:02d}m{elapsed%60:02d}s | "
                f"App CPU: {app_cpu:>5s}, FP: {app_fp:>8s}, FDs: {fds:2d} | "
                f"Tun CPU: {tun_cpu:>5s}, RSS: {tun_rss:>7s} | "
                f"Probe: {http_code} ({latency:.3f}s) | "
                f"Errs: {self.total_errors}, Crashes: {self.total_crashes}"
            )

            iteration += 1
            time.sleep(self.interval)

        self.log("Continuous Stability Observer loop ended.")
        if hasattr(self, "last_record") and self.last_record:
            self.update_live_status(self.last_record)

def main():
    parser = argparse.ArgumentParser(description="Continuous High-Frequency Stability Observer")
    parser.add_argument("--duration-hours", type=float, default=24.0, help="Total observation duration in hours (default: 24.0)")
    parser.add_argument("--duration-seconds", type=int, default=None, help="Optional duration in seconds (overrides --duration-hours)")
    parser.add_argument("--interval", type=int, default=30, help="Sampling interval in seconds (default: 30)")
    parser.add_argument("--output-dir", type=str, default="reports/diagnostics", help="Output directory")
    parser.add_argument("--probe-url", type=str, default="https://www.google.com", help="Probe URL")
    args = parser.parse_args()

    dur_seconds = args.duration_seconds if args.duration_seconds is not None else int(args.duration_hours * 3600)
    observer = ContinuousStabilityObserver(
        duration_seconds=dur_seconds,
        interval=args.interval,
        output_dir=args.output_dir,
        probe_url=args.probe_url,
    )
    observer.run_loop()

if __name__ == "__main__":
    main()
