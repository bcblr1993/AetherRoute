#!/usr/bin/env python3
"""Unit tests for monitor_aetherroute_daemon.py and generate_monitor_report.py."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from monitor_aetherroute_daemon import (
    AnomalyEngine,
    write_csv_row,
    CSV_HEADERS,
)
from generate_monitor_report import (
    percentile,
    analyze_metrics,
    generate_markdown,
)


def make_healthy_sample(epoch: int = 1000, footprint: float = 90.0, cpu: float = 1.0) -> dict:
    return {
        "timestamp_iso": "2026-09-22T08:00:00Z",
        "epoch": epoch,
        "app": {
            "pid": 1001,
            "ppid": 1,
            "name": "AetherRoute",
            "cpu_percent": cpu,
            "mem_percent": 0.2,
            "rss_mb": 110.0,
            "vsz_mb": 4000.0,
            "footprint_mb": footprint,
            "peak_footprint_mb": footprint + 5.0,
            "thread_count": 4,
            "fd_count": 50,
        },
        "tunnel": {
            "pid": 1002,
            "ppid": 1,
            "name": "com.aetherroute.desktop.tunnel",
            "cpu_percent": 1.5,
            "mem_percent": 0.1,
            "rss_mb": 80.0,
            "vsz_mb": 3000.0,
            "footprint_mb": None,
            "peak_footprint_mb": None,
            "thread_count": 12,
            "fd_count": 20,
        },
        "network": {
            "tcp_states": {"ESTABLISHED": 50, "CLOSE_WAIT": 0, "TIME_WAIT": 10},
            "app_close_wait": 0,
            "utun": {"interface": "utun7", "mtu": 1500, "ipkts": 1000, "ierrs": 0, "opkts": 1200, "oerrs": 0},
            "proxy_probe": {"ok": True, "http_code": "204", "connect_s": 0.01, "tls_s": 0.15, "total_s": 0.25},
            "direct_probe": {"ok": True, "http_code": "200", "connect_s": 0.01, "tls_s": 0.03, "total_s": 0.05},
        },
        "dns": {"ok": True, "latency_ms": 5.0, "is_fake_ip": True, "error": None},
        "logs": {"total_errors": 0, "total_faults": 0, "panics_or_asserts": 0},
    }


class TestAnomalyEngine(unittest.TestCase):
    def test_healthy_cycle(self):
        engine = AnomalyEngine()
        sample = make_healthy_sample()
        verdict, issues, flags = engine.update_and_detect(sample, crashes=[])
        self.assertEqual(verdict, "HEALTHY")
        self.assertIn("All operational checks normal.", issues)
        self.assertEqual(flags, [])

    def test_process_missing(self):
        engine = AnomalyEngine()
        sample = make_healthy_sample()
        sample["app"] = None
        verdict, issues, flags = engine.update_and_detect(sample, crashes=[])
        self.assertEqual(verdict, "CRITICAL")
        self.assertIn("PROCESS_APP_MISSING", flags)

    def test_process_restart_detected(self):
        engine = AnomalyEngine()
        sample1 = make_healthy_sample(epoch=1000)
        engine.update_and_detect(sample1, crashes=[])

        sample2 = make_healthy_sample(epoch=1060)
        sample2["app"]["pid"] = 9999  # New PID
        verdict, issues, flags = engine.update_and_detect(sample2, crashes=[])
        self.assertEqual(verdict, "CRITICAL")
        self.assertIn("APP_PID_RESTARTED", flags)

    def test_crash_report_detected(self):
        engine = AnomalyEngine()
        sample = make_healthy_sample()
        crashes = [{"file": "/path/to/AetherRoute.ips", "name": "AetherRoute.ips"}]
        verdict, issues, flags = engine.update_and_detect(sample, crashes=crashes)
        self.assertEqual(verdict, "CRITICAL")
        self.assertIn("CRASH_DETECTED", flags)

    def test_sustained_high_cpu_strikes(self):
        engine = AnomalyEngine()
        # 1st cycle high CPU: no trigger yet (need 3 strikes)
        sample1 = make_healthy_sample(cpu=50.0)
        v1, _, f1 = engine.update_and_detect(sample1, [])
        self.assertEqual(v1, "HEALTHY")

        # 2nd cycle high CPU
        sample2 = make_healthy_sample(cpu=48.0)
        v2, _, f2 = engine.update_and_detect(sample2, [])
        self.assertEqual(v2, "HEALTHY")

        # 3rd cycle high CPU: strike reached!
        sample3 = make_healthy_sample(cpu=52.0)
        v3, issues3, f3 = engine.update_and_detect(sample3, [])
        self.assertEqual(v3, "WARNING")
        self.assertIn("CPU_APP_SUSTAINED_HIGH", f3)

    def test_memory_creep_detection(self):
        engine = AnomalyEngine()
        # Feed 20 samples with increasing footprint (+3MB each min -> +60MB total)
        for i in range(20):
            sample = make_healthy_sample(epoch=1000 + i * 60, footprint=90.0 + (i * 3.0))
            v, issues, flags = engine.update_and_detect(sample, [])
            if i < 14:
                self.assertNotIn("MEMORY_LEAK_WARNING", flags)
            else:
                self.assertIn("MEMORY_LEAK_WARNING", flags)
                self.assertEqual(v, "WARNING")

    def test_close_wait_socket_leak(self):
        engine = AnomalyEngine()
        sample = make_healthy_sample()
        sample["network"]["app_close_wait"] = 6
        verdict, issues, flags = engine.update_and_detect(sample, [])
        self.assertEqual(verdict, "WARNING")
        self.assertIn("SOCKET_LEAK_CLOSE_WAIT", flags)

    def test_proxy_degradation_strikes_vs_direct_control(self):
        engine = AnomalyEngine()
        # 1. Proxy slow but direct is fast -> strike 1 (no alert yet)
        sample1 = make_healthy_sample()
        sample1["network"]["proxy_probe"]["total_s"] = 3.5
        v1, _, f1 = engine.update_and_detect(sample1, [])
        self.assertEqual(v1, "HEALTHY")

        # 2. Proxy slow second time -> strike 2 -> alert!
        sample2 = make_healthy_sample()
        sample2["network"]["proxy_probe"]["total_s"] = 4.0
        v2, _, f2 = engine.update_and_detect(sample2, [])
        self.assertEqual(v2, "WARNING")
        self.assertIn("PROXY_PATH_DEGRADED", f2)

        # 3. Host offline: both proxy and direct fail -> no proxy degraded alert blamed on app
        engine_offline = AnomalyEngine()
        sample_off = make_healthy_sample()
        sample_off["network"]["proxy_probe"]["ok"] = False
        sample_off["network"]["direct_probe"]["ok"] = False
        _, issues_off, f_off = engine_offline.update_and_detect(sample_off, [])
        self.assertNotIn("PROXY_PATH_DEGRADED", f_off)
        self.assertTrue(any("offline" in msg for msg in issues_off))

    def test_incident_cooldown(self):
        engine = AnomalyEngine()
        t0 = 10000.0
        self.assertTrue(engine.should_capture_incident("TEST_FLAG", t0))
        # 60 seconds later: still within cooldown
        self.assertFalse(engine.should_capture_incident("TEST_FLAG", t0 + 60.0))
        # 700 seconds later: cooldown expired
        self.assertTrue(engine.should_capture_incident("TEST_FLAG", t0 + 700.0))


class TestReporting(unittest.TestCase):
    def test_percentile_computation(self):
        data = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
        self.assertAlmostEqual(percentile(data, 50), 5.5)
        self.assertAlmostEqual(percentile(data, 90), 9.1)
        self.assertEqual(percentile([], 50), 0.0)

    def test_analyze_metrics_and_markdown(self):
        rows = [
            {
                "timestamp_iso": "2026-09-22T08:00:00Z",
                "epoch": "1000",
                "verdict": "HEALTHY",
                "anomaly_flags": "NONE",
                "app_cpu": "1.0",
                "app_footprint_mb": "90.0",
                "app_rss_mb": "100.0",
                "app_fds": "40",
                "tunnel_cpu": "2.0",
                "tunnel_rss_mb": "80.0",
                "app_close_wait": "0",
                "tcp_established": "50",
                "proxy_ok": "True",
                "proxy_total_s": "0.25",
                "proxy_tls_s": "0.15",
                "direct_total_s": "0.05",
                "dns_ok": "True",
                "dns_latency_ms": "5.0",
                "dns_is_fake_ip": "True",
                "log_errors_1m": "0",
                "log_faults_1m": "0",
                "log_unconnected_calls": "0",
                "log_tcp_copy_errs": "0",
            },
            {
                "timestamp_iso": "2026-09-22T08:01:00Z",
                "epoch": "1060",
                "verdict": "HEALTHY",
                "anomaly_flags": "NONE",
                "app_cpu": "1.5",
                "app_footprint_mb": "91.0",
                "app_rss_mb": "101.0",
                "app_fds": "42",
                "tunnel_cpu": "2.5",
                "tunnel_rss_mb": "81.0",
                "app_close_wait": "0",
                "tcp_established": "52",
                "proxy_ok": "True",
                "proxy_total_s": "0.26",
                "proxy_tls_s": "0.16",
                "direct_total_s": "0.05",
                "dns_ok": "True",
                "dns_latency_ms": "5.2",
                "dns_is_fake_ip": "True",
                "log_errors_1m": "0",
                "log_faults_1m": "0",
                "log_unconnected_calls": "0",
                "log_tcp_copy_errs": "0",
            },
        ]
        analysis = analyze_metrics(rows, incidents=[])
        self.assertEqual(analysis["total_samples"], 2)
        self.assertEqual(analysis["overall_verdict"], "HEALTHY")
        self.assertAlmostEqual(analysis["cpu"]["app_mean"], 1.25)
        self.assertEqual(analysis["memory"]["app_delta"], 1.0)
        self.assertEqual(analysis["network"]["proxy_avail_pct"], 100.0)

        md = generate_markdown(analysis)
        self.assertIn("AetherRoute 稳定性与运行时性能分析报告", md)
        self.assertIn("HEALTHY", md)
        self.assertIn("未捕获任何异常事件", md)


if __name__ == "__main__":
    unittest.main()
