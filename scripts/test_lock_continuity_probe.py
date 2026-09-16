#!/usr/bin/env python3
import http.server
import threading
import unittest

from lock_continuity_probe import probe


class ContinuityTests(unittest.TestCase):
    def run_server(self, close_after):
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                self.server.requests += 1
                self.send_response(204)
                self.send_header("Content-Length", "0")
                if self.server.requests >= close_after:
                    self.send_header("Connection", "close")
                    self.close_connection = True
                self.end_headers()

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.requests = 0
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server, f"http://127.0.0.1:{server.server_port}/generate_204"

    def test_continuous_connection_passes(self):
        server, url = self.run_server(100)
        result = probe(url, duration=0.05, interval=0.01)
        self.assertGreater(result["requests"], 1)
        self.assertEqual(result["requests"], server.requests)
        self.assertEqual(result["reconnects"], 0)

    def test_reconnection_cannot_hide_an_interruption(self):
        server, url = self.run_server(2)
        with self.assertRaises(RuntimeError):
            probe(url, duration=0.05, interval=0.01)
        self.assertEqual(server.requests, 2)


if __name__ == "__main__":
    unittest.main()
