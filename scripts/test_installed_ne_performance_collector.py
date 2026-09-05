#!/usr/bin/env python3
"""Negative controls and owned loopback HTTPS smoke; no VM or real NE run."""
import copy
import errno
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


collector = load("ne_collector", ROOT / "scripts/collect_installed_ne_performance.py")
peer = load("ne_peer", ROOT / "scripts/installed_ne_performance_peer.py")


class CollectorTests(unittest.TestCase):
    def testCurlTLSOrMalformedMetricsCannotPass(self):
        for line in ["NE_METRIC:200|32|0|10.1|0|60|0", "NE_METRIC:000|0|0|12|0|0|0", "NE_METRIC:nan", "bad"]:
            with self.subTest(line=line), self.assertRaises(collector.Incomplete):
                collector.parse_metric(line)
        self.assertEqual(collector.parse_metric("NE_METRIC:200|32|0|10.1|0|0|0")["duration"], 10_100_000_000)

    def observation(self):
        observed = collector.NetTopObservation(123, "192.0.2.1", 4567, "download")
        observed.feed(",bytes_in,bytes_out,\n")
        observed.feed("com.aetherroute.123,0,0,\n")
        return observed

    def testProcessTotalsAloneNeverProveAFlow(self):
        observed = self.observation()
        observed.feed("com.aetherroute.123,999999,999999,\n")
        self.assertFalse(observed.observed.is_set())
        with self.assertRaises(collector.Incomplete):
            observed.proof(32, {}, {})

    def testWrongOwnerAndWrongRemoteAreIgnored(self):
        observed = self.observation()
        observed.feed("other.124,0,0,\n")
        observed.feed("tcp4 192.0.2.2:9999<->192.0.2.1:4567,9999,9999,\n")
        observed.feed("com.aetherroute.123,0,0,\n")
        observed.feed("tcp4 192.0.2.2:9999<->192.0.2.1:4568,9999,9999,\n")
        self.assertFalse(observed.observed.is_set())

    def testOwnedFlowRequiresMonotonicSufficientBytesAndUniqueTuple(self):
        observed = self.observation()
        label = "tcp4 192.0.2.2:9999<->192.0.2.1:4567"
        observed.feed(label + ",100,0,\n")
        observed.feed(label + ",150,0,\n")
        before, after, digest = observed.proof(32, {"bytes": 32}, {"providerPID": 123})
        self.assertEqual((before, after), (100, 150))
        self.assertRegex(digest, r"^[0-9a-f]{64}$")
        with self.assertRaises(collector.Incomplete):
            observed.proof(51, {}, {})
        observed.feed(label + ",10,0,\n")
        with self.assertRaises(collector.Incomplete):
            observed.proof(1, {}, {})
        observed.feed("tcp4 192.0.2.2:10000<->192.0.2.1:4567,500,0,\n")
        with self.assertRaises(collector.Incomplete):
            observed.proof(1, {}, {})

    def testReceiptBindsNoncePeerDirectionHashBytesAndActualRelayPath(self):
        receipt = {"requestID": "request", "peerID": "peer", "direction": "download", "bytes": 32,
                   "sha256": "a" * 64, "accessPath": "relay", "mode": "candidate"}
        collector.verify_receipt(receipt, "request", "peer", "download", 32, "a" * 64, "relay")
        for key, value in [("requestID", "replayed"), ("peerID", "other"), ("direction", "upload"),
                           ("bytes", 31), ("sha256", "b" * 64), ("accessPath", "lan"), ("mode", "baseline")]:
            with self.subTest(key=key), self.assertRaises(collector.Incomplete):
                collector.verify_receipt(dict(receipt, **{key: value}), "request", "peer", "download", 32, "a" * 64, "relay")

    def testNormalTestCandidateIsOnlyDiagnosticAndDiagnosticsCoreRejected(self):
        manifest = {"schemaVersion": 1, "architecture": "arm64", "releaseStatus": "notarized-test-candidate", "build": "123",
                    "sourceManifestSHA256": "a" * 64, "signing": {"app": {"bundleID": "com.example.test"}},
                    "notarization": {"status": "Accepted"}, "safety": {"diagnosticsIncluded": False},
                    "core": {"variant": "normal", "diagnosticsIncluded": False,
                             "flow": {"features": "aether-flow-only", "artifactSHA256": "b" * 64},
                             "packet": {"features": "aether-embedded", "artifactSHA256": "c" * 64},
                             "protocolReference": {"matchesCandidateArtifacts": True, "flowArtifactSHA256": "b" * 64,
                                                   "packetArtifactSHA256": "c" * 64, "evidenceSHA256": "d" * 64}}}
        normalized, diagnostic = collector.candidate_identity(manifest)
        self.assertTrue(diagnostic)
        self.assertEqual(normalized["build"], 123)
        for mutate in (lambda m: m["core"].update(variant="diagnostics"),
                       lambda m: m["safety"].update(diagnosticsIncluded=True),
                       lambda m: m["core"]["protocolReference"].update(matchesCandidateArtifacts=False),
                       lambda m: m["core"]["packet"].update(artifactSHA256="e" * 64)):
            changed = copy.deepcopy(manifest)
            mutate(changed)
            with self.assertRaises(collector.Incomplete):
                collector.candidate_identity(changed)

    def testMissingAuthorizationProducesOnlyPendingEvidenceAndNoCommands(self):
        with tempfile.TemporaryDirectory(prefix="aether-ne-collector-test-") as temp:
            output = Path(temp) / "evidence"
            with patch.object(collector.subprocess, "run", side_effect=AssertionError("unexpected command")):
                status = collector.main(["/abs/candidate.dmg", "/abs/candidate.json", str(output),
                                         "--peer-control-url", "https://secret.invalid"])
            self.assertEqual(status, 78)
            self.assertEqual({p.name for p in output.iterdir()}, {"performance.json", "SHA256SUMS"})
            payload = (output / "performance.json").read_bytes()
            data = json.loads(payload)
            self.assertEqual(data["collectionStatus"], "pending")
            self.assertNotIn(b"secret.invalid", payload)
            self.assertEqual((output / "SHA256SUMS").read_text(), hashlib.sha256(payload).hexdigest() + "  performance.json\n")

    def latency_fixture(self, reconnect=False, wrong_nonce=False):
        def execute(arguments, **_):
            config = Path(arguments[-1]).read_text()
            ids = re.findall(r"/v1/latency\?id=([0-9a-f]{32})", config)
            self.assertEqual(len(ids), 201)
            self.assertEqual(config.count("\nnext\n"), 200)
            bodies, metrics = [], []
            for index, request_id in enumerate(ids):
                bodies.append(json.dumps({"requestID": "wrong" if wrong_nonce and index == 4 else request_id,
                                          "peerID": "peer", "accessPath": "lan"}))
                metrics.append(f"NE_METRIC:200|128|0|0.001|{0.001 if index == 0 else 0}|0|{1 if index == 0 or (reconnect and index == 5) else 0}\n")
            return subprocess.CompletedProcess(arguments, 0, "".join(bodies).encode(), "".join(metrics).encode())
        return execute

    def testEchoesUseOneCurlAndRejectReconnectOrWrongNonce(self):
        with tempfile.TemporaryDirectory(prefix="aether-ne-collector-test-") as temp:
            token = Path(temp) / "token"
            token.write_text("a" * 32)
            args = SimpleNamespace(peer_token_file=token, ca_certificate=Path(temp) / "ca.pem",
                                   peer_data_url="https://sample.test:8443", baseline_address="192.0.2.1")
            client = collector.Collector(args, temp)
            client.peer_id = "peer"
            with patch.object(collector, "run", side_effect=self.latency_fixture()) as command:
                self.assertEqual(client.latency("baseline"), [1_000_000] * 200)
                self.assertEqual(command.call_count, 1)
            for flags in ({"reconnect": True}, {"wrong_nonce": True}):
                with patch.object(collector, "run", side_effect=self.latency_fixture(**flags)), self.assertRaises(collector.Incomplete):
                    client.latency("baseline")
            self.assertFalse((Path(temp) / "latency-curl-config").exists())

    def testFailedPeerRestoreStillAttemptsDMGDetach(self):
        client = collector.Collector.__new__(collector.Collector)
        client.peer_id, client.mounted, client.work = "peer", True, Path("/temporary-task")
        with patch.object(client, "peer_mode", side_effect=collector.Incomplete("unreachable")), patch.object(collector, "run") as command:
            with self.assertRaises(collector.Incomplete):
                client.close()
            self.assertIn("detach", command.call_args.args[0])
            self.assertFalse(client.mounted)

    def testMachOBytesRejectDiagnosticsDespiteNormalManifest(self):
        with tempfile.TemporaryDirectory(prefix="aether-ne-collector-test-") as temp:
            app = Path(temp)
            binary = app / "framework"
            binary.write_bytes(bytes.fromhex("cffaedfe") + b"normal executable bytes")
            collector.verify_normal_app_bytes(app)
            binary.write_bytes(bytes.fromhex("cffaedfe") + b"x" * (1024 * 1024 - 12) + b"aether_flow stage=")
            with self.assertRaises(collector.Incomplete):
                collector.verify_normal_app_bytes(app)

    def testMissingURLHostWritesPendingWithoutTracebackOrSystemCommand(self):
        with tempfile.TemporaryDirectory(prefix="aether-ne-collector-test-") as temp:
            output = Path(temp) / "evidence"
            args = ["/abs/candidate.dmg", "/abs/candidate.json", str(output), "--authorize-network",
                    "--designated-test-host", collector.socket.gethostname(), "--peer-control-url", "https://192.168.50.2:8443",
                    "--peer-data-url", "https://", "--baseline-address", "192.168.50.2", "--node-address", "192.168.50.2",
                    "--node-port", "4567", "--peer-token-file", "/abs/token", "--ca-certificate", "/abs/ca.pem"]
            with patch.object(collector.platform, "system", return_value="Darwin"), patch.object(collector.platform, "machine", return_value="arm64"), \
                    patch.object(collector.subprocess, "run", side_effect=AssertionError("unexpected command")):
                self.assertEqual(collector.main(args), 78)
            self.assertIn("same-controlled-peer-topology-required", json.loads((output / "performance.json").read_bytes())["blockingReasons"])

    def testExplicitTargetRejectsLoopbackPublicAndBypassAddressesBeforeCommands(self):
        for address in ("127.0.0.1", "0.0.0.0", "1.1.1.1", "::1", "224.0.0.1", "255.255.255.255", "192.168.50.2"):
            with self.subTest(address=address), tempfile.TemporaryDirectory(prefix="aether-ne-target-test-") as temp:
                output = Path(temp) / "evidence"
                args = ["/abs/candidate.dmg", "/abs/candidate.json", str(output), "--authorize-network",
                        "--designated-test-host", collector.socket.gethostname(), "--peer-control-url", "https://192.168.50.2:8443",
                        "--peer-data-url", "https://sample.test:8443", "--baseline-address", "192.168.50.2",
                        "--node-address", "192.168.50.2", "--candidate-address", address, "--node-port", "4567",
                        "--peer-token-file", "/abs/token", "--ca-certificate", "/abs/ca.pem"]
                with patch.object(collector.platform, "system", return_value="Darwin"), patch.object(collector.platform, "machine", return_value="arm64"), \
                        patch.object(collector.subprocess, "run", side_effect=AssertionError("unexpected command")):
                    self.assertEqual(collector.main(args), 78)
                self.assertEqual(json.loads((output / "performance.json").read_bytes())["blockingReasons"],
                                 ["controlled-target-IP-required"])

    def testObserverWaitFailureStillClosesItsPTYAndReportsIncomplete(self):
        observed = self.observation()
        from unittest.mock import Mock
        process = Mock()
        process.poll.return_value = None
        process.wait.side_effect = subprocess.TimeoutExpired("nettop", 3)
        observed.process = process
        observed.thread = Mock()
        observed.thread.is_alive.return_value = False
        master, slave = os.openpty()
        os.close(slave)
        observed.master_fd = master
        with self.assertRaises(collector.Incomplete):
            observed.stop()
        process.kill.assert_called_once()
        self.assertIsNone(observed.master_fd)
        with self.assertRaises(OSError):
            os.fstat(master)
        observed.thread.join.assert_called_once()

    def testSurvivingObserverReaderCannotBlockIncompleteEvidence(self):
        from unittest.mock import Mock
        observed = self.observation()
        observed.process, observed.thread = Mock(), Mock()
        observed.process.poll.return_value = None
        observed.process.wait.side_effect = subprocess.TimeoutExpired("nettop", 3)
        observed.thread.is_alive.return_value = True
        with self.assertRaises(collector.Incomplete):
            observed.stop()
        self.assertTrue(observed.reader_stop.is_set())

    def testPTYLaunchFailureClosesBothOwnedDescriptors(self):
        descriptors = os.openpty()
        observed = self.observation()
        with patch.object(collector.os, "openpty", return_value=descriptors), \
                patch.object(collector.subprocess, "Popen", side_effect=OSError("injected launch failure")):
            with self.assertRaisesRegex(collector.Incomplete, "provider-observer-start-failed"):
                observed.start()
        for descriptor in descriptors:
            with self.assertRaises(OSError):
                os.fstat(descriptor)

    def testRealPTYDeliversBufferedLowVolumeLinesBeforeWriterExits(self):
        observed = collector.NetTopObservation(123, "192.0.2.1", 4567, "download")
        real_popen = subprocess.Popen
        source = "import sys,time;assert sys.stdout.isatty();print(',bytes_in,bytes_out,');print('test.123,0,0,');print('tcp4 192.0.2.2:9<->192.0.2.1:4567,4,0,');time.sleep(10)"
        def launch(_arguments, **kwargs):
            return real_popen([sys.executable, "-I", "-B", "-c", source], **kwargs)
        try:
            with patch.object(collector.subprocess, "Popen", side_effect=launch):
                observed.start()
            self.assertTrue(observed.observed.wait(3))
            self.assertIsNone(observed.process.poll())
            master = observed.master_fd
        finally:
            observed.stop()
        self.assertIsNotNone(observed.process.poll())
        self.assertFalse(observed.thread.is_alive())
        with self.assertRaises(OSError):
            os.fstat(master)

    def testPTYReaderStartupFailureReapsItsAlreadyLaunchedChild(self):
        observed = self.observation()
        real_popen = subprocess.Popen
        descriptors = os.openpty()
        def launch(_arguments, **kwargs):
            return real_popen([sys.executable, "-I", "-B", "-c", "import time;time.sleep(10)"], **kwargs)
        with patch.object(collector.os, "openpty", return_value=descriptors), \
                patch.object(collector.subprocess, "Popen", side_effect=launch), \
                patch.object(collector.threading.Thread, "start", side_effect=RuntimeError("injected thread failure")):
            with self.assertRaisesRegex(collector.Incomplete, "provider-observer-start-failed"):
                observed.start()
        self.assertIsNotNone(observed.process.poll())
        self.assertIsNone(observed.master_fd)
        for descriptor in descriptors:
            with self.assertRaises(OSError):
                os.fstat(descriptor)

    def testPTYReaderHandlesDarwinEOFAndLinuxEIOButRejectsTruncatedOrOtherErrors(self):
        for ending, partial, failed in [(b"", b"", False), (OSError(errno.EIO, "hangup"), b"", False),
                                        (b"", b"unfinished", True), (OSError(errno.EBADF, "bad descriptor"), b"", True)]:
            with self.subTest(ending=repr(ending), partial=bool(partial)):
                observed = self.observation()
                master, slave = os.openpty(); os.close(slave); observed.master_fd = master
                reads = [b",bytes_in,bytes_out,\r\n" + partial, ending]
                with patch.object(collector.select, "select", return_value=([master], [], [])), \
                        patch.object(collector.os, "read", side_effect=reads):
                    observed.consume(master)
                self.assertEqual(observed.reader_failed, failed)
                self.assertIsNone(observed.master_fd)
                with self.assertRaises(OSError):
                    os.fstat(master)

    def testActualNettopObservesOwnedLoopbackArmBeforePayload(self):
        # A real macOS process/flow observation, not mocked CSV or a throughput
        # result. Only four arm bytes cross an owned loopback socket before the
        # observer signals ready, reproducing the pilot's pre-payload condition.
        self.assertEqual(sys.platform, "darwin", "actual nettop regression requires the product's macOS test host")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0)); listener.listen(1)
            listener.settimeout(3)
            port = listener.getsockname()[1]
            observed = collector.NetTopObservation(os.getpid(), "127.0.0.1", port, "upload")
            try:
                observed.start()
                with socket.create_connection(("127.0.0.1", port), timeout=3) as client:
                    server, _ = listener.accept()
                    with server:
                        server.settimeout(3)
                        client.sendall(b"arm\n")
                        self.assertEqual(server.recv(4), b"arm\n")
                        self.assertTrue(observed.observed.wait(8), "actual low-volume flow was not observed before payload")
                        self.assertIsNone(observed.process.poll())
                        with observed.lock:
                            self.assertEqual(len(observed.flows), 1)
                            self.assertTrue(all(0 <= value < 65536 for values in observed.flows.values() for value in values))
            finally:
                observed.stop()
            self.assertFalse(observed.thread.is_alive())
            self.assertIsNone(observed.master_fd)
            self.assertIsNotNone(observed.process.poll())

    def testRejectedActualDMGTicketStopsBeforeMount(self):
        with tempfile.TemporaryDirectory(prefix="aether-ne-collector-test-") as temp:
            directory = Path(temp)
            token, dmg = directory / "token", directory / "candidate.dmg"
            token.write_text("a" * 32)
            dmg.write_bytes(b"test candidate")
            client = collector.Collector(SimpleNamespace(peer_token_file=token, dmg=dmg), directory)
            with patch.object(collector, "run", side_effect=collector.Incomplete("ticket-rejected")) as command:
                with self.assertRaises(collector.Incomplete):
                    client.candidate({"dmg": {"sha256": collector.sha_file(dmg)}})
            self.assertEqual(command.call_args.args[0], ["/usr/bin/xcrun", "stapler", "validate", str(dmg)])
            self.assertFalse(client.mounted)

    def testTemporaryCleanupFailureStillWritesChecksummedIncompleteEvidence(self):
        from unittest.mock import Mock
        work = Mock()
        work.cleanup.side_effect = OSError("injected cleanup failure")
        evidence = {"collectionStatus": "complete"}
        with tempfile.TemporaryDirectory(prefix="aether-ne-collector-test-") as temp:
            collector.finish_collection(None, work, Path(temp), evidence)
            saved = json.loads((Path(temp) / "performance.json").read_bytes())
            self.assertEqual(saved["collectionStatus"], "incomplete")
            self.assertIn("temporary-work-cleanup-failed", saved["blockingReasons"])
            self.assertTrue((Path(temp) / "SHA256SUMS").is_file())
        work._finalizer.detach.assert_called_once()

    def testFailedDetachNeverRecursivelyDeletesMountedDMG(self):
        from unittest.mock import Mock
        work, client = Mock(), Mock()
        client.mounted = True
        client.close.side_effect = collector.Incomplete("detach-failed")
        with tempfile.TemporaryDirectory(prefix="aether-ne-collector-test-") as temp:
            evidence = {"collectionStatus": "complete"}
            collector.finish_collection(client, work, Path(temp), evidence)
            self.assertEqual(evidence["collectionStatus"], "incomplete")
            self.assertTrue((Path(temp) / "performance.json").exists())
        work.cleanup.assert_not_called()
        work._finalizer.detach.assert_called_once()

    def testCancellationWithActiveProviderIsExplicitlyIncomplete(self):
        from unittest.mock import Mock
        client = Mock()
        client.state_preparation_started = True
        client.state.side_effect = collector.Incomplete("candidate-still-connected")
        with tempfile.TemporaryDirectory(prefix="aether-ne-collector-test-") as temp:
            evidence = {"collectionStatus": "complete"}
            collector.finish_collection(client, None, Path(temp), evidence)
            self.assertEqual(evidence["collectionStatus"], "incomplete")
            self.assertIn("network-state-not-restored", evidence["blockingReasons"])


