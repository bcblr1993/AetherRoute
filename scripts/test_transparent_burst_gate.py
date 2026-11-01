#!/usr/bin/env python3
"""Behavioral regression for the native TCP burst gate and its controlled origin."""
import importlib.util
import pathlib
import threading
import unittest
import urllib.error
import urllib.request
from unittest.mock import Mock, patch

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("burst", ROOT / "scripts/test_transparent_burst_concurrency.py")
burst = importlib.util.module_from_spec(spec)
spec.loader.exec_module(burst)


class BurstGateTests(unittest.TestCase):
    def test_first_timeout_is_not_hidden_by_retry(self):
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.getcode.return_value = 204
        opener = Mock()
        opener.open.side_effect = [TimeoutError("synthetic timeout"), response]
        with patch.object(burst.urllib.request, "build_opener", return_value=opener):
            with self.assertRaises(TimeoutError):
                burst.clean_fetch(0)
        self.assertEqual(opener.open.call_count, 1)

    def test_all_sixty_requests_can_be_in_flight_together(self):
        lock, ready = threading.Lock(), threading.Event()
        active = peak = 0
        def fetch(_):
            nonlocal active, peak
            with lock:
                active += 1
                peak = max(peak, active)
                if active == 60:
                    ready.set()
            ready.wait(timeout=1)
            with lock:
                active -= 1
            return 204
        with patch.object(burst, "clean_fetch", side_effect=fetch), \
             patch.object(burst, "get_transparent_provider_pid", return_value=None), \
             patch.object(burst.time, "sleep"), patch.object(burst, "TOTAL_REQUESTS", 60):
            self.assertEqual(burst.main(), 0)
        self.assertEqual(peak, 60)

    def test_controlled_origin_serves_only_empty_probe_responses(self):
        path = ROOT / "Tests/Interop/burst_http_server.py"
        origin_spec = importlib.util.spec_from_file_location("burst_origin", path)
        origin = importlib.util.module_from_spec(origin_spec)
        origin_spec.loader.exec_module(origin)
        server = origin.make_server("127.0.0.1", 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            base = f"http://127.0.0.1:{server.server_port}"
            with opener.open(base + "/generate_204", timeout=3) as response:
                self.assertEqual(response.status, 204)
                self.assertEqual(response.headers["X-AetherRoute-Burst"], "1")
                self.assertEqual(response.read(), b"")
            with self.assertRaises(urllib.error.HTTPError) as error:
                opener.open(base + "/key.pem", timeout=3)
            self.assertEqual(error.exception.code, 404)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
