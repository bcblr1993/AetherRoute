#!/usr/bin/env python3
"""Bounded HTTPS phase probe for a task-owned relay; no product trust changes.

Preparation only: the signed XCTest/coordinator must separately bind the helper,
candidate, provider lifetime, node receipt, phase order and recovery lease.
This helper proves only an individual HTTPS observation, never a release gate.
"""
import argparse
import ctypes
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import time

PROTOCOL = "aetherroute-installed-ne-performance-v1"
SCHEMA = "controlled-relay-phase-v1"
PHASES = ("before", "connected", "after")
ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"}
MARKER = b"\nAETHER_PHASE_METRIC "
PRIVATE_NETWORKS = tuple(ipaddress.ip_network(x) for x in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
TEST_NETWORKS = tuple(ipaddress.ip_network(x) for x in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"))


class ProbeError(Exception):
    pass


def require(value, reason):
    if not value:
        raise ProbeError(reason)


def monotonic_ns():
    # Python 3.9 on macOS subtracts a process-local origin. Swift and separate
    # lease workers need the same boot-relative clock, so read Mach directly.
    if sys.platform != "darwin":
        return time.monotonic_ns()
    return _mach_clock.mach_absolute_time() * _mach_timebase.numer // _mach_timebase.denom


if sys.platform == "darwin":
    class _MachTimebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
    _mach_clock = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    _mach_clock.mach_absolute_time.argtypes = []
    _mach_clock.mach_absolute_time.restype = ctypes.c_uint64
    _mach_clock.mach_timebase_info.argtypes = [ctypes.POINTER(_MachTimebase)]
    _mach_clock.mach_timebase_info.restype = ctypes.c_int
    _mach_timebase = _MachTimebase()
    require(_mach_clock.mach_timebase_info(ctypes.byref(_mach_timebase)) == 0 and
            _mach_timebase.numer > 0 and _mach_timebase.denom > 0, "shared-monotonic-clock-unavailable")


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def strict_json(raw):
    def pairs(rows):
        value = {}
        for key, item in rows:
            require(key not in value, "duplicate-json-key")
            value[key] = item
        return value
    try:
        return json.loads(raw, object_pairs_hook=pairs)
    except (ValueError, UnicodeError) as error:
        raise ProbeError("malformed-json") from error


def validate_plan(plan):
    fields = {"schemaVersion", "runID", "engine", "cycle", "candidateManifestSHA256", "peerID",
              "peerSourceSHA256", "hostname", "port", "controlAddress", "dataAddress", "requestID",
              "token", "certificateSHA256"}
    require(type(plan) is dict and set(plan) == fields, "plan-fields-invalid")
    require(type(plan["schemaVersion"]) is int and plan["schemaVersion"] == 1, "plan-schema-invalid")
    require(plan["engine"] in ("tun", "transparent"), "plan-engine-invalid")
    require(type(plan["cycle"]) is int and 1 <= plan["cycle"] <= 20, "plan-cycle-invalid")
    require(type(plan["port"]) is int and 1024 <= plan["port"] <= 65535, "plan-port-invalid")
    for key, length in (("runID", 32), ("requestID", 32), ("candidateManifestSHA256", 64),
                        ("peerID", 64), ("peerSourceSHA256", 64), ("certificateSHA256", 64)):
        require(type(plan[key]) is str and re.fullmatch("[0-9a-f]{%d}" % length, plan[key]), "plan-identity-invalid")
    require(plan["hostname"] == "aether-performance.test", "plan-hostname-invalid")
    require(type(plan["token"]) is str and re.fullmatch(r"[A-Za-z0-9_-]{32,128}", plan["token"]), "plan-token-invalid")
    for key, networks in (("controlAddress", PRIVATE_NETWORKS), ("dataAddress", TEST_NETWORKS)):
        try:
            address = ipaddress.ip_address(plan[key])
        except (ValueError, TypeError) as error:
            raise ProbeError("plan-address-invalid") from error
        require(type(plan[key]) is str and address.version == 4 and str(address) == plan[key] and
                any(address in network and address not in (network.network_address, network.broadcast_address)
                    for network in networks), "plan-address-outside-test-topology")
    return plan


class PrivateInputs:
    def __init__(self, stage, expected_plan_sha):
        require(type(expected_plan_sha) is str and re.fullmatch(r"[0-9a-f]{64}", expected_plan_sha), "plan-hash-invalid")
        self.path = Path(stage)
        require(re.fullmatch(r"/private/tmp/aether-ne-probe\.[0-9a-f]{32}", str(self.path)), "stage-path-invalid")
        self.fd = os.open(str(self.path), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(self.fd)
            require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700,
                    "stage-ownership-invalid")
            raw = self.read("plan.json", 8192)
            require(digest(raw) == expected_plan_sha, "plan-hash-mismatch")
            self.plan = validate_plan(strict_json(raw))
            self.plan_sha = expected_plan_sha
            self.certificate()
        except BaseException:
            os.close(self.fd)
            raise

    def read(self, name, limit):
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.fd)
        try:
            info = os.fstat(fd)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1 and
                    stat.S_IMODE(info.st_mode) == 0o600 and 0 < info.st_size <= limit, "private-input-invalid")
            with os.fdopen(fd, "rb", closefd=False) as stream:
                raw = stream.read(limit + 1)
            require(len(raw) <= limit, "private-input-too-large")
            return raw
        finally:
            os.close(fd)

    def certificate(self):
        raw = self.read("server-cert.pem", 65536)
        require(digest(raw) == self.plan["certificateSHA256"], "certificate-hash-mismatch")
        # Curl opens this exact path; reject moving/replacing the stage while a
        # descriptor for the original directory remains valid.
        current = os.lstat(str(self.path))
        opened = os.fstat(self.fd)
        require(current.st_ino == opened.st_ino and current.st_dev == opened.st_dev and
                stat.S_ISDIR(current.st_mode), "stage-replaced")
        return str(self.path / "server-cert.pem")

    def close(self):
        os.close(self.fd)


