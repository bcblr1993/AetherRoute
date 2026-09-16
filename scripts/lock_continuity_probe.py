#!/usr/bin/env python3
"""Verify repeated responses on ONE TCP connection; reconnection is forbidden."""
import argparse
import http.client
import json
import time
from urllib.parse import urlsplit


def probe(url, duration=25, interval=1, ready=lambda: None):
    target = urlsplit(url)
    if target.scheme not in ("http", "https") or not target.hostname:
        raise ValueError("an HTTP(S) keep-alive endpoint is required")
    cls = http.client.HTTPSConnection if target.scheme == "https" else http.client.HTTPConnection
    connection = cls(target.hostname, target.port, timeout=5)
    try:
        connection.connect()
        # http.client normally silently reconnects after a server closes. That
        # would turn a lock/unlock regression into a false pass.
        connection.auto_open = 0
        original_socket = connection.sock
        started = time.monotonic()
        count = 0
        while True:
            if connection.sock is not original_socket:
                raise RuntimeError("connection closed or replaced")
            path = target.path or "/"
            if target.query:
                path += "?" + target.query
            connection.request("GET", path, headers={"Connection": "keep-alive"})
            response = connection.getresponse()
            response.read()
            if response.status != 204 or connection.sock is not original_socket:
                raise RuntimeError("expected HTTP 204 on the original keep-alive connection")
            count += 1
            if count == 1:
                ready()
            if time.monotonic() - started >= duration:
                return {"requests": count, "connections": 1, "reconnects": 0}
            time.sleep(interval)
    finally:
        connection.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="https://www.google.com/generate_204")
    parser.add_argument("--duration", type=float, default=25)
    args = parser.parse_args()
    result = probe(args.url, args.duration, ready=lambda: print("READY", flush=True))
    print(json.dumps(result), flush=True)
