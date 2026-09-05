#!/usr/bin/env python3
"""Collect actual installed NE samples on one explicitly designated test Mac.

No product settings, trust stores, firewall, routes or arbitrary server state
are changed. The operator prepares the selected engine in the normal signed
app and confirms each phase; its state is independently checked.
Only the companion task-owned HTTPS peer receives
phase-control requests. Missing facilities produce pending/incomplete evidence.
"""
import argparse
import csv
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ["scripts/collect_installed_ne_performance.sh", "scripts/collect_installed_ne_performance.py",
           "scripts/installed_ne_performance_peer.py"]
PROTOCOL = "aetherroute-installed-ne-performance-v1"
METRIC = "NE_METRIC:"
WRITE_METRIC = "%{stderr}" + METRIC + "%{http_code}|%{size_download}|%{size_upload}|%{time_total}|%{time_appconnect}|%{ssl_verify_result}|%{num_connects}\n"


class Incomplete(Exception):
    """Only fixed, privacy-safe reason codes are written to evidence."""


def require(condition, reason):
    if not condition:
        raise Incomplete(reason)


def sha_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha_json(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def candidate_identity(manifest):
    """Adapt normal test candidates only for explicitly non-production output."""
    status = manifest.get("releaseStatus")
    require(manifest.get("schemaVersion") == 1 and manifest.get("architecture") == "arm64", "candidate-manifest-invalid")
    diagnostic_collection = status == "notarized-test-candidate"
    if diagnostic_collection:
        core = manifest.get("core", {})
        reference = core.get("protocolReference", {})
        require(core.get("variant") == "normal" and core.get("diagnosticsIncluded") is False
                and manifest.get("safety", {}).get("diagnosticsIncluded") is False
                and reference.get("matchesCandidateArtifacts") is True, "normal-test-core-evidence-required")
        for kind, feature in (("flow", "aether-flow-only"), ("packet", "aether-embedded")):
            artifact = core.get(kind, {})
            digest = artifact.get("artifactSHA256", "")
            require(re.fullmatch(r"[0-9a-f]{64}", digest) is not None and artifact.get("features") == feature
                    and reference.get(kind + "ArtifactSHA256") == digest, "normal-test-core-hash-mismatch")
        require(re.fullmatch(r"[0-9a-f]{64}", reference.get("evidenceSHA256", "")) is not None, "normal-test-protocol-evidence-missing")
        product = manifest.get("signing", {}).get("app", {}).get("bundleID", "")
        source = manifest.get("sourceManifestSHA256", "")
    else:
        require(status == "notarized-candidate", "notarized-normal-candidate-required")
        product = manifest.get("productID", "")
        source = manifest.get("source", {}).get("manifestSHA256", "")
    require(manifest.get("notarization", {}).get("status") == "Accepted", "candidate-notarization-missing")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{2,127}", product) is not None
            and re.fullmatch(r"[0-9a-f]{64}", source) is not None, "candidate-identity-invalid")
    build = manifest.get("build")
    require((type(build) is int and build > 0) or (diagnostic_collection and isinstance(build, str)
            and re.fullmatch(r"[1-9][0-9]*", build) is not None), "candidate-build-invalid")
    normalized = dict(manifest, productID=product, build=int(build), source={"manifestSHA256": source})
    return normalized, diagnostic_collection