def bounded_process(arguments, payload, timeout=8, output_limit=66560, error_limit=8192):
    """Drain both pipes while running; cancellation reaps only this child group."""
    require(len(payload) <= 8192, "curl-config-too-large")
    process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=ENV, close_fds=True, start_new_session=True)
    output, errors = bytearray(), bytearray()
    deadline = time.monotonic() + timeout
    selector = selectors.DefaultSelector()
    try:
        os.set_blocking(process.stdin.fileno(), False)
        selector.register(process.stdin, selectors.EVENT_WRITE, "input")
        for pipe, name in ((process.stdout, "output"), (process.stderr, "errors")):
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, name)
        pending = memoryview(payload)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            require(remaining > 0, "curl-process-deadline")
            for key, _ in selector.select(min(remaining, .1)):
                if key.data == "input":
                    try:
                        pending = pending[os.write(key.fd, pending):]
                    except BrokenPipeError:
                        pending = memoryview(b"")
                    if not pending:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                    continue
                try:
                    block = os.read(key.fd, 16384)
                except BlockingIOError:
                    continue
                if not block:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                destination, limit = (output, output_limit) if key.data == "output" else (errors, error_limit)
                require(len(destination) + len(block) <= limit, "curl-output-limit")
                destination.extend(block)
        require(process.wait(timeout=max(.001, deadline - time.monotonic())) >= 0, "curl-terminated-by-signal")
        return process.returncode, bytes(output), bytes(errors)
    except subprocess.TimeoutExpired as error:
        raise ProbeError("curl-process-deadline") from error
    finally:
        selector.close()
        # A child may exit while its descendants retain a pipe. The private
        # process group still belongs to this invocation and must be reaped.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)
        for pipe in (process.stdin, process.stdout, process.stderr):
            pipe.close()


def parse_response(code, raw, error_bytes):
    body, found, metrics = raw.rpartition(MARKER)
    require(found and len(body) <= 65536 and len(metrics) <= 256, "curl-metrics-missing-or-large")
    match = re.fullmatch(rb"([0-9]{3}) ([0-9]{1,5}) ([0-9]{1,5}) ([0-9]+(?:\.[0-9]+)?) \[([0-9.]*)\]", metrics)
    require(match is not None, "curl-metrics-malformed")
    status, tls, size = (int(match.group(i)) for i in (1, 2, 3))
    seconds = float(match.group(4))
    require(math.isfinite(seconds) and 0 <= seconds <= 8 and size == len(body), "curl-metrics-invalid")
    result = {"curlExitCode": code, "httpStatus": status, "tlsVerifyResult": tls,
              "responseBytes": size, "responseSHA256": digest(body), "curlNanoseconds": round(seconds * 1e9),
              "errorOutputSHA256": digest(error_bytes)}
    return result, body, match.group(5).decode()


