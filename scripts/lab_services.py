#!/usr/bin/env python3
"""Test-only Linux lab supervisor and AWG adapter. Never bundled with the app."""
import base64
import gzip
import hashlib
import hmac
import io
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import zipfile

ROOT = Path("/opt/aether-lab")
# Fixed official release assets; validated before extraction/execution.
ASSETS = {
    "xray": ("https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip",
             "23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"),
    "mihomo": ("https://github.com/MetaCubeX/mihomo/releases/download/v1.19.29/mihomo-linux-amd64-v1.19.29.gz",
               "60de76a35a6cbf7b4fa4a20f5c257c24345d1d635ab1aa3877022a1997ef413c"),
    "tuic4": ("https://github.com/EAimty/tuic/releases/download/0.8.5/tuic-server-0.8.5-x86_64-linux-gnu",
              "29e58e8527b7511bcf9f5719a5d292ae07e2ae0d972320ae0992c613c8abab86"),
    "ssr": ("https://github.com/shadowsocksrr/shadowsocksr/archive/b365980a82d7309f4ed368c6bd958ee080cdd37b.tar.gz",
            "63f1578f0efbfccc3f82d684bbf0ada276d5c04c6b8aad33f0e9d9e4d8573a3f"),
}


def install():
    for name, (url, digest) in ASSETS.items():
        cache = ROOT / (name + ".asset")
        if not cache.exists() or hashlib.sha256(cache.read_bytes()).hexdigest() != digest:
            with urllib.request.urlopen(url, timeout=120) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError(f"{name}: official asset checksum mismatch")
            cache.write_bytes(data)
        data = cache.read_bytes()
        if name == "ssr":
            dest = ROOT / "ssr"
            dest.mkdir(exist_ok=True)
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                for member in archive.getmembers():
                    parts = Path(member.name).parts[1:]
                    if not parts or member.issym() or member.islnk():
                        continue
                    member.name = str(Path(*parts))
                    archive.extract(member, dest, filter="data")
        else:
            if name == "xray":
                data = zipfile.ZipFile(io.BytesIO(data)).read("xray")
            elif name == "mihomo":
                data = gzip.decompress(data)
            path = ROOT / name
            # Linux refuses to truncate a running executable (ETXTBSY).
            # Keep an unchanged inode, or atomically publish a verified new one.
            if path.is_file() and path.read_bytes() == data:
                continue
            descriptor, temporary = tempfile.mkstemp(prefix=f".{name}-", dir=ROOT)
            temporary = Path(temporary)
            try:
                with os.fdopen(descriptor, "wb") as output:
                    output.write(data)
                    output.flush()
                    os.fsync(output.fileno())
                temporary.chmod(0o755)
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
    print("Pinned lab servers installed")


def supervise():
    children, logs = [], []
    def stop(*_):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        for service in json.loads((ROOT / "services.json").read_text()):
            log = open(ROOT / (service["name"] + ".log"), "ab", buffering=0)
            logs.append(log)
            children.append(subprocess.Popen(service["argv"], stdout=log, stderr=log, cwd=ROOT))
        while True:
            for i, child in enumerate(children):
                if child.poll() is not None:
                    # Do not echo command lines: some servers use credential arguments.
                    raise RuntimeError(f"lab service {i} exited with {child.returncode}")
            time.sleep(1)
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
        for child in children:
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        for log in logs:
            log.close()


def awg_transform(data, options, public_key, outbound=False):
    """Independent test adapter: validate MAC1 and translate WG wire headers."""
    key = hashlib.blake2s(b"mac1----" + base64.b64decode(public_key)).digest()
    for typ, size, offset, pad in ((1, 148, 116, options["s1"]), (2, 92, 60, options["s2"]),
                                   (3, 64, None, 0), (4, None, None, 0)):
        header = typ if outbound else options[f"h{typ}"]
        body = data if outbound else data[pad:]
        if len(body) < 4 or struct.unpack("<I", body[:4])[0] != header:
            continue
        if (size is not None and len(body) != size) or (typ == 4 and len(body) < 32):
            continue
        if offset is not None and not hmac.compare_digest(
                body[offset:offset + 16], hashlib.blake2s(body[:offset], key=key, digest_size=16).digest()):
            return None
        result = bytearray(body)
        result[:4] = struct.pack("<I", options[f"h{typ}"] if outbound else typ)
        if offset is not None:
            result[offset:offset + 16] = hashlib.blake2s(result[:offset], key=key, digest_size=16).digest()
        return (os.urandom(pad) if outbound else b"") + result
    return None


def awg(config_path):
    config = json.loads(Path(config_path).read_text())
    front = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    front.bind(("0.0.0.0", config["port"]))
    selector = selectors.DefaultSelector()
    selector.register(front, selectors.EVENT_READ, None)
    peers = {}
    try:
        while True:
            for event, _ in selector.select(timeout=10):
                sock, client = event.fileobj, event.data
                if client is None:
                    data, client = front.recvfrom(65535)
                    plain = awg_transform(data, config["options"], config["server_public"])
                    if plain is None:
                        continue
                    if client not in peers:
                        back = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                        back.connect(("127.0.0.1", config["backend"]))
                        selector.register(back, selectors.EVENT_READ, client)
                        peers[client] = [back, time.monotonic()]
                    peers[client][1] = time.monotonic()
                    peers[client][0].send(plain)
                else:
                    data = sock.recv(65535)
                    wire = awg_transform(data, config["options"], config["client_public"], outbound=True)
                    if wire is not None:
                        front.sendto(wire, client)
            for client, (back, seen) in list(peers.items()):
                if time.monotonic() - seen > 300:
                    selector.unregister(back)
                    back.close()
                    del peers[client]
    finally:
        for back, _ in peers.values():
            back.close()
        front.close()
        selector.close()


if __name__ == "__main__":
    if sys.argv[1] == "install":
        install()
    elif sys.argv[1] == "supervise":
        supervise()
    elif sys.argv[1] == "awg":
        awg(sys.argv[2])
