#!/usr/bin/env python3
"""Loopback-only HTTP CONNECT proxy used as a `type: http` node in tests.

Requires Basic credentials, relays only to 127.0.0.1, records each accepted
CONNECT authority to the log file, and prints its port once listening.
"""
import base64
import socket
import sys
import threading

LOG_PATH, USER, PASSWORD = sys.argv[1], sys.argv[2], sys.argv[3]
EXPECTED_AUTH = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
log_lock = threading.Lock()


def pipe(source, destination):
    try:
        while data := source.recv(65536):
            destination.sendall(data)
    except OSError:
        pass
    finally:
        try:
            destination.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client):
    with client:
        header = b""
        while b"\r\n\r\n" not in header:
            chunk = client.recv(4096)
            if not chunk or len(header) > 16384:
                return
            header += chunk
        lines = header.split(b"\r\n\r\n", 1)[0].decode("latin-1").split("\r\n")
        method, authority, _ = (lines[0].split(" ") + ["", ""])[:3]
        fields = {
            name.strip().lower(): value.strip()
            for name, _, value in (line.partition(":") for line in lines[1:])
        }
        if fields.get("proxy-authorization") != EXPECTED_AUTH:
            client.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
            return
        host, _, port = authority.rpartition(":")
        if method != "CONNECT" or host != "127.0.0.1" or not port.isdigit():
            client.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
            return
        try:
            upstream = socket.create_connection((host, int(port)), timeout=5)
        except OSError:
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            return
        with upstream:
            with log_lock, open(LOG_PATH, "a", encoding="utf-8") as log:
                log.write(f"CONNECT {authority}\n")
            client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            relay = threading.Thread(target=pipe, args=(client, upstream), daemon=True)
            relay.start()
            pipe(upstream, client)
            relay.join(5)


listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(16)
print(listener.getsockname()[1], flush=True)
while True:
    connection, _ = listener.accept()
    threading.Thread(target=handle, args=(connection,), daemon=True).start()
