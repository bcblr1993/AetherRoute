"""Collect one engine's runtime receipts on the dedicated, already connected Mac.

The candidate is the notarized candidate DMG installed on that Mac; the same
DMG is later packaged, and package_release_dmg.sh refuses it without receipts.

Never installs, launches, or changes the candidate's mode. Interface switching
does disrupt the designated remote Mac, hence the explicit hardware opt-in.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

from verify_parallel_acceptance import read_candidate, require, verify_output

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"


def collect(candidate, host, engine, directory):
    require(os.environ.get("AETHERROUTE_ALLOW_PHYSICAL_RUNTIME") == "YES",
            "requires AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES for the dedicated test Mac")
    # Keep this disruptive gate pinned to the SOP's hardware, never this Mac,
    # a loopback alias, or an arbitrary user-supplied SSH endpoint.
    require(host == "chenxu@100.64.0.3", "physical gate only supports the designated Mac mini")
    require(engine in ("tun", "transparent"), "engine must be tun or transparent")
    candidate = Path(candidate)
    build, hashes = read_candidate(candidate)
    digest = hashlib.sha256(candidate.read_bytes()).hexdigest()

    def remote(command, script=None, timeout=30):
        return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host, command],
                              input=script, capture_output=True, text=True, timeout=timeout)

    def identity():
        hardware = remote("ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/grep IOPlatformUUID")
        local = subprocess.run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
                               capture_output=True, text=True, check=True)
        pattern = r'"IOPlatformUUID"\s*=\s*"([^"]+)"'
        remote_uuid = re.search(pattern, hardware.stdout)
        local_uuid = re.search(pattern, local.stdout)
        require(remote_uuid and local_uuid and remote_uuid[1] != local_uuid[1], "refusing the current Mac or unverified hardware")
        for name, expected in hashes.items():
            result = remote("shasum -a 256 " + shlex.quote("/Applications/" + name))
            require(result.returncode == 0 and result.stdout.split()[0] == expected,
                    "installed candidate binary differs from the supplied DMG")
        result = remote(f"sh -s -- ready {build} {engine}",
                        (SCRIPTS / "vm_matrix_lifecycle.sh").read_text())
        require(result.returncode == 0, "candidate is not connected in the requested engine")

    identity()
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    record_path = directory / f"{engine}.json"
    require(not record_path.exists(), "refusing to overwrite existing engine evidence")
    for name in ("idle", "upload", "switch"):
        require(not (directory / f"{engine}-{name}.log").exists(), "use a fresh evidence directory after a failed run")
    record = {"schema": 1, "build": build, "host": host, "engine": engine,
              "candidate_sha256": digest, "checks": {}}
    for name, script, timeout in [("idle", "test_idle_keepalive_reuse.sh", 110),
                                  ("upload", "test_large_upload.sh", 270),
                                  ("switch", "test_remote_interface_switch.sh", 1000)]:
        identity()
        if name == "switch":
            env = {key: value for key, value in os.environ.items() if not key.startswith("AETHERROUTE_SWITCH_")}
            result = subprocess.run(["sh", str(SCRIPTS / script), host], env=env,
                                    capture_output=True, text=True, timeout=timeout)
        else:
            result = remote("sh -s", (SCRIPTS / script).read_text(), timeout=timeout)
        output = result.stdout + result.stderr
        log = directory / f"{engine}-{name}.log"
        log.write_text(output)
        require(result.returncode == 0, f"{engine}/{name} failed; see {log}")
        verify_output(name, output)
        identity()
        record["checks"][name] = {"exit_status": result.returncode, "log": log.name,
                                  "sha256": hashlib.sha256(log.read_bytes()).hexdigest()}
    record_path.write_text(json.dumps(record, indent=2) + "\n")
    print(f"Physical {engine} evidence saved: {record_path}")


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 5, "usage: collect_physical_runtime_evidence.py CANDIDATE_DMG HOST ENGINE OUTPUT_DIR")
        collect(*sys.argv[1:])
    except (ValueError, OSError, KeyError, IndexError, subprocess.SubprocessError) as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        sys.exit(1)
