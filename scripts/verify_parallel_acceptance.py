"""Fail closed on shortened acceptance or missing physical runtime evidence."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import sys
import zipfile

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


def candidate_build(path):
    """Return the archive's CFBundleVersion after checking its binaries exist."""
    with zipfile.ZipFile(path) as archive:
        info = plistlib.loads(archive.read("AetherRoute.app/Contents/Info.plist"))
        names = set(archive.namelist())
    build = str(info["CFBundleVersion"])
    require(re.fullmatch(r"[0-9]+", build), "invalid candidate build")
    missing = [name for name in CANDIDATE_BINARIES if name not in names]
    require(not missing, f"candidate is missing {', '.join(missing)}")
    return build


def verify_candidate(path, build):
    # A reused candidate must be the exact archive later bound into evidence.
    require(path.startswith("/"), "reused candidate path must be absolute")
    require(Path(path).is_file() and path.endswith(".zip"), f"reused candidate not found: {path}")
    actual = candidate_build(path)
    require(actual == build, f"reused candidate is build {actual}, expected {build}")


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
        elif len(sys.argv) == 4 and sys.argv[1] == "candidate":
            verify_candidate(*sys.argv[2:])
        elif len(sys.argv) == 6 and sys.argv[1] == "evidence":
            verify_evidence(*sys.argv[2:])
        else:
            raise ValueError("usage: verify_parallel_acceptance.py settings | candidate ZIP BUILD"
                             " | evidence DIR BUILD HOST CANDIDATE_SHA256")
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile) as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 1
    print("Acceptance policy verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