class PeerTests(unittest.TestCase):
    def handler(self, body, role="lan", mode="baseline"):
        handler = peer.Handler.__new__(peer.Handler)
        state = peer.PeerState("a" * 32)
        state.mode = mode
        handler.server = SimpleNamespace(state=state, role=role)
        handler.headers = {"Authorization": "Bearer " + "a" * 32, "Transfer-Encoding": "chunked"}
        handler.path = "/v1/upload?id=" + "b" * 32
        handler.rfile, handler.wfile = io.BytesIO(body), io.BytesIO()
        handler.close_connection = False
        handler.responses = []
        handler.reply = lambda value, status=200: handler.responses.append((status, value))
        return handler

    def testChunkedUploadComputesActualPayloadReceipt(self):
        handler = self.handler(b"3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n")
        handler.do_POST()
        status, receipt = handler.responses[0]
        self.assertEqual(status, 200)
        self.assertEqual(receipt["bytes"], 5)
        self.assertEqual(receipt["sha256"], hashlib.sha256(b"abcde").hexdigest())
        self.assertEqual(receipt["accessPath"], "lan")

    def testCandidateRejectsDirectLANAndAcceptsOnlyRelayPayload(self):
        direct = self.handler(b"1\r\na\r\n0\r\n\r\n", mode="candidate")
        direct.do_POST()
        self.assertEqual(direct.responses[0][0], 409)
        self.assertFalse(direct.server.state.receipts)
        relay = self.handler(b"1\r\na\r\n0\r\n\r\n", role="relay", mode="candidate")
        relay.do_POST()
        self.assertEqual(relay.responses[0][1]["accessPath"], "relay")

    def testBrokenChunkAndWrongTokenNeverProduceReceipt(self):
        for body in (b"9\r\nshort\r\n", b"100001\r\n", b"1\r\naXX"):
            handler = self.handler(body)
            handler.do_POST()
            self.assertTrue(handler.close_connection)
            self.assertFalse(handler.server.state.receipts)
        handler = self.handler(b"0\r\n\r\n")
        handler.headers["Authorization"] = "Bearer wrong"
        handler.do_POST()
        self.assertEqual(handler.responses[0][0], 401)


