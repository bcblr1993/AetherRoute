#!/usr/bin/env python3
"""Check that every advertised lab node has a deployed server, not just YAML."""
import importlib.util
import hashlib
import errno
import base64
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("protocol_lab", Path(__file__).with_name("protocol_lab.py"))
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)
supervisor_spec = importlib.util.spec_from_file_location("lab_services", Path(__file__).with_name("lab_services.py"))
supervisor = importlib.util.module_from_spec(supervisor_spec)
supervisor_spec.loader.exec_module(supervisor)


class LabTests(unittest.TestCase):
    def setUp(self):
        previous = lab.OUT
        self.addCleanup(setattr, lab, "OUT", previous)
        self.key_generation = 0
        command = patch.object(lab, "run", side_effect=self.fake_tool)
        command.start()
        self.addCleanup(command.stop)
        certificate = patch.object(lab.subprocess, "run", return_value=SimpleNamespace(stdout=b"unit-test-der"))
        certificate.start()
        self.addCleanup(certificate.stop)

    def fake_tool(self, *args, **_):
        # Unit tests run on clean ARM64 workers without downloaded lab tools.
        # Real key generation/deployment is verified by the separate 43-node E2E.
        if args[0] == "openssl":
            (lab.OUT / "cert.pem").write_text("unit-test certificate fixture")
            (lab.OUT / "key.pem").write_text("unit-test key fixture")
            return ""
        if args[0].endswith("/xray"):
            self.key_generation += 1
            return json.dumps({"decryption": f"fixture-server-{self.key_generation}",
                               "encryption": f"fixture-client-{self.key_generation}"})
        key = base64.b64encode(bytes(range(32))).decode()
        if args[2] in ("reality-keypair", "wg-keypair"):
            return f"PrivateKey: {key}\nPublicKey: {key}\n"
        if args[2] == "ech-keypair":
            return "-----BEGIN ECH CONFIGS-----\ndGVzdA==\n-----END ECH CONFIGS-----\n-----BEGIN ECH KEYS-----\ndGVzdA==\n-----END ECH KEYS-----\n"
        raise AssertionError("Unexpected external command in a unit test")

    def test_all_advertised_nodes_have_server_and_fresh_encryption_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            lab.OUT = Path(tmp)
            lab.generate("192.0.2.1")
            servers = json.loads((lab.OUT / "services.json").read_text())
            expected = json.loads((lab.OUT / "expect.json").read_text())
            self.assertEqual(set(expected), {n for s in servers for n in s["nodes"]})
            self.assertTrue(all(s["argv"] and s["ports"] for s in servers))
            first = json.loads((lab.OUT / "xray.json").read_text())["inbounds"][-1]["settings"]["decryption"]
            self.assertEqual(first, f"fixture-server-{self.key_generation}")
            self.assertIn(f"fixture-client-{self.key_generation}", (lab.OUT / "clash.yaml").read_text())
            lab.generate("192.0.2.1")
            second = json.loads((lab.OUT / "xray.json").read_text())["inbounds"][-1]["settings"]["decryption"]
            self.assertNotEqual(first, second)

    def test_deploy_transfers_and_starts_all_services(self):
        with tempfile.TemporaryDirectory() as tmp:
            lab.OUT = Path(tmp)
            lab.generate("192.0.2.1")
            with patch.object(lab, "run", return_value="/tmp/aether-lab-deploy.Test12\n"), \
                 patch.object(lab.subprocess, "run") as transfer, patch.object(lab, "ssh") as remote:
                lab.deploy("tester@example.invalid")
            args = transfer.call_args.args[0]
            transferred = {Path(value).name for value in args[4:-1]}
            self.assertTrue({"services.json", "ssr.json", "awg.json", "xray.json",
                             "mihomo-listeners.yaml", "lab_services.py"} <= transferred)
            script = remote.call_args.args[1]
            self.assertIn("lab_services.py supervise", script)
            self.assertIn("lab_services.py install", script)

    def test_manifest_rejects_missing_and_duplicate_nodes(self):
        for services in ([{"nodes": ["one"]}], [{"nodes": ["one", "one", "two"]}]):
            with self.assertRaises(ValueError):
                lab.validate_services(services, {"one": {}, "two": {}})

    def test_burst_origin_is_supervised_and_exported(self):
        with tempfile.TemporaryDirectory() as tmp:
            lab.OUT = Path(tmp)
            lab.generate("192.0.2.1")
            services = json.loads((lab.OUT / "services.json").read_text())
            origin = next(service for service in services if service["name"] == "burst-http")
            port = origin["ports"][0]
            self.assertIn(port, range(lab.BASE, lab.BASE + 40))
            server = json.loads((lab.OUT / "server.json").read_text())
            actual = {item["listen_port"] for item in server["inbounds"] + server["endpoints"]}
            self.assertNotIn(port, actual, "control origin must not collide with an internal protocol listener")
            declared = next(service["ports"] for service in services if service["name"] == "sing-box")
            self.assertTrue(actual <= set(declared), "manifest must include internal listeners")
            self.assertIn("burst_http_server.py", " ".join(origin["argv"]))
            self.assertEqual((lab.OUT / "burst-url.txt").read_text().strip(),
                             f"http://192.0.2.1:{port}/generate_204")

    def test_installer_replaces_running_binary_without_truncating_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            executable = root / "tuic4"
            executable.write_bytes(b"running old binary")
            data = b"verified replacement"
            (root / "tuic4.asset").write_bytes(data)
            write_bytes = Path.write_bytes
            def reject_running_file(path, content):
                if path == executable:
                    raise OSError(errno.ETXTBSY, "Text file busy")
                return write_bytes(path, content)
            assets = {"tuic4": ("https://example.invalid/pinned", hashlib.sha256(data).hexdigest())}
            with patch.object(supervisor, "ROOT", root), patch.object(supervisor, "ASSETS", assets), \
                 patch.object(Path, "write_bytes", reject_running_file):
                supervisor.install()
            self.assertEqual(executable.read_bytes(), data)
            self.assertTrue(executable.stat().st_mode & 0o100)


if __name__ == "__main__":
    unittest.main()
