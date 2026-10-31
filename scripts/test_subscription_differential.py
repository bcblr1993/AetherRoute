#!/usr/bin/env python3
"""Tests for the Mihomo differential (scripts/subscription_differential.py).

The unit half runs in test.sh with no network and no engines. The end-to-end
half (`--e2e`) drives Mihomo and our engine against a sing-box server on
loopback, so it needs the interop tools and the clash-rs build; it runs with
the release interop gates.
"""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import subscription_differential as diff  # noqa: E402

SECRET_SERVER = "secret-node.example.net"
SECRET_PASSWORD = "p4ssw0rd-should-never-leak"
SECRET_UUID = "11111111-2222-3333-4444-555555555555"


def ok(delay=120):
    return {"ok": True, "delay": delay}


def failed(error="timeout"):
    return {"ok": False, "error": error}


class ClassifyTests(unittest.TestCase):
    def test_every_outcome_has_its_own_class(self):
        self.assertEqual(diff.classify(ok(), ok()), "both_ok")
        self.assertEqual(diff.classify(failed(), failed()), "both_fail")
        # Mihomo reaches the node and we do not: the case the tool exists for.
        self.assertEqual(diff.classify(ok(), failed()), "ours_fail")
        self.assertEqual(diff.classify(failed(), ok()), "mihomo_fail")
        # The node never reached our engine (normalizer or engine skipped it).
        self.assertEqual(diff.classify(ok(), None), "ours_missing")
        self.assertEqual(diff.classify(failed(), None), "ours_missing")
        self.assertEqual(diff.classify(None, ok()), "mihomo_missing")

    def test_a_sub_millisecond_answer_is_a_success(self):
        # Our engine reports the HTTP round trip after the handshake, which
        # rounds to 0 ms on loopback; that is an answer, not a failure.
        self.assertEqual(diff.delay_result({"delay": 0, "overall": 1}),
                         {"ok": True, "delay": 0})
        self.assertEqual(diff.delay_result({"delay": 12}), {"ok": True, "delay": 12})
        self.assertFalse(diff.delay_result({"message": "timeout"})["ok"])
        self.assertFalse(diff.delay_result({"delay": -1})["ok"])
        self.assertFalse(diff.delay_result({"delay": True})["ok"])

    def test_only_our_regressions_are_findings(self):
        self.assertTrue(diff.is_finding("ours_fail"))
        self.assertTrue(diff.is_finding("ours_missing"))
        for name in ("both_ok", "both_fail", "mihomo_fail", "mihomo_missing"):
            self.assertFalse(diff.is_finding(name), name)


class SummaryTests(unittest.TestCase):
    def proxy(self, **extra):
        node = {
            "name": "HK 01",
            "type": "vless",
            "server": SECRET_SERVER,
            "port": 443,
            "uuid": SECRET_UUID,
            "password": SECRET_PASSWORD,
        }
        node.update(extra)
        return node

    def test_summary_keeps_protocol_options_and_drops_secrets(self):
        summary = diff.node_summary(self.proxy(
            network="xhttp", tls=True, flow="xtls-rprx-vision",
            **{"client-fingerprint": "chrome",
               "reality-opts": {"public-key": "k", "short-id": "s"},
               "smux": {"enabled": True}}
        ))
        self.assertEqual(summary["type"], "vless")
        self.assertEqual(summary["network"], "xhttp")
        self.assertTrue(summary["tls"])
        self.assertEqual(summary["flow"], "xtls-rprx-vision")
        self.assertEqual(summary["client-fingerprint"], "chrome")
        self.assertTrue(summary["reality"])
        self.assertTrue(summary["mux"])
        text = json.dumps(summary)
        for secret in (SECRET_SERVER, SECRET_PASSWORD, SECRET_UUID, '"k"', '"s"'):
            self.assertNotIn(secret, text)

    def test_shadowsocks_reports_cipher_and_plugin(self):
        summary = diff.node_summary({
            "name": "SS", "type": "ss", "server": SECRET_SERVER, "port": 8388,
            "cipher": "2022-blake3-aes-128-gcm", "password": SECRET_PASSWORD,
            "plugin": "obfs", "plugin-opts": {"mode": "tls", "host": SECRET_SERVER},
        })
        self.assertEqual(summary["cipher"], "2022-blake3-aes-128-gcm")
        self.assertEqual(summary["plugin"], "obfs")
        self.assertNotIn(SECRET_SERVER, json.dumps(summary))


