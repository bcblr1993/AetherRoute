"""Collect one engine's runtime receipts in the isolated Tart VM (`vm:macos27`).

The candidate is the notarized candidate DMG installed in that VM; the same
DMG is later packaged, and package_release_dmg.sh refuses it without receipts.

Never installs, launches, or changes the candidate's mode. Interface switching
disrupts the guest VM's uplinks, hence the explicit opt-in and guest UUID check.
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


def resolve_ssh_target(host):
    if host.startswith("vm:"):
        vm_name = host.split(":", 1)[1]
        require(re.fullmatch(r"[A-Za-z0-9._-]+", vm_name), "invalid Tart VM name")
        vm_user = os.environ.get("AETHERROUTE_VM_USER", "chenxu")
        vm_ip = os.environ.get("AETHERROUTE_VM_IP", "").strip()
        if not vm_ip:
            result = subprocess.run(["tart", "ip", vm_name], capture_output=True, text=True, timeout=15)
            vm_ip = result.stdout.strip()
        require(re.fullmatch(r"[0-9.]+", vm_ip), f"cannot resolve IP for Tart VM {vm_name}")
        return f"{vm_user}@{vm_ip}"
    return host


def collect(candidate, host, engine, directory):
    require(os.environ.get("AETHERROUTE_ALLOW_PHYSICAL_RUNTIME") == "YES",
            "requires AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES for the dedicated test VM")
    # Keep this disruptive gate pinned to the isolated Tart VM, never this Mac,
    # a loopback alias, or an arbitrary user-supplied SSH endpoint.
    expected_vm = f"vm:{os.environ.get('AETHERROUTE_VM_NAME', 'macos27')}"
    require(host == expected_vm, f"runtime gate only supports the designated Tart VM ({expected_vm})")
    require(engine in ("tun", "transparent"), "engine must be tun or transparent")
    candidate = Path(candidate)
    build, hashes = read_candidate(candidate)
    digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
    ssh_target = resolve_ssh_target(host)
    ssh_key = Path(os.environ.get("AETHERROUTE_VM_SSH_KEY", str(Path.home() / ".ssh/id_ed25519")))
    ssh_base = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                "-o", "StrictHostKeyChecking=accept-new"]
    if ssh_key.is_file():
        ssh_base += ["-o", "IdentitiesOnly=yes", "-i", str(ssh_key)]

    def remote(command, script=None, timeout=30):
        return subprocess.run([*ssh_base, ssh_target, command],
                              input=script, capture_output=True, text=True, timeout=timeout)

    def identity():
        hardware = remote("ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/grep IOPlatformUUID")
        local = subprocess.run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
                               capture_output=True, text=True, check=True)
        pattern = r'"IOPlatformUUID"\s*=\s*"([^"]+)"'
        remote_uuid = re.search(pattern, hardware.stdout)
        local_uuid = re.search(pattern, local.stdout)
        require(remote_uuid and local_uuid and remote_uuid[1] != local_uuid[1], "refusing the current Mac or unverified guest")
        vmm = remote("/usr/sbin/sysctl -n kern.hv_vmm_present")
        require(vmm.returncode == 0 and vmm.stdout.strip() == "1", "refusing a non-VM host")
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
            result = subprocess.run(["sh", str(SCRIPTS / script), ssh_target], env=env,
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
    print(f"Runtime {engine} evidence saved: {record_path}")


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 5, "usage: collect_physical_runtime_evidence.py CANDIDATE_DMG HOST ENGINE OUTPUT_DIR")
        collect(*sys.argv[1:])
    except (ValueError, OSError, KeyError, IndexError, subprocess.SubprocessError) as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        sys.exit(1)
