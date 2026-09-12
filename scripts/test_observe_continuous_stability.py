#!/usr/bin/env python3
"""Unit tests for observe_continuous_stability.py."""

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from observe_continuous_stability import ContinuousStabilityObserver

class TestContinuousStabilityObserver(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_observer_initialization(self):
        obs = ContinuousStabilityObserver(
            duration_seconds=100,
            interval=5,
            output_dir=self.temp_dir,
            probe_url="https://example.com"
        )
        self.assertEqual(obs.duration_seconds, 100)
        self.assertEqual(obs.interval, 5)
        self.assertTrue(obs.jsonl_path.parent.exists())

    def test_status_update_healthy(self):
        obs = ContinuousStabilityObserver(
            duration_seconds=100,
            interval=5,
            output_dir=self.temp_dir,
        )
        obs.app_footprints = [95.0, 95.5]
        obs.app_cpus = [0.1, 0.2]
        obs.tun_cpus = [1.0, 1.2]
        obs.tun_rsses = [80.0, 81.0]
        obs.successful_probes = 10
        obs.total_probes = 10
        obs.latencies = [0.5, 0.6]

        rec = {
            "app": {"pid": 1234, "cpu": 0.2, "footprint_mb": 95.5, "rss_mb": 150.0, "fds": 80},
            "tunnel": {"pid": 5678, "cpu": 1.2, "rss_mb": 81.0, "threads": 10},
            "probe": {"http_code": "200", "latency": 0.6},
            "log_errors": 0,
            "total_crashes": 0
        }
        obs.update_live_status(rec)

        self.assertTrue(obs.status_path.exists())
        with open(obs.status_path, "r") as f:
            data = json.load(f)

        self.assertEqual(data["verdict"], "HEALTHY")
        self.assertEqual(data["aggregates"]["stability"]["totalErrors"], 0)
        self.assertEqual(data["aggregates"]["stability"]["totalCrashes"], 0)
        self.assertAlmostEqual(data["aggregates"]["process"]["appFootprintDeltaMB"], 0.5)

    def test_status_update_critical_on_crash(self):
        obs = ContinuousStabilityObserver(
            duration_seconds=100,
            interval=5,
            output_dir=self.temp_dir,
        )
        obs.total_crashes = 1
        obs.update_live_status({})

        with open(obs.status_path, "r") as f:
            data = json.load(f)
        self.assertEqual(data["verdict"], "CRITICAL")

if __name__ == "__main__":
    unittest.main()