class ReportTests(unittest.TestCase):
    def test_report_lists_findings_first_and_never_leaks_secrets(self):
        proxies = [
            {"name": "A", "type": "ss", "server": SECRET_SERVER, "port": 1,
             "cipher": "aes-128-gcm", "password": SECRET_PASSWORD},
            {"name": "B", "type": "vless", "server": SECRET_SERVER, "port": 2,
             "uuid": SECRET_UUID, "network": "xhttp"},
            {"name": "C", "type": "trojan", "server": SECRET_SERVER, "port": 3,
             "password": SECRET_PASSWORD},
        ]
        report = diff.build_report(
            raw_proxies=proxies,
            ours_proxy_names={"A", "C"},
            mihomo_results={"A": ok(80), "B": ok(90), "C": ok(70)},
            ours_results={"A": ok(85), "C": failed("handshake")},
            meta={"source": "fixture"},
        )
        self.assertEqual(report["counts"]["both_ok"], 1)
        self.assertEqual(report["counts"]["ours_missing"], 1)
        self.assertEqual(report["counts"]["ours_fail"], 1)
        self.assertEqual([f["name"] for f in report["findings"]], ["B", "C"])
        markdown = diff.render_markdown(report)
        self.assertIn("ours_missing", markdown)
        for text in (json.dumps(report), markdown):
            for secret in (SECRET_SERVER, SECRET_PASSWORD, SECRET_UUID):
                self.assertNotIn(secret, text)

    def test_names_are_redacted_on_request(self):
        report = diff.build_report(
            raw_proxies=[{"name": "Provider HK 01", "type": "ss"}],
            ours_proxy_names=set(),
            mihomo_results={"Provider HK 01": ok()},
            ours_results={},
            meta={},
            redact_names=True,
        )
        self.assertNotIn("Provider", json.dumps(report))
        self.assertEqual(report["nodes"][0]["name"], "node-1")


