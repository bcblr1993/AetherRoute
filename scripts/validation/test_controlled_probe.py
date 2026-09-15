#!/usr/bin/env python3
"""Offline adversarial cases and actual loopback TLS; no VM or NE operations."""
import copy
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("controlled_probe", HERE / "controlled_probe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def plan():
    return {"schemaVersion": 1, "runID": "a" * 32, "engine": "tun", "cycle": 1,
            "candidateManifestSHA256": "b" * 64, "peerID": "c" * 64, "peerSourceSHA256": "d" * 64,
            "hostname": "aether-performance.test", "port": 62116, "controlAddress": "192.168.64.1",
            "dataAddress": "203.0.113.123", "requestID": "e" * 32, "token": "f" * 40,
            "certificateSHA256": "0" * 64}


def response(body=b"", code=0, status=200, tls=0, address="203.0.113.123"):
    return probe.parse_response(code, body + probe.MARKER +
                                ("%03d %d %d 0.001 [%s]" % (status, tls, len(body), address)).encode(), b"")


def healthy(value):
    return response(probe.canonical({"protocol": probe.PROTOCOL, "peerID": value["peerID"],
                                     "serverSourceSHA256": value["peerSourceSHA256"]}), address=value["controlAddress"])


def relay(value):
    return json.dumps({"requestID": value["requestID"], "peerID": value["peerID"], "accessPath": "relay"},
                      separators=(",", ":")).encode()


class PlanAndPhaseTests(unittest.TestCase):
    def test_strict_plan(self):
        self.assertEqual(probe.validate_plan(plan()), plan())
        changes = [{"schemaVersion": True}, {"cycle": True}, {"port": True}, {"cycle": 0}, {"cycle": 21},
                   {"port": 443}, {"port": 65536}, {"engine": "guess"}, {"engine": None},
                   {"runID": "z" * 32}, {"hostname": "aether-performance.test\nheader=x"},
                   {"token": "f" * 32 + "\r\n"}, {"controlAddress": "127.0.0.1"},
                   {"controlAddress": "8.8.8.8"}, {"controlAddress": "192.168.0.0"},
                   {"dataAddress": "192.168.64.3"}, {"dataAddress": "203.0.113.255"},
                   {"dataAddress": 123}, {"dataAddress": "2001:db8::1"}, {"unexpected": True}]
        for changed in changes:
            with self.subTest(changed=changed), self.assertRaises(probe.ProbeError):
                probe.validate_plan(dict(plan(), **changed))
        for key in plan():
            changed = plan(); del changed[key]
            with self.subTest(missing=key), self.assertRaises(probe.ProbeError):
                probe.validate_plan(changed)

    def test_duplicate_json_keys(self):
        with self.assertRaises(probe.ProbeError):
            probe.strict_json(b'{"schemaVersion":1,"schemaVersion":1}')

    def execute(self, phase, data, health_transform=None):
        value = plan()
        inputs = SimpleNamespace(plan=value, plan_sha="1" * 64, certificate=lambda: "/private/test/cert.pem")
        controls = []
        def request(_plan, _cert, path, control):
            controls.append(control)
            if control:
                item = healthy(value)
                return health_transform(item, len(controls)) if health_transform else item
            self.assertEqual(path, "/v1/latency?id=" + value["requestID"])
            return data
        result = probe.observe(inputs, phase, request)
        self.assertEqual(controls, [True, False, True])
        self.assertLessEqual(result["startedMonotonicNS"], result["requestStartedMonotonicNS"])
        self.assertLessEqual(result["requestStartedMonotonicNS"], result["requestFinishedMonotonicNS"])
        self.assertLessEqual(result["requestFinishedMonotonicNS"], result["completedMonotonicNS"])
        raw = probe.canonical(result)
        for secret in (value["token"], value["requestID"], value["peerID"], value["controlAddress"], value["hostname"]):
            self.assertNotIn(secret.encode(), raw)
        return result

    def test_exact_connected_and_unreachable_phases(self):
        value = plan()
        result = self.execute("connected", response(relay(value)))
        self.assertEqual(result["outcome"], "matched")
        for phase in ("before", "after"):
            for code in (7, 28):
                result = self.execute(phase, response(code=code, status=0, address=""))
                self.assertEqual(result["outcome"], "unreachable")

    def test_all_other_failures_are_not_unreachable(self):
        for data in (response(code=6, status=0), response(code=35, status=0), response(code=60, status=0, tls=18),
                     response(code=28, status=0, tls=18), response(code=28, status=0, address="127.0.0.1"),
                     response(code=28, status=0, body=b"partial"), response(code=7, status=403),
                     response(relay(plan())), response(code=0, status=409)):
            with self.subTest(observation=data[0]), self.assertRaises(probe.ProbeError):
                self.execute("before", data)

    def test_connected_requires_exact_body_tls_and_target(self):
        for data in (response(relay(plan()), tls=18), response(relay(plan()), status=302),
                     response(relay(plan()), address="192.168.64.1"), response(relay(plan()), code=28),
                     response(relay(dict(plan(), requestID="9" * 32))), response(relay(dict(plan(), peerID="9" * 64))),
                     response(relay(plan()).replace(b'"relay"', b'"lan"')), response(relay(plan()) + b"\n")):
            with self.subTest(observation=data[0]), self.assertRaises(probe.ProbeError):
                self.execute("connected", data)

    def test_peer_unhealthy_or_changed_cannot_count_as_unreachable(self):
        for boundary in (1, 3):
            for mutate in (lambda x: (dict(x[0], curlExitCode=60), x[1], x[2]),
                           lambda x: (x[0], x[1].replace(b"c" * 64, b"9" * 64), x[2]),
                           lambda x: (x[0], x[1], "203.0.113.123"),
                           lambda x: (x[0], b"{}", x[2])):
                with self.subTest(boundary=boundary), self.assertRaises(probe.ProbeError):
                    self.execute("before", response(code=28, status=0, address=""),
                                 lambda x, n: mutate(x) if n == boundary else x)

    def test_metric_rejects_missing_truncated_mismatched_or_nonfinite(self):
        for raw in (b"", b"no trailer", probe.MARKER + b"200 0 1 0.1 []", probe.MARKER + b"200 0 0 nan []",
                    probe.MARKER + b"200 0 0 0.1 []\n", probe.MARKER + b"200 0 0 -1 []",
                    probe.MARKER + b"200 0 0 9 []", b"a" * 65537 + probe.MARKER + b"200 0 65537 0.1 []"):
            with self.subTest(size=len(raw)), self.assertRaises(probe.ProbeError):
                probe.parse_response(0, raw, b"")


class PrivateFileTests(unittest.TestCase):
    def setUp(self):
        self.stage = Path("/private/tmp/aether-ne-probe." + secrets.token_hex(16))
        self.stage.mkdir(mode=0o700)
        self.value = plan()
        self.certificate = b"test certificate bytes"
        self.value["certificateSHA256"] = probe.digest(self.certificate)
        self.write("server-cert.pem", self.certificate)
        self.write("plan.json", probe.canonical(self.value))

    def write(self, name, raw):
        path = self.stage / name
        path.write_bytes(raw); path.chmod(0o600)

    def tearDown(self):
        for child in self.stage.iterdir():
            child.unlink()
        self.stage.rmdir()

    def inputs(self):
        return probe.PrivateInputs(str(self.stage), probe.digest((self.stage / "plan.json").read_bytes()))

    def test_valid_pinned_inputs_and_modified_cert(self):
        inputs = self.inputs()
        try:
            self.assertEqual(inputs.plan, self.value)
            self.write("server-cert.pem", b"replaced")
            with self.assertRaises(probe.ProbeError): inputs.certificate()
        finally:
            inputs.close()

    def test_hash_mismatch_and_world_readable_stage(self):
        with self.assertRaises(probe.ProbeError): probe.PrivateInputs(str(self.stage), "f" * 64)
        self.stage.chmod(0o755)
        with self.assertRaises(probe.ProbeError): self.inputs()

    def test_plan_mode_and_duplicate_key(self):
        (self.stage / "plan.json").chmod(0o644)
        with self.assertRaises(probe.ProbeError): self.inputs()
        self.write("plan.json", b'{"schemaVersion":1,"schemaVersion":1}')
        with self.assertRaises(probe.ProbeError): self.inputs()

    def test_symlink_hardlink_fifo_and_oversized_certificate(self):
        cert = self.stage / "server-cert.pem"
        for kind in ("symlink", "hardlink", "fifo", "oversized"):
            cert.unlink()
            if kind == "symlink": cert.symlink_to("plan.json")
            elif kind == "hardlink": os.link(self.stage / "plan.json", cert)
            elif kind == "fifo": os.mkfifo(cert, 0o600)
            else: self.write("server-cert.pem", b"a" * 65537)
            with self.subTest(kind=kind), self.assertRaises((probe.ProbeError, OSError)): self.inputs()


class ProcessTests(unittest.TestCase):
    def test_monotonic_epoch_is_shared_with_new_python_processes(self):
        before = probe.monotonic_ns()
        source = "import importlib.util; s=importlib.util.spec_from_file_location('p',%r); p=importlib.util.module_from_spec(s); s.loader.exec_module(p); print(p.monotonic_ns())" % str(HERE / "controlled_probe.py")
        child = int(subprocess.check_output([sys.executable, "-I", "-B", "-c", source], timeout=3))
        after = probe.monotonic_ns()
        self.assertLessEqual(before, child)
        self.assertLessEqual(child, after)

    def command(self, source):
        return [sys.executable, "-I", "-B", "-c", source]

    def test_full_bidirectional_pipes_and_exit_status(self):
        result = probe.bounded_process(self.command("import sys; data=sys.stdin.buffer.read(); "
                      "sys.stderr.buffer.write(b'e'*8192); sys.stderr.flush(); "
                      "sys.stdout.buffer.write(b'x'*65536+data); sys.exit(23)"), b"payload")
        self.assertEqual(result, (23, b"x" * 65536 + b"payload", b"e" * 8192))

    def test_proxy_env_not_inherited_and_no_user_config(self):
        with patch.dict(os.environ, {"http_proxy": "SECRET", "HTTP_PROXY": "SECRET", "CURL_HOME": "SECRET"}):
            result = probe.bounded_process(self.command("import os; print(','.join(sorted(os.environ)))"), b"")
        self.assertNotIn(b"proxy", result[1].lower()); self.assertNotIn(b"CURL_HOME", result[1])
        captured = []
        def fake(argv, payload):
            captured.append((argv, payload))
            return 28, probe.MARKER + b"000 0 0 0.1 []", b""
        with patch.object(probe, "bounded_process", fake):
            probe.curl_request(plan(), "/private/task/cert.pem", "/v1/info", True)
        self.assertEqual(captured[0][0], ["/usr/bin/curl", "-q", "--config", "-"])
        self.assertIn(b'proxy = ""', captured[0][1]); self.assertNotIn(b"insecure", captured[0][1])

    def test_output_overflow_fails_fast(self):
        start = time.monotonic()
        with self.assertRaisesRegex(probe.ProbeError, "output-limit"):
            probe.bounded_process(self.command("import sys,time; sys.stdout.buffer.write(b'x'*200000); sys.stdout.flush(); time.sleep(20)"), b"")
        self.assertLess(time.monotonic() - start, 3)

    def test_deadline_reaps_child(self):
        with tempfile.TemporaryDirectory(prefix="aether-probe-child-") as folder:
            pidfile = Path(folder) / "pid"
            start = time.monotonic()
            source = "import os,time,pathlib; pathlib.Path(%r).write_text(str(os.getpid())); time.sleep(20)" % str(pidfile)
            with self.assertRaisesRegex(probe.ProbeError, "deadline"):
                probe.bounded_process(self.command(source), b"", timeout=2)
            self.assertLess(time.monotonic() - start, 3)
            pid = int(pidfile.read_text())
            with self.assertRaises(ProcessLookupError): os.kill(pid, 0)

    def test_exited_parent_cannot_leave_a_pipe_holding_descendant(self):
        with tempfile.TemporaryDirectory(prefix="aether-probe-descendant-") as folder:
            pidfile = Path(folder) / "pid"
            # Allow both Python interpreters to start before exercising cleanup.
            child = "import os,time,pathlib; pathlib.Path(%r).write_text(str(os.getpid())); time.sleep(20)" % str(pidfile)
            parent = "import subprocess,sys; subprocess.Popen([sys.executable,'-I','-B','-c',%r])" % child
            with self.assertRaisesRegex(probe.ProbeError, "deadline"):
                probe.bounded_process(self.command(parent), b"", timeout=2)
            pid = int(pidfile.read_text())
            deadline = time.monotonic() + 2
            while True:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                self.assertLess(time.monotonic(), deadline, "owned descendant survived process deadline")
                time.sleep(.01)


class RealTLSTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="aether-controlled-probe-tls-")
        cls.folder = Path(cls.temp.name)
        cls.cert, cls.key = cls.folder / "cert.pem", cls.folder / "key.pem"
        cls.config = cls.folder / "openssl.cnf"
        cls.config.write_text("[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=aether-performance.test\n[v3]\nsubjectAltName=DNS:aether-performance.test\nbasicConstraints=critical,CA:TRUE\n")
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-keyout", str(cls.key), "-out", str(cls.cert), "-config", str(cls.config)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        cls.key.chmod(0o600)
        cls.other_cert, cls.other_key = cls.folder / "other-cert.pem", cls.folder / "other-key.pem"
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-keyout", str(cls.other_key), "-out", str(cls.other_cert), "-config", str(cls.config)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        cls.other_key.chmod(0o600)
        cls.value = plan()
        cls.value.update(controlAddress="127.0.0.1", dataAddress="127.0.0.1")
        cls.status = 200
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                if self.headers.get("Authorization") != "Bearer " + cls.value["token"]:
                    self.send_response(401); self.end_headers(); return
                body = relay(cls.value)
                if self.path == "/v1/info":
                    body = probe.canonical({"protocol": probe.PROTOCOL, "peerID": cls.value["peerID"],
                                             "serverSourceSHA256": cls.value["peerSourceSHA256"]})
                self.send_response(cls.status)
                self.send_header("Content-Length", str(len(body))); self.end_headers()
                self.wfile.write(body)
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.server.daemon_threads = True
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cls.cert, cls.key)
        cls.server.socket = context.wrap_socket(cls.server.socket, server_side=True)
        cls.value["port"] = cls.server.server_port
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join(timeout=2); cls.temp.cleanup()

    def test_real_tls_health_and_exact_relay(self):
        value = copy.deepcopy(self.value)
        info = probe.curl_request(value, str(self.cert), "/v1/info", True)
        probe.health(value, info)
        result, body, address = probe.curl_request(value, str(self.cert), "/v1/latency?id=" + value["requestID"], False)
        self.assertEqual((result["curlExitCode"], result["tlsVerifyResult"], result["httpStatus"]), (0, 0, 200))
        self.assertEqual(body, relay(value)); self.assertEqual(address, "127.0.0.1")

    def test_real_bad_authorization_and_redirect_do_not_pass_health(self):
        value = dict(self.value, token="0" * 40)
        with self.assertRaises(probe.ProbeError):
            probe.health(value, probe.curl_request(value, str(self.cert), "/v1/info", True))
        self.__class__.status = 302
        try:
            with self.assertRaises(probe.ProbeError):
                probe.health(self.value, probe.curl_request(self.value, str(self.cert), "/v1/info", True))
        finally:
            self.__class__.status = 200

    def test_real_untrusted_certificate_is_rejected(self):
        result = probe.curl_request(self.value, str(self.other_cert), "/v1/info", True)
        self.assertEqual(result[0]["curlExitCode"], 60)
        self.assertNotEqual(result[0]["tlsVerifyResult"], 0)
        with self.assertRaises(probe.ProbeError): probe.health(self.value, result)


if __name__ == "__main__":
    unittest.main(verbosity=2)