def curl_request(plan, certificate, path, control):
    require(path == "/v1/info" or path == "/v1/latency?id=" + plan["requestID"], "probe-path-invalid")
    address = plan["controlAddress"] if control else plan["dataAddress"]
    options = ["silent", "show-error", "http1.1", "ipv4", "connect-timeout = 3", "max-time = 5", "max-filesize = 65536",
               'proxy = ""', 'noproxy = "*"', 'proto = "=https"', "max-redirs = 0",
               "cacert = " + json.dumps(certificate),
               "url = " + json.dumps("https://%s:%d%s" % (plan["hostname"], plan["port"], path)),
               "resolve = " + json.dumps("%s:%d:%s" % (plan["hostname"], plan["port"], address)),
               "header = " + json.dumps("Authorization: Bearer " + plan["token"]),
               'header = "Cache-Control: no-store"',
               'write-out = "\\nAETHER_PHASE_METRIC %{http_code} %{ssl_verify_result} %{size_download} %{time_total} [%{remote_ip}]"']
    return parse_response(*bounded_process(["/usr/bin/curl", "-q", "--config", "-"], ("\n".join(options) + "\n").encode()))


def health(plan, response):
    result, body, address = response
    require(result["curlExitCode"] == 0 and result["httpStatus"] == 200 and result["tlsVerifyResult"] == 0 and
            address == plan["controlAddress"], "peer-health-transport-failed")
    require(strict_json(body) == {"protocol": PROTOCOL, "peerID": plan["peerID"],
                                  "serverSourceSHA256": plan["peerSourceSHA256"]}, "peer-health-identity-failed")
    return digest(canonical(result))


def observe(inputs, phase, request=curl_request):
    require(phase in PHASES, "phase-invalid")
    plan = inputs.plan
    started = monotonic_ns()
    before = health(plan, request(plan, inputs.certificate(), "/v1/info", True))
    request_started = monotonic_ns()
    result, body, address = request(plan, inputs.certificate(), "/v1/latency?id=" + plan["requestID"], False)
    request_finished = monotonic_ns()
    after = health(plan, request(plan, inputs.certificate(), "/v1/info", True))
    inputs.certificate()
    expected = json.dumps({"requestID": plan["requestID"], "peerID": plan["peerID"],
                           "accessPath": "relay"}, separators=(",", ":")).encode()
    if phase == "connected":
        require(result["curlExitCode"] == 0 and result["httpStatus"] == 200 and result["tlsVerifyResult"] == 0 and
                body == expected and address == plan["dataAddress"], "connected-relay-response-mismatch")
        outcome = "matched"
    else:
        # DNS/TLS/HTTP/auth/malformed responses never count as an expected
        # unavailable path. Coordinator additionally verifies zero node receipt.
        require(result["curlExitCode"] in (7, 28) and result["httpStatus"] == 0 and result["tlsVerifyResult"] == 0 and
                not body and address in ("", plan["dataAddress"]), "disconnected-path-not-proven-unreachable")
        outcome = "unreachable"
    return {"schema": SCHEMA, "runID": plan["runID"], "engine": plan["engine"], "cycle": plan["cycle"], "phase": phase,
            "planSHA256": inputs.plan_sha, "candidateManifestSHA256": plan["candidateManifestSHA256"],
            "requestIdentitySHA256": digest(plan["requestID"].encode()), "peerIdentitySHA256": digest(plan["peerID"].encode()),
            "expectedResponseSHA256": digest(expected), "healthBeforeSHA256": before, "healthAfterSHA256": after,
            "startedMonotonicNS": started, "requestStartedMonotonicNS": request_started,
            "requestFinishedMonotonicNS": request_finished, "completedMonotonicNS": monotonic_ns(),
            "outcome": outcome, "observation": result}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage")
    parser.add_argument("plan_sha256")
    parser.add_argument("phase", choices=PHASES)
    args = parser.parse_args(argv)
    inputs = None
    try:
        inputs = PrivateInputs(args.stage, args.plan_sha256)
        receipt = observe(inputs, args.phase)
        sys.stdout.buffer.write(canonical(receipt) + b"\n")
        return 0
    except (ProbeError, OSError, ValueError, KeyboardInterrupt) as error:
        reason = str(error) if isinstance(error, ProbeError) else "probe-interrupted-or-input-unreadable"
        print("controlled-probe-error=" + reason, file=sys.stderr)
        return 78
    finally:
        if inputs is not None:
            inputs.close()


if __name__ == "__main__":
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt()
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    sys.exit(main())
