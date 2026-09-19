#!/usr/bin/env python3
import base64
import json
import pathlib
import socketserver
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def read_bytes(path: str) -> bytes:
    return pathlib.Path(path).read_bytes()


if len(sys.argv) != 7:
    raise SystemExit(
        "usage: server.py PORT_FILE ACTIVE REVOKED DEVICE_LIMIT UPDATE ACTIVE_RECEIPT"
    )

port_file = pathlib.Path(sys.argv[1])
active_envelope = read_bytes(sys.argv[2])
revoked_envelope = read_bytes(sys.argv[3])
device_limit_envelope = read_bytes(sys.argv[4])
update_envelope = read_bytes(sys.argv[5])
expected_receipt = base64.b64encode(read_bytes(sys.argv[6])).decode("ascii")


class Handler(BaseHTTPRequestHandler):
    server_version = "AetherRouteStaging/1"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def send_bytes(self, status: int, body: bytes = b"") -> None:
        self.send_response(status)
        if body:
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self) -> None:
        if (
            self.path != "/v1/update"
            or self.headers.get("Accept") != "application/json"
            or self.headers.get("User-Agent") != "AetherRoute/1 UpdateChecker"
        ):
            self.send_bytes(404)
            return
        self.send_bytes(200, update_envelope)

    def do_POST(self) -> None:
        if (
            self.path != "/v1/license"
            or self.headers.get("Content-Type") != "application/json"
            or self.headers.get("Accept") != "application/json"
            or self.headers.get("User-Agent") != "AetherRoute/1 LicenseClient"
        ):
            self.send_bytes(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 64 * 1024:
                raise ValueError("invalid body size")
            request = json.loads(self.rfile.read(length))
            required = {
                "schemaVersion",
                "action",
                "productID",
                "deviceID",
                "appVersion",
                "appBuild",
                "licenseKey",
                "signedReceipt",
            }
            if set(request) != required:
                raise ValueError("invalid request shape")
            if (
                request["schemaVersion"] != 1
                or request["productID"] != "com.example.aetherroute"
                or request["deviceID"] != "11111111-2222-3333-4444-555555555555"
                or request["appVersion"] != "1.0.0"
                or request["appBuild"] != "100"
            ):
                raise ValueError("invalid client identity")
        except (ValueError, json.JSONDecodeError):
            self.send_bytes(400)
            return

        action = request["action"]
        if action == "activate" and request["signedReceipt"] is None:
            responses = {
                "ACTIVE-LICENSE-KEY": active_envelope,
                "REVOKED-LICENSE-KEY": revoked_envelope,
                "DEVICE-LIMIT-KEY": device_limit_envelope,
            }
            response = responses.get(request["licenseKey"])
            self.send_bytes(200, response) if response else self.send_bytes(404)
            return
        if (
            action == "refresh"
            and request["licenseKey"] is None
            and request["signedReceipt"] == expected_receipt
        ):
            self.send_bytes(200, revoked_envelope)
            return
        if (
            action == "deactivate"
            and request["licenseKey"] is None
            and request["signedReceipt"] == expected_receipt
        ):
            self.send_bytes(204)
            return
        self.send_bytes(400)


class StagingServer(ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = self.server_address[0]
        self.server_port = self.server_address[1]


server = StagingServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_address[1]), encoding="ascii")
server.serve_forever()

