#!/usr/bin/env python3
"""
Unit tests for full-spectrum observability metrics in observe_continuous_stability.py.
"""

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from observe_continuous_stability import ContinuousStabilityObserver

class TestAdvancedObservability(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.obs = ContinuousStabilityObserver(
            duration_seconds=100,
            interval=5,
            output_dir=self.temp_dir,
        )

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_memory_slope_calculation(self):
        # Slope of y = 100 + 10 * x -> slope should be +10.0 MB/h
        self.obs.app_footprints = [
            (0.0, 100.0),
            (0.1, 101.0),
            (0.2, 102.0),
            (0.3, 103.0),
            (0.4, 104.0),
            (1.0, 110.0),
        ]
        slope = self.obs.calculate_memory_slope()
        self.assertAlmostEqual(slope, 10.0, places=1)

    def test_memory_slope_flat(self):
        # Flat footprint -> slope should be 0.0
        self.obs.app_footprints = [
            (0.0, 100.0),
            (0.1, 100.0),
            (0.2, 100.0),
            (0.3, 100.0),
            (0.4, 100.0),
        ]
        slope = self.obs.calculate_memory_slope()
        self.assertEqual(slope, 0.0)

    @patch("observe_continuous_stability.socket.getaddrinfo")
    def test_probe_dns_fake_ip(self, mock_gai):
        mock_gai.return_value = [(2, 1, 6, "", ("198.18.0.25", 443))]
        res = self.obs.probe_dns("www.google.com")
        self.assertTrue(res["success"])
        self.assertEqual(res["ip"], "198.18.0.25")
        self.assertTrue(res["is_fake_ip"])
        self.assertGreaterEqual(res["latency_ms"], 0.0)

    @patch("observe_continuous_stability.socket.getaddrinfo")
    def test_probe_dns_direct_ip(self, mock_gai):
        mock_gai.return_value = [(2, 1, 6, "", ("17.253.144.10", 443))]
        res = self.obs.probe_dns("www.apple.com")
        self.assertTrue(res["success"])
        self.assertEqual(res["ip"], "17.253.144.10")
        self.assertFalse(res["is_fake_ip"])

    @patch.object(ContinuousStabilityObserver, "run_cmd")
    def test_get_tcp_socket_states(self, mock_cmd):
        sample_output = """
Active Internet connections (including servers)
Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
tcp4       0      0  198.18.0.1.51234       198.18.0.25.443        ESTABLISHED
tcp4       0      0  198.18.0.1.51235       198.18.0.25.443        ESTABLISHED
tcp4       0      0  198.18.0.1.51236       198.18.0.25.443        CLOSE_WAIT
tcp4       0      0  *.9090                 *.*                    LISTEN
"""
        mock_cmd.return_value = (sample_output, "", 0)
        states = self.obs.get_tcp_socket_states()
        self.assertEqual(states["ESTABLISHED"], 2)
        self.assertEqual(states["CLOSE_WAIT"], 1)
        self.assertEqual(states["LISTEN"], 1)
        self.assertEqual(states["SYN_SENT"], 0)

    @patch.object(ContinuousStabilityObserver, "run_cmd")
    def test_detect_utun_stats(self, mock_cmd):
        self.obs.utun_name = "utun7"
        sample_netstat = """
Name       Mtu   Network       Address            Ipkts Ierrs    Opkts Oerrs  Coll
utun7      1500  <Link#27>                      1000000     0   800000     0     0
utun7      1500  198.18.0/16   198.18.0.1       1000000     -   800000     -     -
"""
        mock_cmd.return_value = (sample_netstat, "", 0)
        stats = self.obs.detect_utun_stats()
        self.assertIsNotNone(stats)
        self.assertEqual(stats["interface"], "utun7")
        self.assertEqual(stats["mtu"], 1500)
        self.assertEqual(stats["ipkts"], 1000000)
        self.assertEqual(stats["ierrs"], 0)
        self.assertEqual(stats["opkts"], 800000)
        self.assertEqual(stats["oerrs"], 0)

    def test_verdict_critical_on_leak_slope(self):
        # Simulate steep memory leak slope > 25 MB/h
        self.obs.app_footprints = [
            (0.0, 100.0),
            (0.5, 120.0),
            (1.0, 140.0),
            (1.5, 160.0),
            (2.0, 180.0),
        ]
        self.obs.update_live_status({})
        with open(self.obs.status_path, "r") as f:
            data = json.load(f)
        self.assertEqual(data["verdict"], "CRITICAL")
        self.assertIn("Severe memory growth or leak slope", data["verdictReasons"])

if __name__ == "__main__":
    unittest.main()