class HTTPSPeerIntegrationTests(unittest.TestCase):
    def testRealLoopbackTLSReusePayloadReceiptsAndPhaseIsolation(self):
        # Explicitly authorized local protocol smoke, not a NE performance gate.
        # The only listeners are two ephemeral ports on 127.0.0.1. Trust is
        # supplied to this curl invocation; no system keychain is changed.
        class CountingHandler(peer.Handler):
            def setup(self):
                super().setup()
                self.server.nodelay.append(self.connection.getsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY))

        class CountingServer(peer.http.server.ThreadingHTTPServer):
            daemon_threads = True

            def get_request(self):
                request = super().get_request()
                self.accepted += 1
                return request

        with tempfile.TemporaryDirectory(prefix="aether-ne-https-test-") as temp:
            directory = Path(temp)
            config = directory / "certificate.conf"
            config.write_text("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=sample.test\n[ext]\nsubjectAltName=DNS:sample.test,IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\n")
            certificate, key = directory / "certificate.pem", directory / "private-key.pem"
            subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "1",
                            "-config", str(config), "-keyout", str(key), "-out", str(certificate)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
            key.chmod(0o600)
            token = directory / "token"
            token.write_text("t" * 32)
            token.chmod(0o600)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(certificate, key)
            state = peer.PeerState("t" * 32)
            servers = []
            client = None
            try:
                for role in ("lan", "relay"):
                    server = CountingServer(("127.0.0.1", 0), CountingHandler)
                    server.role, server.state = role, state
                    server.accepted, server.nodelay = 0, []
                    server.socket = context.wrap_socket(server.socket, server_side=True)
                    servers.append(server)
                    threading.Thread(target=server.serve_forever, daemon=True).start()
                lan, relay = servers
                args = SimpleNamespace(peer_token_file=token, ca_certificate=certificate,
                                       peer_control_url=f"https://127.0.0.1:{lan.server_port}",
                                       peer_data_url=f"https://sample.test:{lan.server_port}", baseline_address="127.0.0.1",
                                       candidate_address="127.0.0.2")
                client = collector.Collector(args, directory)
                client.verify_peer()
                client.peer_mode("baseline")
                before = lan.accepted
                latency = client.latency("baseline")
                self.assertEqual(len(latency), 200)
                self.assertTrue(all(value > 0 for value in latency))
                self.assertEqual(lan.accepted - before, 1, "All echoes must reuse exactly one TLS connection")
                for direction in ("upload", "download"):
                    actual_metrics = []
                    parse_metric = collector.parse_metric

                    def observe_metric(line):
                        metric = parse_metric(line)
                        actual_metrics.append(metric)
                        return metric

                    with patch.object(collector, "parse_metric", side_effect=observe_metric):
                        measurement = client.transfer("baseline", direction, None)
                    self.assertGreaterEqual(measurement["transferDurationNanoseconds"], 10_000_000_000)
                    self.assertGreater(measurement["bytesReceived"], 0)
                    self.assertEqual(measurement["bytesSent"], measurement["bytesReceived"])
                    self.assertEqual(measurement["sentPayloadSHA256"], measurement["receivedPayloadSHA256"])
                    self.assertFalse(measurement["providerActive"])
                    payload_metrics = [metric for metric in actual_metrics if metric["duration"] == measurement["transferDurationNanoseconds"]]
                    self.assertEqual(len(payload_metrics), 1)
                    if direction == "upload":
                        self.assertGreater(payload_metrics[0]["upload"], measurement["bytesSent"],
                                           "Real curl framing must not inflate the evidence payload count")
                    else:
                        self.assertEqual(payload_metrics[0]["download"], measurement["bytesReceived"])
                    print(f"Loopback HTTPS protocol smoke {direction}: payloadBytes={measurement['bytesSent']} "
                          f"transferDurationNanoseconds={measurement['transferDurationNanoseconds']}; no NE involved.", flush=True)
                client.peer_mode("candidate")
                request_id = "c" * 32
                with self.assertRaises(collector.Incomplete):
                    client.request(args.peer_data_url + "/v1/latency?id=" + request_id, "baseline")
                args.peer_data_url = f"https://sample.test:{relay.server_port}"
                args.candidate_address = "127.0.0.1"  # Local protocol fixture, not an accepted CLI NE target.
                body, _ = client.request(args.peer_data_url + "/v1/latency?id=" + request_id, "candidate")
                self.assertEqual(body["accessPath"], "relay")
                args.peer_data_url = f"https://wrong-hostname.test:{relay.server_port}"
                with self.assertRaises(collector.Incomplete):
                    client.request(args.peer_data_url + "/v1/latency?id=" + request_id, "candidate")
                args.peer_data_url = f"https://sample.test:{relay.server_port}"
                client.header.write_text("Authorization: Bearer wrong\n")
                with self.assertRaises(collector.Incomplete):
                    client.request(args.peer_control_url + "/v1/info")
                client.header.write_text("Authorization: Bearer " + "t" * 32 + "\n")
                # Darwin returns a nonzero flag (currently 4), not necessarily 1.
                self.assertTrue(all(value != 0 for server in servers for value in server.nodelay))
            finally:
                try:
                    if client:
                        client.close()
                finally:
                    for server in servers:
                        server.shutdown()
                        server.server_close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