def verify_normal_app_bytes(app):
    # Scan the actual archived/installed Mach-O payloads, including frameworks,
    # rather than trusting a manifest's description of its build variant.
    magic_numbers = {bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe",
                                                       "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
    count = 0
    for path in app.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as source:
            prefix = source.read(4)
            if prefix not in magic_numbers:
                continue
            count += 1
            previous = prefix
            for block in iter(lambda: source.read(1024 * 1024), b""):
                sample = previous + block
                require(b"aether_flow stage=" not in sample and b"aether_packet stage=" not in sample,
                        "candidate-contains-diagnostics-core")
                previous = sample[-32:]
    require(count > 0, "candidate-mach-o-unobservable")


def clean_env():
    return {k: v for k, v in os.environ.items() if k.lower() not in ("http_proxy", "https_proxy", "all_proxy", "no_proxy")}


def run(arguments, timeout=30, allow_failure=False):
    try:
        result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env={**clean_env(), "LC_ALL": "C"}, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Incomplete("system-observation-unavailable") from error
    require(allow_failure or result.returncode == 0, "system-command-failed")
    return result


def parse_metric(line):
    require(line.startswith(METRIC), "curl-metrics-missing")
    parts = line[len(METRIC):].strip().split("|")
    require(len(parts) == 7 and all(re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", p) for p in parts), "curl-metrics-invalid")
    code, down, up, seconds, tls, verify, connections = map(Decimal, parts)
    require(code == 200 and verify == 0 and seconds > 0, "https-transfer-failed")
    return {"download": int(down), "upload": int(up), "duration": int(seconds * 1_000_000_000),
            "tls": tls, "connections": int(connections)}


def verify_receipt(receipt, request_id, peer_id, direction, count, digest, role):
    require(type(receipt) is dict and receipt.get("requestID") == request_id and receipt.get("peerID") == peer_id,
            "peer-receipt-identity-mismatch")
    require(receipt.get("direction") == direction and type(receipt.get("bytes")) is int
            and receipt["bytes"] == count and count > 0 and receipt.get("sha256") == digest,
            "peer-payload-integrity-failed")
    require(receipt.get("accessPath") == role and receipt.get("mode") == ("baseline" if role == "lan" else "candidate"),
            "peer-path-attribution-failed")


class NetTopObservation:
    """Observe one actual TCP flow of the candidate, never process totals.

    The peer holds an initial request until this observer sees its flow. Curl
    then reuses that TLS connection for payload and an untimed hold request.
    Ambiguous flows, missing ownership, resets or short deltas fail closed.
    """
    def __init__(self, pid, address, port, direction):
        self.pid, self.address, self.port, self.direction = pid, address, port, direction
        self.header = None
        self.owner = False
        self.flows = {}
        self.lock = threading.Lock()
        self.observed = threading.Event()
        self.process = None
        self.thread = None

    def feed(self, line):
        row = next(csv.reader([line]))
        if "bytes_in" in row and "bytes_out" in row:
            self.header = row
            return
        if self.header is None or len(row) < len(self.header):
            return
        offset = min(self.header.index("bytes_in"), self.header.index("bytes_out"))
        label = " ".join(row[:offset]).strip()
        if re.search(r"(?:[.:])" + str(self.pid) + r"$", label):
            self.owner = True
            return
        if "tcp" not in label.lower():
            if label and not re.fullmatch(r"[0-9:. ]+", label):
                self.owner = False
            return
        if not self.owner or "<->" not in label:
            return
        remote = label.split("<->", 1)[1].strip()
        if remote not in (f"{self.address}:{self.port}", f"{self.address}.{self.port}"):
            return
        field = "bytes_in" if self.direction == "download" else "bytes_out"
        value = row[self.header.index(field)].strip()
        if not re.fullmatch(r"[0-9]+", value):
            return
        with self.lock:
            self.flows.setdefault(label, []).append(int(value))
            self.observed.set()

    def start(self):
        self.process = subprocess.Popen(
            ["/usr/bin/nettop", "-n", "-x", "-L", "0", "-s", "1", "-p", str(self.pid), "-J", "bytes_in,bytes_out"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=clean_env())

        def consume():
            for index, line in enumerate(self.process.stdout):
                if index > 5000:
                    break
                self.feed(line)
        self.thread = threading.Thread(target=consume, daemon=True)
        self.thread.start()

    def stop(self):
        failed = False
        if self.process is not None:
            try:
                if self.process.poll() is None:
                    self.process.terminate()
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    self.process.kill()
                    self.process.wait(timeout=3)
                except (OSError, subprocess.TimeoutExpired):
                    failed = True
            except OSError:
                failed = True
            if self.thread:
                self.thread.join(timeout=3)
                failed = failed or self.thread.is_alive()
            # TextIO.close can wait on a readline lock held by a surviving
            # reader. Preserve an incomplete result instead of blocking here.
            if not self.thread or not self.thread.is_alive():
                try:
                    self.process.stdout.close()
                except OSError:
                    failed = True
        require(not failed, "provider-observer-cleanup-failed")

    def proof(self, count, receipt, lifetime):
        with self.lock:
            require(len(self.flows) == 1, "provider-flow-ambiguous-or-unobservable")
            label, values = next(iter(self.flows.items()))
            require(len(values) >= 2 and all(b >= a for a, b in zip(values, values[1:])), "provider-flow-counter-reset")
            require(values[-1] - values[0] >= count, "provider-flow-bytes-insufficient")
            proof = {"flowSHA256": hashlib.sha256(label.encode()).hexdigest(), "counters": values,
                     "receipt": receipt, "provider": lifetime}
            return values[0], values[-1], sha_json(proof)


class Collector:
    def __init__(self, args, work):
        self.args, self.work = args, Path(work)
        self.peer_id = None
        self.mounted = False
        self.header = self.work / "authorization-header"
        self.header.write_text("Authorization: Bearer " + args.peer_token_file.read_text().strip() + "\n")
        self.header.chmod(0o600)
        self.providers = {}
        self.product = ""
        self.state_preparation_started = False

    def curl_options(self, phase=None):
        result = ["--silent", "--show-error", "--http1.1", "--proxy", "", "--noproxy", "*",
                  "--proto", "=https", "--connect-timeout", "10", "--max-time", "60",
                  "--cacert", str(self.args.ca_certificate), "--header", "@" + str(self.header)]
        if phase == "baseline":
            url = urlsplit(self.args.peer_data_url)
            result += ["--resolve", f"{url.hostname}:{url.port or 443}:{self.args.baseline_address}"]
        return result

    def request(self, url, phase=None, data=None):
        arguments = ["/usr/bin/curl", "-q"] + self.curl_options(phase)
        if data is not None:
            arguments += ["--header", "Content-Type: application/json", "--data-binary", json.dumps(data)]
        arguments += ["--write-out", WRITE_METRIC, url]
        result = run(arguments, timeout=65)
        require(len(result.stdout) <= 16384, "peer-response-too-large")
        lines = result.stderr.decode(errors="replace").splitlines()
        metrics = [parse_metric(line) for line in lines if line.startswith(METRIC)]
        require(len(metrics) == 1 and metrics[0]["tls"] > 0, "https-verification-unavailable")
        try:
            body = json.loads(result.stdout)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise Incomplete("peer-response-invalid") from error
        return body, metrics[0]

    def verify_peer(self):
        info, _ = self.request(self.args.peer_control_url + "/v1/info")
        require(info.get("protocol") == PROTOCOL and info.get("serverSourceSHA256") == sha_file(ROOT / SOURCES[2]),
                "peer-is-not-this-task-owned-server")
        require(re.fullmatch(r"[0-9a-f]{64}", info.get("peerID", "")) is not None, "peer-identity-invalid")
        self.peer_id = info["peerID"]

    def peer_mode(self, mode):
        body, _ = self.request(self.args.peer_control_url + "/v1/mode", data={"mode": mode})
        require(body == {"peerID": self.peer_id, "mode": mode}, "peer-phase-control-failed")

    def signature(self, path):
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)])
        result = run(["/usr/bin/codesign", "-dv", "--verbose=4", str(path)])
        lines = (result.stdout + result.stderr).decode(errors="replace").splitlines()
        values = dict(line.split("=", 1) for line in lines if "=" in line)
        require(any(line.startswith("Authority=Developer ID Application:") for line in lines), "provider-not-developer-id-signed")
        require(re.fullmatch(r"[A-Z0-9]{10}", values.get("TeamIdentifier", "")) is not None
                and re.fullmatch(r"[0-9a-f]{40}", values.get("CDHash", "")) is not None,
                "provider-signature-unobservable")
        return values["TeamIdentifier"], values["CDHash"]

    def candidate(self, manifest):
        require(sha_file(self.args.dmg) == manifest["dmg"]["sha256"], "candidate-dmg-hash-mismatch")
        run(["/usr/bin/xcrun", "stapler", "validate", str(self.args.dmg)], timeout=60)
        self.product = manifest["productID"]
        mount = self.work / "candidate-mount"
        mount.mkdir()
        run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(self.args.dmg)], timeout=60)
        self.mounted = True
        apps = list(mount.glob("*.app"))
        require(len(apps) == 1, "candidate-app-ambiguous")
        archived = apps[0]
        run(["/usr/bin/xcrun", "stapler", "validate", str(archived)], timeout=60)
        require(self.signature(archived) == self.signature(self.args.app), "installed-app-signature-differs")
        for app in (archived, self.args.app):
            verify_normal_app_bytes(app)
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            require(info["CFBundleIdentifier"] == self.product and info["CFBundleShortVersionString"] == manifest["version"]
                    and int(info["CFBundleVersion"]) == manifest["build"], "installed-app-version-differs")
        for engine, suffix in [("tun", ".tunnel"), ("transparent", ".transparent-proxy")]:
            bundle_id = self.product + suffix
            relative = Path("Contents/Library/SystemExtensions") / (bundle_id + ".systemextension")
            old, new = archived / relative, self.args.app / relative
            signatures = [self.signature(path) for path in (old, new)]
            require(signatures[0] == signatures[1], "installed-provider-signature-differs")
            hashes = []
            for provider in (old, new):
                info = plistlib.loads((provider / "Contents/Info.plist").read_bytes())
                require(info["CFBundleIdentifier"] == bundle_id and info["CFBundleShortVersionString"] == manifest["version"]
                        and int(info["CFBundleVersion"]) == manifest["build"], "provider-version-differs")
                hashes.append(sha_file(provider / "Contents/MacOS" / info["CFBundleExecutable"]))
            require(hashes[0] == hashes[1], "installed-provider-executable-differs")
            self.providers[engine] = {"bundleID": bundle_id, "version": manifest["version"], "build": manifest["build"],
                                      "teamID": signatures[0][0], "archivedCDHash": signatures[0][1], "installedCDHash": signatures[1][1],
                                      "archivedExecutableSHA256": hashes[0], "installedExecutableSHA256": hashes[1]}
        require(self.providers["tun"]["teamID"] == self.providers["transparent"]["teamID"], "provider-team-mismatch")

    def lifetime(self, engine):
        expected = self.providers[engine]
        pids = run(["/usr/bin/pgrep", "-x", expected["bundleID"]], allow_failure=True).stdout.decode().split()
        require(len(pids) == 1 and pids[0].isdigit(), "provider-process-not-unique")
        pid = int(pids[0])
        path = run(["/bin/ps", "-p", str(pid), "-o", "comm="]).stdout.decode().strip()
        require(sha_file(path) == expected["installedExecutableSHA256"], "running-provider-executable-differs")
        require(self.signature(path) == (expected["teamID"], expected["installedCDHash"]), "running-provider-signature-differs")
        started = run(["/bin/ps", "-p", str(pid), "-o", "lstart="]).stdout.decode().strip()
        instant = datetime.strptime(started, "%a %b %d %H:%M:%S %Y").astimezone(timezone.utc)
        return {"providerPID": pid, "providerStartedAt": instant.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "providerBundleID": expected["bundleID"], "providerCDHash": expected["installedCDHash"]}

    def transparent_event(self):
        bundle = self.providers["transparent"]["bundleID"]
        pids = run(["/usr/bin/pgrep", "-x", bundle], allow_failure=True).stdout.decode().split()
        if not pids:
            return "stopped"
        life = self.lifetime("transparent")
        predicate = f'processIdentifier == {life["providerPID"]} AND (eventMessage CONTAINS "stage=startProxy" OR eventMessage CONTAINS "stage=stopProxy")'
        started = datetime.strptime(life["providerStartedAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).astimezone()
        logs = run(["/usr/bin/log", "show", "--start", started.strftime("%Y-%m-%d %H:%M:%S"), "--style", "compact", "--info", "--predicate", predicate]).stdout.decode(errors="replace")
        events = re.findall(r"stage=(startProxy|stopProxy) (requested|success|failed)", logs)
        require(bool(events), "transparent-lifecycle-unobservable")
        return "connected" if events[-1] == ("startProxy", "success") else "stopped" if events[-1] == ("stopProxy", "success") else "transitioning"

    def state(self, engine=None):
        tun = run(["/usr/sbin/scutil", "--nc", "status", "AetherRoute"], allow_failure=True).stdout.decode().splitlines()
        tun = tun[0] if tun else "unobservable"
        transparent = self.transparent_event()
        if engine is None:
            require(tun in ("Disconnected", "Invalid") and transparent == "stopped", "baseline-provider-not-disconnected")
            return None
        registrations = run(["/usr/bin/systemextensionsctl", "list"]).stdout.decode()
        expected = self.providers[engine]
        rows = [line for line in registrations.splitlines() if re.search(r"\b" + re.escape(expected["bundleID"]) + r"\s", line)
                and "waiting to uninstall" not in line]
        require(len(rows) == 1 and "[activated enabled]" in rows[0]
                and f'({expected["version"]}/{expected["build"]})' in rows[0], "provider-registration-differs")
        require((tun == "Connected" and transparent == "stopped") if engine == "tun"
                else (tun in ("Disconnected", "Invalid") and transparent == "connected"), "candidate-engine-not-exclusively-connected")
        if engine == "tun":
            route = run(["/sbin/route", "-n", "get", "default"]).stdout.decode()
            require(re.search(r"interface:\s+utun[0-9]+", route) is not None, "tun-default-route-unverified")
        return self.lifetime(engine)

    def prepare(self, engine=None):
        mode = engine or "disconnected"
        require(sys.stdin.isatty(), "interactive-state-preparation-required")
        self.state_preparation_started = True
        input(f"Prepare AetherRoute on this test Mac: {mode}. Press Enter after it settles. ")
        return self.state(engine)

    def latency(self, phase):
        # One curl process, one verified TLS connection, 201 sequential echoes.
        # The warm-up includes DNS/TCP/TLS; the 200 measured requests must reuse
        # that connection, so neither process launch nor TLS setup is timed.
        request_ids = [secrets.token_hex(16) for _ in range(201)]
        config = self.work / "latency-curl-config"
        lines = []
        options = self.curl_options(phase)
        for index, request_id in enumerate(request_ids):
            if index:
                lines.append("next")
            position = 0
            while position < len(options):
                key = options[position][2:]
                position += 1
                if position < len(options) and not options[position].startswith("--"):
                    lines.append(key + " = " + json.dumps(options[position]))
                    position += 1
                else:
                    lines.append(key)
            lines.extend(["write-out = " + json.dumps(WRITE_METRIC),
                          "url = " + json.dumps(self.args.peer_data_url + "/v1/latency?id=" + request_id)])
        config.write_text("\n".join(lines) + "\n")
        config.chmod(0o600)
        try:
            result = run(["/usr/bin/curl", "-q", "--config", str(config)], timeout=240)
        finally:
            config.unlink(missing_ok=True)
        require(len(result.stdout) < 1024 * 1024 and len(result.stderr) < 1024 * 1024, "echo-response-too-large")
        metrics = [parse_metric(line) for line in result.stderr.decode(errors="replace").splitlines() if line.startswith(METRIC)]
        require(len(metrics) == 201 and metrics[0]["tls"] > 0 and metrics[0]["connections"] == 1
                and all(metric["connections"] == 0 for metric in metrics[1:]), "echo-tls-connection-not-reused")
        remaining = result.stdout.decode()
        decoder = json.JSONDecoder()
        for request_id in request_ids:
            body, consumed = decoder.raw_decode(remaining.lstrip())
            remaining = remaining.lstrip()[consumed:]
            require(body == {"requestID": request_id, "peerID": self.peer_id,
                             "accessPath": "lan" if phase == "baseline" else "relay"}, "echo-path-or-identity-mismatch")
        require(not remaining.strip(), "echo-response-count-mismatch")
        return [metric["duration"] for metric in metrics[1:]]

    def transfer(self, phase, direction, life):
        request_id = secrets.token_hex(16)
        observer = NetTopObservation(life["providerPID"], self.args.node_address, self.args.node_port, direction) if life else None
        options = self.curl_options(phase)
        base = self.args.peer_data_url
        arguments = ["/usr/bin/curl", "-q"] + options + ["--output", "/dev/null", "--write-out", "%{stderr}NE_ARM:%{http_code}|%{time_appconnect}|%{ssl_verify_result}\n", base + "/v1/arm?id=" + request_id,
                    "--next"] + options + ["--output", "-", "--write-out", WRITE_METRIC]
        if direction == "upload":
            arguments += ["--request", "POST", "--upload-file", "-", "--header", "Expect:"]
        arguments += [base + "/v1/" + direction + "?seconds=10&id=" + request_id,
                      "--next"] + options + ["--output", "/dev/null", "--write-out", "", base + "/v1/hold?id=" + request_id]
        armed = threading.Event()
        timing = {}
        metrics, thread_errors = [], []
        digest = hashlib.sha256()
        count = [0]
        response = bytearray()
        process = None

        def upload():
            if not armed.wait(25):
                thread_errors.append("payload-arm-timeout")
                return
            block = os.urandom(65536)
            # Allow the next curl operation to begin after the arm marker;
            # every accepted *measured* transfer must still span at least 10 s.
            deadline = time.monotonic() + 10.25
            try:
                while time.monotonic() < deadline:
                    pending = memoryview(block)
                    while pending:
                        wrote = process.stdin.write(pending)
                        if not wrote:
                            raise BrokenPipeError()
                        digest.update(pending[:wrote])
                        count[0] += wrote
                        pending = pending[wrote:]
                process.stdin.close()
            except (OSError, ValueError):
                thread_errors.append("upload-stream-failed")

        def output():
            for block in iter(lambda: process.stdout.read(65536), b""):
                if direction == "download":
                    digest.update(block)
                    count[0] += len(block)
                elif len(response) + len(block) <= 16384:
                    response.extend(block)
                else:
                    thread_errors.append("upload-response-too-large")

        def errors():
            for raw in process.stderr:
                line = raw.decode(errors="replace").strip()
                try:
                    if line.startswith("NE_ARM:"):
                        parts = line[len("NE_ARM:"):].split("|")
                        require(len(parts) == 3 and parts[0] == "200" and Decimal(parts[1]) > 0 and parts[2] == "0",
                                "armed-tls-connection-not-verified")
                        armed.set()
                    elif line.startswith(METRIC):
                        timing["end"] = time.monotonic_ns()
                        metrics.append(parse_metric(line))
                except (Incomplete, ArithmeticError):
                    thread_errors.append("transfer-metrics-invalid")
                    armed.set()

        try:
            if observer:
                observer.start()
            # These monotonic timestamps enclose observation/setup and payload.
            # Only curl's payload time_total is used as the throughput divisor.
            timing["start"] = time.monotonic_ns()
            process = subprocess.Popen(arguments, stdin=subprocess.PIPE if direction == "upload" else subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=clean_env(), bufsize=0)
            threads = [threading.Thread(target=output, daemon=True), threading.Thread(target=errors, daemon=True)]
            if direction == "upload":
                threads.append(threading.Thread(target=upload, daemon=True))
            for thread in threads:
                thread.start()
            if observer:
                require(observer.observed.wait(10), "provider-flow-unobservable-before-payload")
            # A task-owned peer arm is released only after its candidate socket
            # is observed. Baseline also arms, but has no provider to observe.
            released = False
            for _ in range(20):
                try:
                    released_body, _ = self.request(self.args.peer_control_url + "/v1/release?id=" + request_id)
                    require(released_body == {"requestID": request_id}, "peer-arm-identity-mismatch")
                    released = True
                    break
                except Incomplete:
                    time.sleep(0.1)
            require(released, "peer-arm-not-released")
            process.wait(timeout=55)
            for thread in threads:
                thread.join(timeout=5)
            require(not any(thread.is_alive() for thread in threads) and not thread_errors and process.returncode == 0,
                    "transfer-process-or-stream-failed")
            require(len(metrics) == 1 and set(timing) == {"start", "end"}, "transfer-timing-unobservable")
            metric = metrics[0]
            require(metric["connections"] == 0, "payload-not-on-observed-tls-connection")
            # curl size_upload includes HTTP chunk framing for this streaming
            # upload. Payload bytes are counted/hash-checked independently at
            # both ends below; framing never enters the throughput numerator.
            require((metric["upload"] >= count[0] if direction == "upload" else metric["download"] == count[0]),
                    "curl-payload-byte-count-mismatch")
            require(timing["end"] - timing["start"] >= metric["duration"] >= 10_000_000_000,
                    "transfer-duration-too-short")
            receipt, _ = self.request(self.args.peer_control_url + "/v1/receipt?id=" + request_id)
            verify_receipt(receipt, request_id, self.peer_id, direction, count[0], digest.hexdigest(), "lan" if phase == "baseline" else "relay")
            sent_count, received_count = (receipt["bytes"], count[0]) if direction == "download" else (count[0], receipt["bytes"])
            sent_hash, received_hash = (receipt["sha256"], digest.hexdigest()) if direction == "download" else (digest.hexdigest(), receipt["sha256"])
            result = {"bytesSent": sent_count, "bytesReceived": received_count, "sentPayloadSHA256": sent_hash,
                      "receivedPayloadSHA256": received_hash, "startedMonotonicNanoseconds": timing["start"],
                      "endedMonotonicNanoseconds": timing["end"], "transferDurationNanoseconds": metric["duration"],
                      "providerActive": life is not None,
                      "peerIdentitySHA256": hashlib.sha256(self.peer_id.encode()).hexdigest()}
            if observer:
                before, after, proof = observer.proof(count[0], receipt, life)
                result.update(life)
                result.update(providerObservedBytesBefore=before, providerObservedBytesAfter=after,
                              counterSource="nettop-process", pathAttribution="provider-flow-observed",
                              providerFlowObservationSHA256=proof)
            return result
        finally:
            armed.set()
            cleanup_failed = False
            if process is not None:
                try:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    cleanup_failed = True
                for stream in (process.stdin, process.stdout, process.stderr):
                    try:
                        if stream and not stream.closed:
                            stream.close()
                    except OSError:
                        cleanup_failed = True
            if observer:
                try:
                    observer.stop()
                except (Incomplete, OSError, subprocess.TimeoutExpired):
                    cleanup_failed = True
            require(not cleanup_failed, "transfer-process-cleanup-failed")

    def close(self):
        failed = False
        if self.peer_id is not None:
            try:
                self.peer_mode("baseline")
            except (Incomplete, OSError):
                failed = True
        if self.mounted:
            try:
                run(["/usr/bin/hdiutil", "detach", str(self.work / "candidate-mount")], timeout=30)
                self.mounted = False
            except (Incomplete, OSError):
                failed = True
        require(not failed, "peer-restoration-or-dmg-detach-failed")


def write_evidence(directory, evidence):
    payload = (json.dumps(evidence, indent=2, sort_keys=True) + "\n").encode()
    (directory / "performance.json").write_bytes(payload)
    (directory / "SHA256SUMS").write_text(hashlib.sha256(payload).hexdigest() + "  performance.json\n")


def finish_collection(client, work, directory, evidence):
    # Cleanup operations are independent: a failed peer reset cannot prevent a
    # DMG detach, and a failed temporary-directory removal cannot erase the
    # auditable pending/incomplete result.
    if client:
        try:
            client.close()
        except (Incomplete, OSError, subprocess.TimeoutExpired):
            evidence["collectionStatus"] = "incomplete"
            evidence.setdefault("blockingReasons", []).append("peer-restoration-or-dmg-detach-failed")
        if getattr(client, "state_preparation_started", False) is True:
            try:
                client.state()
            except (Incomplete, OSError, subprocess.TimeoutExpired):
                evidence["collectionStatus"] = "incomplete"
                evidence.setdefault("blockingReasons", []).append("network-state-not-restored")
                print("Network disconnection is not confirmed. Disconnect AetherRoute in the test Mac's app before leaving the test.", file=sys.stderr)
    if work:
        try:
            if client and client.mounted:
                work._finalizer.detach()
                evidence["collectionStatus"] = "incomplete"
                evidence.setdefault("blockingReasons", []).append("candidate-dmg-remains-mounted")
            else:
                work.cleanup()
        except OSError:
            work._finalizer.detach()
            evidence["collectionStatus"] = "incomplete"
            evidence.setdefault("blockingReasons", []).append("temporary-work-cleanup-failed")
    try:
        write_evidence(directory, evidence)
    except OSError:
        evidence["collectionStatus"] = "incomplete"
        print("Could not persist complete checksummed evidence; production remains blocked.", file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dmg", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--app", type=Path, default=Path("/Applications/AetherRoute.app"))
    parser.add_argument("--authorize-network", action="store_true")
    parser.add_argument("--designated-test-host")
    parser.add_argument("--peer-control-url")
    parser.add_argument("--peer-data-url")
    parser.add_argument("--baseline-address")
    parser.add_argument("--node-address")
    parser.add_argument("--node-port", type=int)
    parser.add_argument("--peer-token-file", type=Path)
    parser.add_argument("--ca-certificate", type=Path)
    args = parser.parse_args(argv)
    if not args.output.is_absolute() or args.output.exists() or args.output.is_symlink():
        parser.error("output must be a new absolute directory")
    args.output.mkdir(mode=0o700, parents=True)
    evidence = {"schemaVersion": 1, "surface": "installed-network-extension", "collectionStatus": "pending", "blockingReasons": []}
    collector = None
    work = None
    try:
        require(args.authorize_network, "explicit-network-authorization-missing")
        require(args.designated_test_host == socket.gethostname(), "designated-test-host-not-confirmed")
        require(platform.system() == "Darwin" and platform.machine() == "arm64", "designated-arm64-mac-required")
        require(all((args.peer_control_url, args.peer_data_url, args.baseline_address, args.node_address, args.node_port,
                     args.peer_token_file, args.ca_certificate)), "controlled-peer-inputs-missing")
        for value in (args.baseline_address, args.node_address):
            address = ipaddress.ip_address(value)
            require(address.version == 4 and address.is_private and not address.is_loopback and not address.is_unspecified,
                    "controlled-lan-address-required")
        control, data = urlsplit(args.peer_control_url), urlsplit(args.peer_data_url)
        require(all(url.scheme == "https" and not url.username and not url.password and url.path in ("", "/")
                    and not url.query and not url.fragment for url in (control, data)), "controlled-https-base-url-required")
        require(control.hostname == args.baseline_address and isinstance(data.hostname, str)
                and data.hostname.endswith(".test") and control.port == data.port,
                "same-controlled-peer-topology-required")
        require(re.fullmatch(r"[A-Za-z0-9.-]{1,253}", data.hostname) is not None, "test-peer-hostname-invalid")
        args.peer_control_url = args.peer_control_url.rstrip("/")
        args.peer_data_url = args.peer_data_url.rstrip("/")
        require(1024 <= args.node_port <= 65535, "unprivileged-controlled-node-port-required")
        for path in (args.dmg, args.manifest, args.app, args.peer_token_file, args.ca_certificate):
            require(path.is_absolute() and path.exists(), "required-absolute-input-missing")
        token = args.peer_token_file.read_text().strip()
        require(re.fullmatch(r"[A-Za-z0-9_-]{32,128}", token) is not None, "peer-token-file-invalid")
        manifest, diagnostic_collection = candidate_identity(json.loads(args.manifest.read_bytes()))
        budget_path = ROOT / "Config/InstalledNEPerformanceBudget.json"
        budget = json.loads(budget_path.read_bytes())
        require(budget["collectorSources"] == SOURCES, "collector-source-policy-differs")
        evidence = {"schemaVersion": 1, "collectionStatus": "incomplete", "surface": "installed-network-extension",
                    "candidate": {"dmgSHA256": sha_file(args.dmg), "manifestSHA256": sha_file(args.manifest),
                                  "sourceManifestSHA256": manifest["source"]["manifestSHA256"], "productID": manifest["productID"],
                                  "version": manifest["version"], "build": manifest["build"]},
                    "collectorSources": {name: sha_file(ROOT / name) for name in SOURCES}, "budgetSHA256": sha_file(budget_path),
                    "machine": {"architecture": platform.machine(), "model": run(["/usr/sbin/sysctl", "-n", "hw.model"]).stdout.decode().strip(),
                                "macOSBuild": run(["/usr/bin/sw_vers", "-buildVersion"]).stdout.decode().strip(),
                                "hostNameSHA256": hashlib.sha256(socket.gethostname().encode()).hexdigest()}, "samples": []}
        work = tempfile.TemporaryDirectory(prefix="aether-installed-ne-performance-")
        collector = Collector(args, work.name)
        collector.candidate(manifest)
        collector.verify_peer()
        evidence["providers"] = collector.providers
        evidence["topology"] = {"kind": "controlled-peer", "transport": "tcp", "baseline": "same-peer-provider-disconnected",
                                "peerIdentitySHA256": hashlib.sha256(collector.peer_id.encode()).hexdigest(), "internetPath": False}
        for engine in ("tun", "transparent"):
            for direction in ("upload", "download"):
                for index in range(5):
                    pair = {"engine": engine, "direction": direction, "pairIndex": index}
                    for role in ("baseline", "candidate"):
                        life = collector.prepare(engine if role == "candidate" else None)
                        collector.peer_mode(role)
                        latency = collector.latency(role)
                        require(collector.state(engine if life else None) == life, "provider-changed-during-latency")
                        measurement = collector.transfer(role, direction, life)
                        require(collector.state(engine if life else None) == life, "provider-changed-during-transfer")
                        measurement["latencyNanoseconds"] = latency
                        pair[role] = measurement
                    evidence["samples"].append(pair)
                    write_evidence(args.output, evidence)
                    print(f"Collected {engine}/{direction} pair {index + 1}/5; no performance verdict assigned.", flush=True)
        collector.prepare(None)
        if diagnostic_collection:
            evidence["collectionStatus"] = "pending"
            evidence["blockingReasons"] = ["normal-test-candidate-is-calibration-only"]
        else:
            evidence["collectionStatus"] = "complete"
    except (Incomplete, OSError, ValueError, KeyError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        evidence["blockingReasons"] = [str(error) if isinstance(error, Incomplete) else "collection-interrupted-or-input-unreadable"]
    finally:
        finish_collection(collector, work, args.output, evidence)
    print("Installed NE collection: " + evidence["collectionStatus"] + ". Production still requires reviewed calibration and independent validation.")
    return 0 if evidence["collectionStatus"] == "complete" else 78


if __name__ == "__main__":
    def interrupt(_number, _frame):
        raise KeyboardInterrupt()
    for interruption in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(interruption, interrupt)
    sys.exit(main())
