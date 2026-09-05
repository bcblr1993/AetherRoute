#!/usr/bin/env python3
"""Explicitly launched, task-owned HTTPS peer; never changes system networking.

Supply a certificate trusted only by the collector's --cacert, a private token
file, and a private LAN bind address. The same service listens on that address
and 127.0.0.1. Baseline payloads use LAN; candidate payloads require a test node
on this host to relay to loopback. No shell commands or arbitrary targets run.
"""
import argparse
import hashlib
import http.server
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import threading
import time
from urllib.parse import parse_qs, urlsplit

PROTOCOL = "aetherroute-installed-ne-performance-v1"


class PeerState:
    def __init__(self, token):
        self.token = token
        self.peer_id = secrets.token_hex(32)
        self.source_sha = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        self.mode = "baseline"
        self.receipts = {}
        self.armed = {}
        self.lock = threading.Lock()

    def save(self, request_id, receipt):
        with self.lock:
            if len(self.receipts) >= 256:
                del self.receipts[next(iter(self.receipts))]
            self.receipts[request_id] = receipt


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    disable_nagle_algorithm = True

    def log_message(self, *_):
        pass  # Never retain endpoint addresses, request IDs or authorization.

    def reply(self, value, status=200):
        data = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def authorized(self):
        expected = "Bearer " + self.server.state.token
        if not secrets.compare_digest(self.headers.get("Authorization", ""), expected):
            self.close_connection = True
            self.reply({"error": "unauthorized"}, 401)
            return False
        return True

    def request_id(self):
        value = parse_qs(urlsplit(self.path).query).get("id", [""])[0]
        if not re.fullmatch(r"[0-9a-f]{32}", value):
            raise ValueError("invalid request ID")
        return value

    def payload_allowed(self):
        state = self.server.state
        expected = "lan" if state.mode == "baseline" else "relay"
        if self.server.role != expected:
            self.close_connection = True
            self.reply({"error": "path not permitted in this phase"}, 409)
            return False
        return True

    def receipt(self, request_id, direction, count, digest):
        return {"requestID": request_id, "peerID": self.server.state.peer_id,
                "direction": direction, "bytes": count, "sha256": digest,
                "accessPath": self.server.role, "mode": self.server.state.mode}

    def do_GET(self):
        if not self.authorized():
            return
        path = urlsplit(self.path).path
        if path == "/v1/info":
            self.reply({"protocol": PROTOCOL, "peerID": self.server.state.peer_id,
                        "serverSourceSHA256": self.server.state.source_sha})
            return
        try:
            request_id = self.request_id()
            if path == "/v1/receipt":
                with self.server.state.lock:
                    receipt = self.server.state.receipts.get(request_id)
                self.reply(receipt or {"error": "receipt unavailable"}, 200 if receipt else 404)
                return
            if path == "/v1/release":
                if self.server.role != "lan":
                    raise ValueError("control requires LAN listener")
                with self.server.state.lock:
                    event = self.server.state.armed.get(request_id)
                if event is None:
                    self.reply({"error": "not armed"}, 409)
                else:
                    event.set()
                    self.reply({"requestID": request_id})
                return
            if not self.payload_allowed():
                return
            if path == "/v1/arm":
                event = threading.Event()
                with self.server.state.lock:
                    self.server.state.armed[request_id] = event
                try:
                    released = event.wait(15)
                    self.reply({"requestID": request_id}, 200 if released else 504)
                finally:
                    with self.server.state.lock:
                        self.server.state.armed.pop(request_id, None)
                return
            if path in ("/v1/latency", "/v1/hold"):
                if path == "/v1/hold":
                    time.sleep(3)  # Outside the timed transfer; keep its TCP flow observable.
                self.reply({"requestID": request_id, "peerID": self.server.state.peer_id,
                            "accessPath": self.server.role})
                return
            if path != "/v1/download":
                self.reply({"error": "unknown operation"}, 404)
                return
            seconds = int(parse_qs(urlsplit(self.path).query).get("seconds", ["10"])[0])
            if not 10 <= seconds <= 30:
                raise ValueError("invalid duration")
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            block = os.urandom(65536)
            digest = hashlib.sha256()
            count = 0
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                self.wfile.write(b"10000\r\n" + block + b"\r\n")
                digest.update(block)
                count += len(block)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            self.server.state.save(request_id, self.receipt(request_id, "download", count, digest.hexdigest()))
        except (ValueError, OSError):
            self.close_connection = True

    def do_POST(self):
        if not self.authorized():
            return
        path = urlsplit(self.path).path
        try:
            if path == "/v1/mode":
                if self.server.role != "lan":
                    raise ValueError("control requires LAN listener")
                size = int(self.headers.get("Content-Length", "0"))
                if not 1 <= size <= 128:
                    raise ValueError("invalid control body")
                mode = json.loads(self.rfile.read(size)).get("mode")
                if mode not in ("baseline", "candidate"):
                    raise ValueError("invalid mode")
                with self.server.state.lock:
                    self.server.state.mode = mode
                self.reply({"peerID": self.server.state.peer_id, "mode": mode})
                return
            if path != "/v1/upload":
                self.reply({"error": "unknown operation"}, 404)
                return
            if not self.payload_allowed():
                return
            request_id = self.request_id()
            if self.headers.get("Transfer-Encoding", "").lower() != "chunked":
                raise ValueError("streaming chunked upload required")
            digest = hashlib.sha256()
            count = 0
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                size = int(self.rfile.readline(128).split(b";", 1)[0].strip(), 16)
                if not 0 <= size <= 1024 * 1024:
                    raise ValueError("invalid chunk")
                if size == 0:
                    if self.rfile.readline(128) != b"\r\n":
                        raise ValueError("unsupported trailers")
                    receipt = self.receipt(request_id, "upload", count, digest.hexdigest())
                    self.server.state.save(request_id, receipt)
                    self.reply(receipt)
                    return
                data = self.rfile.read(size)
                if len(data) != size or self.rfile.read(2) != b"\r\n":
                    raise ValueError("incomplete chunk")
                digest.update(data)
                count += size
            raise ValueError("upload deadline exceeded")
        except (ValueError, OSError, json.JSONDecodeError):
            self.close_connection = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lan-bind", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--certificate", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    args = parser.parse_args()
    address = ipaddress.ip_address(args.lan_bind)
    if address.version != 4 or not address.is_private or address.is_loopback or address.is_unspecified or not 1024 <= args.port <= 65535:
        parser.error("an explicit private LAN address and unprivileged port are required")
    token = args.token_file.read_text().strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", token):
        parser.error("token file must contain 32–128 URL-safe random characters")
    state = PeerState(token)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.certificate, args.key)
    servers = []
    try:
        for bind, role in [(args.lan_bind, "lan"), ("127.0.0.1", "relay")]:
            server = http.server.ThreadingHTTPServer((bind, args.port), Handler)
            server.daemon_threads = True
            server.state, server.role = state, role
            server.socket = context.wrap_socket(server.socket, server_side=True)
            servers.append(server)
            threading.Thread(target=server.serve_forever, daemon=True).start()
        print("Task-owned HTTPS peer ready; baseline LAN and candidate relay paths are separate.", flush=True)
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