class ConfigTests(unittest.TestCase):
    def test_listeners_and_tunnels_are_replaced_by_the_harness_ports(self):
        profile = {
            "port": 7890, "socks-port": 7891, "redir-port": 7892,
            "tproxy-port": 7893, "mixed-port": 7894, "allow-lan": True,
            "external-controller": "0.0.0.0:9090", "external-ui": "ui",
            "secret": "api-secret", "tun": {"enable": True},
            "dns": {"enable": True, "listen": "0.0.0.0:53", "nameserver": ["223.5.5.5"]},
            "proxies": [{"name": "A", "type": "ss"}],
        }
        prepared = diff.prepare_config(profile, mixed_port=17890, api_port=19090)
        self.assertEqual(prepared["mixed-port"], 17890)
        self.assertEqual(prepared["external-controller"], "127.0.0.1:19090")
        self.assertFalse(prepared["allow-lan"])
        for key in ("port", "socks-port", "redir-port", "tproxy-port",
                    "external-ui", "secret", "tun"):
            self.assertNotIn(key, prepared)
        self.assertNotIn("listen", prepared["dns"])
        self.assertEqual(prepared["dns"]["nameserver"], ["223.5.5.5"])
        self.assertEqual(prepared["proxies"], profile["proxies"])
        # The input is left alone.
        self.assertEqual(profile["port"], 7890)

    def test_yaml_loader_reads_block_and_flow_style(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "p.yaml"
            path.write_text(
                "proxies:\n"
                "  - {name: A, type: ss, port: 1}\n"
                "  - name: B\n"
                "    type: vmess\n"
                "    ws-opts: {path: /x}\n",
                encoding="utf-8",
            )
            data = diff.load_yaml(path)
        self.assertEqual([p["name"] for p in data["proxies"]], ["A", "B"])
        self.assertEqual(data["proxies"][1]["ws-opts"]["path"], "/x")


# ---------------------------------------------------------------------------
# End to end: both engines against a sing-box server on loopback.

def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class NoContent(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


class EndToEndTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = Path(os.environ.get("AETHER_INTEROP_TOOLS", ROOT / "build/interop-tools"))
        cls.ours = Path(os.environ.get("AETHER_DIFFERENTIAL_ENGINE",
                                       ROOT / "build/differential-target/release/clash-rs"))
        for needed in (cls.tools / "sing-box", cls.tools / "mihomo-darwin-arm64-v1.19.29.gz", cls.ours):
            if not needed.exists():
                raise unittest.SkipTest(f"missing {needed}")

    def test_engines_agree_on_live_dead_unsupported_and_airport_nodes(self):
        with tempfile.TemporaryDirectory(prefix="aetherroute-diff-e2e-") as directory:
            work = Path(directory)
            mihomo = diff.unpack_mihomo(self.tools / "mihomo-darwin-arm64-v1.19.29.gz", work)

            http = HTTPServer(("127.0.0.1", 0), NoContent)
            threading.Thread(target=http.serve_forever, daemon=True).start()
            probe_url = f"http://127.0.0.1:{http.server_port}/generate_204"

            ss_port, dead_port, anytls_port, upgrade_port = (
                free_port(), free_port(), free_port(), free_port())
            vmess_port, trojan_port = free_port(), free_port()
            hy1_port, ss_mux_port = free_port(), free_port()
            password = "e2e-password"
            subprocess.run(
                ["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                 "ec_paramgen_curve:prime256v1", "-nodes", "-days", "1",
                 "-subj", "/CN=localhost", "-keyout", str(work / "key.pem"),
                 "-out", str(work / "cert.pem")],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            (work / "sing-box.json").write_text(json.dumps({
                "log": {"level": "error"},
                "inbounds": [
                    {"type": "shadowsocks", "listen": "127.0.0.1",
                     "listen_port": ss_port, "method": "aes-128-gcm",
                     "password": password},
                    {"type": "anytls", "listen": "127.0.0.1",
                     "listen_port": anytls_port,
                     "users": [{"name": "e2e", "password": password}],
                     "tls": {"enabled": True,
                             "certificate_path": str(work / "cert.pem"),
                             "key_path": str(work / "key.pem")}},
                    {"type": "vless", "listen": "127.0.0.1",
                     "listen_port": upgrade_port, "users": [{"uuid": SECRET_UUID}],
                     "transport": {"type": "httpupgrade", "path": "/up"}},
                    {"type": "vmess", "listen": "127.0.0.1", "listen_port": vmess_port,
                     "users": [{"uuid": SECRET_UUID, "alterId": 0}]},
                    {"type": "trojan", "listen": "127.0.0.1", "listen_port": trojan_port,
                     "users": [{"password": password}],
                     "tls": {"enabled": True,
                             "certificate_path": str(work / "cert.pem"),
                             "key_path": str(work / "key.pem")}},
                    {"type": "hysteria", "listen": "127.0.0.1", "listen_port": hy1_port,
                     "up_mbps": 100, "down_mbps": 100,
                     "users": [{"name": "e2e", "auth_str": password}],
                     "tls": {"enabled": True, "alpn": ["hysteria"],
                             "certificate_path": str(work / "cert.pem"),
                             "key_path": str(work / "key.pem")}},
                    {"type": "shadowsocks", "listen": "127.0.0.1",
                     "listen_port": ss_mux_port, "method": "aes-128-gcm",
                     "password": password,
                     "multiplex": {"enabled": True, "padding": False}},
                ],
                "outbounds": [{"type": "direct"}],
            }))
            server = subprocess.Popen(
                [str(self.tools / "sing-box"), "run", "-c", str(work / "sing-box.json")],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                diff.wait_for_port(ss_port, timeout=10)
                diff.wait_for_port(anytls_port, timeout=10)
                diff.wait_for_port(upgrade_port, timeout=10)
                diff.wait_for_port(vmess_port, timeout=10)
                diff.wait_for_port(trojan_port, timeout=10)
                diff.wait_for_port(ss_mux_port, timeout=10)
                profile = {
                    "mode": "global",
                    "proxies": [
                        {"name": "live", "type": "ss", "server": "127.0.0.1",
                         "port": ss_port, "cipher": "aes-128-gcm", "password": password},
                        {"name": "dead", "type": "ss", "server": "127.0.0.1",
                         "port": dead_port, "cipher": "aes-128-gcm", "password": password},
                        # Mihomo loads VMess over KCP; our engine skips it.
                        {"name": "unsupported", "type": "vmess", "server": "127.0.0.1",
                         "port": ss_port, "uuid": SECRET_UUID, "alterId": 0,
                         "cipher": "auto", "network": "kcp"},
                        # As airport subscriptions write AnyTLS nodes. Up to
                        # 1.10.0 our engine refused these options, so every
                        # such node was skipped (or the profile failed).
                        {"name": "airport-anytls", "type": "anytls",
                         "server": "127.0.0.1", "port": anytls_port,
                         "password": password, "sni": "localhost",
                         "skip-cert-verify": True, "udp": True,
                         "client-fingerprint": "chrome",
                         "idle-session-check-interval": 30,
                         "idle-session-timeout": 30, "min-idle-session": 0},
                        # Mihomo's spelling of httpupgrade. Up to 1.10.1 our
                        # engine spoke WebSocket here and got a 404.
                        {"name": "mihomo-httpupgrade", "type": "vless",
                         "server": "127.0.0.1", "port": upgrade_port,
                         "uuid": SECRET_UUID, "network": "ws",
                         "ws-opts": {"path": "/up", "v2ray-http-upgrade": True}},
                        # Panels such as Xboard write `network: tcp`
                        # explicitly; up to 1.11.0 our engine refused it.
                        {"name": "panel-vmess-tcp", "type": "vmess",
                         "server": "127.0.0.1", "port": vmess_port,
                         "uuid": SECRET_UUID, "alterId": 0, "cipher": "auto",
                         "network": "tcp"},
                        {"name": "panel-trojan-tcp", "type": "trojan",
                         "server": "127.0.0.1", "port": trojan_port,
                         "password": password, "sni": "localhost",
                         "skip-cert-verify": True, "network": "tcp"},
                        {"name": "hy1-quic", "type": "hysteria",
                         "server": "127.0.0.1", "port": hy1_port,
                         "auth-str": password, "up": 100, "down": 100,
                         "sni": "localhost", "skip-cert-verify": True},
                        {"name": "ss-smux", "type": "ss",
                         "server": "127.0.0.1", "port": ss_mux_port,
                         "cipher": "aes-128-gcm", "password": password,
                         "smux": {"enabled": True, "protocol": "smux"}},
                    ],
                    "proxy-groups": [{"name": "PROXY", "type": "select",
                                      "proxies": ["live", "dead", "unsupported",
                                                  "airport-anytls",
                                                  "mihomo-httpupgrade",
                                                  "panel-vmess-tcp",
                                                  "panel-trojan-tcp",
                                                  "hy1-quic",
                                                  "ss-smux"]}],
                    "rules": ["MATCH,PROXY"],
                }
                report = diff.compare(
                    raw_profile=profile,
                    # Our engine gets the same profile; it must skip the
                    # unsupported KCP node on its own, and the report must say so.
                    ours_profile=profile,
                    mihomo_binary=mihomo,
                    ours_binary=self.ours,
                    work=work,
                    probe_url=probe_url,
                    timeout_ms=3000,
                    attempts=1,
                    meta={"source": "e2e"},
                )
            finally:
                server.terminate()
                server.wait(timeout=5)
                http.shutdown()

        by_name = {node["name"]: node["class"] for node in report["nodes"]}
        self.assertEqual(by_name["live"], "both_ok", report)
        self.assertEqual(by_name["dead"], "both_fail", report)
        self.assertEqual(by_name["unsupported"], "ours_missing", report)
        self.assertEqual(by_name["airport-anytls"], "both_ok", report)
        self.assertEqual(by_name["mihomo-httpupgrade"], "both_ok", report)
        self.assertEqual(by_name["panel-vmess-tcp"], "both_ok", report)
        self.assertEqual(by_name["panel-trojan-tcp"], "both_ok", report)
        self.assertEqual(by_name["hy1-quic"], "both_ok", report)
        self.assertEqual(by_name["ss-smux"], "both_ok", report)
        self.assertNotIn(password, json.dumps(report))


if __name__ == "__main__":
    e2e = "--e2e" in sys.argv
    argv = [arg for arg in sys.argv if arg != "--e2e"]
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    for case in (ClassifyTests, SummaryTests, ReportTests, ConfigTests):
        suite.addTests(loader.loadTestsFromTestCase(case))
    if e2e:
        suite.addTests(loader.loadTestsFromTestCase(EndToEndTests))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
