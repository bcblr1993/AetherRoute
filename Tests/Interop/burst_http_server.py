#!/usr/bin/env python3
"""Controlled empty HTTP origin for native TCP burst testing; serves no files."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys


class ProbeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def do_GET(self):
        self.send_response(204 if self.path == "/generate_204" else 404)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.send_header("X-AetherRoute-Burst", "1")
        self.end_headers()
        self.close_connection = True

    def log_message(self, *_):
        pass


class ProbeServer(ThreadingHTTPServer):
    request_queue_size = 256
    daemon_threads = True


def make_server(host, port):
    return ProbeServer((host, port), ProbeHandler)


if __name__ == "__main__":
    with make_server("0.0.0.0", int(sys.argv[1])) as server:
        server.serve_forever()
