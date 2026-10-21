"""Fail closed on shortened acceptance or missing physical runtime evidence.

Physical evidence is bound to the notarized candidate DMG: the Mac mini's
system extensions only load notarized builds, so the QA ZIP cannot run there.
"""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

CANDIDATE_BINARIES = [
    "AetherRoute.app/Contents/MacOS/AetherRoute",
    *(f"AetherRoute.app/Contents/Library/SystemExtensions/com.aetherroute.desktop.{suffix}"
      f".systemextension/Contents/MacOS/com.aetherroute.desktop.{suffix}"
      for suffix in ("tunnel", "transparent-proxy")),
]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_settings():
    env = os.environ
    require(int(env.get("AETHERROUTE_PERF_SECONDS", "300")) >= 300,
            "release performance profiles require at least 300 seconds each")
    require(env.get("AETHERROUTE_RUN_REMOTE_ARM64", "YES") == "YES",
            "remote ARM64 gate cannot be skipped for release acceptance")
    for key, default in [("AETHERROUTE_PERF_PROFILES", "showcase large"),
                         ("AETHERROUTE_MATRIX_ENGINES", "tun transparent"),
                         ("AETHERROUTE_MATRIX_ROUTING", "rule global direct")]:
        actual = env.get(key, default).split()
        require(sorted(actual) == sorted(default.split()), f"{key} must include exactly {default}")


@contextlib.contextmanager
def mounted_dmg(path):
    """Attach a DMG read-only and unbrowsed; always detach afterwards."""
    with tempfile.TemporaryDirectory(prefix="aether-candidate-") as mount:
        subprocess.run(["hdiutil", "attach", str(path), "-readonly", "-nobrowse",
                        "-mountpoint", mount, "-quiet"], check=True, capture_output=True, timeout=120)
        try:
            yield Path(mount)
        finally:
            subprocess.run(["hdiutil", "detach", mount, "-quiet"], capture_output=True, timeout=60)


def read_candidate(path):
    """Return the notarized candidate DMG's build and executable SHA-256s."""
    path = Path(path)
    require(path.suffix == ".dmg" and path.is_file(), f"notarized candidate DMG not found: {path}")
    with mounted_dmg(path) as mount:
        info = plistlib.loads((mount / "AetherRoute.app/Contents/Info.plist").read_bytes())
        missing = [name for name in CANDIDATE_BINARIES if not (mount / name).is_file()]
        require(not missing, f"candidate is missing {', '.join(missing)}")
        hashes = {name: hashlib.sha256((mount / name).read_bytes()).hexdigest() for name in CANDIDATE_BINARIES}
    build = str(info["CFBundleVersion"])
    require(re.fullmatch(r"[0-9]+", build), "invalid candidate build")
    return build, hashes


def verify_output(name, output):
    # Only a verdict line counts: diagnostics may quote these words mid-line.
    # Probe failures also exit nonzero and lack the success line checked below.
    require(not re.search(r"^(?:FAIL|INCONCLUSIVE|SKIP)\b", output, re.MULTILINE), f"{name} did not pass")
    if name == "idle":
        match = re.search(r"both requests answered after (\d+)s idle", output)
        require(match is not None and int(match[1]) >= 50, "idle reuse must cover at least 50 seconds")
    elif name == "upload":
        match = re.search(r"large upload: (\d+) bytes delivered", output)
        require(match is not None and int(match[1]) >= 2_097_152, "upload must deliver at least 2 MiB")
    elif name == "switch":
        require("PASS: interface switch recovered (3 cycles, deadline 15s)" in output,
                "interface switch needs three cycles at the 15-second deadline")
        moves = re.findall(r"cycle (\d+): .+ off -> (en\d+) recovered in (\d+)s", output)
        require(len(moves) == 6, "interface switch needs six successful moves")
        for cycle in ("1", "2", "3"):
            rows = [(device, int(seconds)) for number, device, seconds in moves if number == cycle]
            require(len(rows) == 2 and len({device for device, _ in rows}) == 2
                    and all(seconds <= 15 for _, seconds in rows),
                    f"interface switch cycle {cycle} is incomplete or over budget")


def verify_evidence(directory, build, host, candidate_sha256):
    directory = Path(directory)
    require(re.fullmatch(r"[0-9a-f]{64}", candidate_sha256), "invalid candidate SHA-256")
    for engine in ("tun", "transparent"):
        record = json.loads((directory / f"{engine}.json").read_text())
        expected = {"schema": 1, "build": build, "host": host, "engine": engine,
                    "candidate_sha256": candidate_sha256}
        require(all(record.get(key) == value for key, value in expected.items()),
                f"{engine}: evidence belongs to another candidate, host, or engine")
        for name in ("idle", "upload", "switch"):
            check = record["checks"][name]
            require(type(check["exit_status"]) is int and check["exit_status"] == 0,
                    f"{engine}/{name}: missing successful exit status")
            filename = f"{engine}-{name}.log"
            require(check["log"] == filename, f"{engine}/{name}: unexpected log path")
            data = (directory / filename).read_bytes()
            require(hashlib.sha256(data).hexdigest() == check["sha256"],
                    f"{engine}/{name}: log checksum mismatch")
            verify_output(name, data.decode("utf-8"))


def main():
    try:
        if sys.argv[1:] == ["settings"]:
            verify_settings()
        elif len(sys.argv) == 6 and sys.argv[1] == "evidence":
            verify_evidence(*sys.argv[2:])
        else:
            raise ValueError("usage: verify_parallel_acceptance.py settings"
                             " | evidence DIR BUILD HOST CANDIDATE_DMG_SHA256")
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 1
    print("Acceptance policy verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
