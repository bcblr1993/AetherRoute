#!/usr/bin/env python3
"""Unit tests for monitor_local_health.py."""

from datetime import datetime, timezone
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from monitor_local_health import (
    evaluate_health,
    parse_crash_file,
)


class TestMonitorLocalHealth(unittest.TestCase):
    def test_parse_crash_file_text(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".crash", delete=False) as f:
            f.write(
                "Process:               AetherRoute [1234]\n"
                "Path:                  /Applications/AetherRoute.app\n"
                "Exception Type:        EXC_BAD_ACCESS (SIGSEGV)\n"
                "Termination Reason:    Namespace SIGNAL, Code 11 Segmentation fault: 11\n"
                "Crashed Thread:        0 Dispatch queue: com.apple.main-thread\n"
            )
            temp_path = Path(f.name)

        try:
            info = parse_crash_file(temp_path)
            self.assertEqual(info["exception_type"], "EXC_BAD_ACCESS (SIGSEGV)")
            self.assertIn("SIGNAL, Code 11", info["termination_reason"])
            self.assertIn("Crashed Thread:        0", info["faulting_thread"])
        finally:
            temp_path.unlink(missing_ok=True)

    def test_parse_crash_file_json_ips(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".ips", delete=False) as f:
            data = {
                "app_name": "AetherRoute",
                "timestamp": "2026-09-12 04:00:00.0000 +0800",
                "exception": {"type": "EXC_CRASH (SIGABRT)"},
                "termination": {"indicator": "Abort trap: 6"},
                "faultingThread": 2,
            }
            f.write(json.dumps(data) + "\n{}")
            temp_path = Path(f.name)

        try:
            info = parse_crash_file(temp_path)
            self.assertEqual(info["exception_type"], "EXC_CRASH (SIGABRT)")
            self.assertEqual(info["termination_reason"], "Abort trap: 6")
            self.assertEqual(info["faulting_thread"], 2)
        finally:
            temp_path.unlink(missing_ok=True)

    def test_evaluate_health_healthy(self):
        processes = [
            {
                "pid": 100,
                "type": "app",
                "name": "AetherRoute",
                "cpu_percent": 1.2,
                "rss_mb": 120.0,
                "footprint_mb": 95.0,
                "open_fd_count": 50,
            },
            {
                "pid": 101,
                "type": "tunnel",
                "name": "com.aetherroute.desktop.tunnel",
                "cpu_percent": 2.0,
                "rss_mb": 180.0,
                "footprint_mb": None,
                "open_fd_count": 20,
            },
        ]
        crashes = []
        logs = {
            "window_minutes": 30,
            "total_errors": 0,
            "total_faults": 0,
            "nw_unconnected_calls": 0,
        }

        eval_res = evaluate_health(processes, crashes, logs)
        self.assertEqual(eval_res["status"], "HEALTHY")
        self.assertIn("All runtime health checks passed cleanly.", eval_res["issues"])

    def test_evaluate_health_critical_on_crash(self):
        processes = [
            {"pid": 100, "type": "app", "name": "AetherRoute"},
            {"pid": 101, "type": "tunnel", "name": "com.aetherroute.desktop.tunnel"},
        ]
        crashes = [{"filename": "AetherRoute-2026-09-12.ips", "exception_type": "EXC_BAD_ACCESS"}]
        logs = {"total_errors": 0, "total_faults": 0}

        eval_res = evaluate_health(processes, crashes, logs)
        self.assertEqual(eval_res["status"], "CRITICAL")
        self.assertTrue(any("crash report" in issue for issue in eval_res["issues"]))

    def test_evaluate_health_warning_on_high_memory(self):
        processes = [
            {
                "pid": 100,
                "type": "app",
                "name": "AetherRoute",
                "footprint_mb": 350.0,
                "rss_mb": 450.0,
                "open_fd_count": 50,
            },
            {"pid": 101, "type": "tunnel", "name": "com.aetherroute.desktop.tunnel"},
        ]
        eval_res = evaluate_health(processes, [], {"total_errors": 0, "total_faults": 0})
        self.assertEqual(eval_res["status"], "WARNING")
        self.assertTrue(any("footprint is high" in issue for issue in eval_res["issues"]))

    def test_evaluate_health_detects_unconnected_nw_calls(self):
        processes = [
            {"pid": 100, "type": "app", "name": "AetherRoute"},
            {"pid": 101, "type": "tunnel", "name": "com.aetherroute.desktop.tunnel"},
        ]
        logs = {
            "window_minutes": 30,
            "total_errors": 5,
            "total_faults": 0,
            "nw_unconnected_calls": 5,
        }
        eval_res = evaluate_health(processes, [], logs)
        self.assertTrue(any("CFNetwork unconnected nw_connection" in issue for issue in eval_res["issues"]))


if __name__ == "__main__":
    unittest.main()
