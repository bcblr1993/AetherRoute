#!/usr/bin/env python3
"""Reject lockfile versions covered by the release's reviewed Rust advisories."""
from pathlib import Path
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
# Reviewed GHSA floors, including Windows-only lockfile entries. Resolver DNSSEC,
# CNAME and TC-retry fixes shipped together; russh also fixes client callbacks,
# hybrid KEX and agent record allocation. Never silently accept an older copy.
MINIMUM = {
    "hickory-resolver": ((0, 26, 2), "GHSA-6w6g-hm98-mhgm / GHSA-5j98-2g5x-46v6 / GHSA-6f2x-v7q7-m7m5"),
    "russh": ((0, 64, 1), "GHSA-47hw-gvq5-r2gm / GHSA-w3jg-pjxf-73p4 / GHSA-4wc5-f2rc-q74m"),
    "pageant": ((0, 2, 3), "GHSA-g4mp-vgx3-xrvm"),
}

def check(path):
    packages = tomllib.loads(path.read_text())["package"]
    found = set()
    failures = []
    for package in packages:
        name = package["name"]
        if name not in MINIMUM:
            continue
        found.add(name)
        minimum, advisory = MINIMUM[name]
        version = package["version"]
        stable = version.split("+", 1)[0]
        try:
            parsed = tuple(map(int, stable.split(".")))
        except ValueError:
            parsed = ()
        if len(parsed) != 3 or parsed < minimum:
            failures.append(f"{name} {version}: requires >= {'.'.join(map(str, minimum))} ({advisory})")
    failures.extend(f"required dependency missing: {name}" for name in {"hickory-resolver", "russh"} - found)
    if failures:
        raise SystemExit("Unsafe engine dependency lockfile:\n" + "\n".join(failures))
    print("Engine security floors passed: DNS resolver, SSH and Windows agent dependencies")

if __name__ == "__main__":
    check(Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "Core/Engine/Cargo.lock")
