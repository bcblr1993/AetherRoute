#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-cleanup-guards.XXXXXX")
cleanup() {
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

expect_failure_without_temp() {
  prefix=$1
  shift
  before="$WORK/$prefix.before"
  after="$WORK/$prefix.after"
  find "$WORK" -maxdepth 1 -type d -name "$prefix.*" -print \
    | LC_ALL=C sort >"$before"
  if TMPDIR="$WORK" "$@" >"$WORK/$prefix.log" 2>&1; then
    echo "Temporary cleanup guard expected failure: $prefix" >&2
    exit 1
  fi
  find "$WORK" -maxdepth 1 -type d -name "$prefix.*" -print \
    | LC_ALL=C sort >"$after"
  cmp -s "$before" "$after" || {
    echo "Temporary cleanup guard detected a leaked directory: $prefix" >&2
    diff -u "$before" "$after" >&2 || true
    exit 1
  }
}

expect_failure_without_temp aetherroute-udp-integrity \
  "$ROOT/scripts/test_udp_integrity.sh" relative-output
expect_failure_without_temp aetherroute-tcp-performance \
  "$ROOT/scripts/test_tcp_performance.sh" relative-output
expect_failure_without_temp aetherroute-interop \
  env \
    AETHER_CORE_ROOT=/nonexistent \
    SING_BOX_BIN=/usr/bin/true \
    SHADOW_TLS_BIN=/usr/bin/true \
    AETHER_INTEROP_CYCLES=0 \
    "$ROOT/scripts/test_protocol_interop.sh"
expect_failure_without_temp aetherroute-shadowquic \
  env \
    AETHER_CORE_ROOT=/nonexistent \
    MIHOMO_ARCHIVE=/nonexistent \
    AETHER_INTEROP_CYCLES=0 \
    "$ROOT/scripts/test_shadowquic_interop.sh"

# Exercise the real candidate-cleanup command through a symlinked /tmp root,
# as on macOS; retain a neighbouring candidate from another build.
python3 - "$ROOT" "$WORK" <<'PYTEST'
from pathlib import Path
import os, subprocess, sys
root, work = map(Path, sys.argv[1:])
real = work / "physical-real-tmp"; real.mkdir()
alias = work / "physical-tmp"; alias.symlink_to(real, target_is_directory=True)
target = real / "aetherroute-candidate-regression.dmg"
other = real / "aetherroute-candidate-another-build.dmg"
target.write_bytes(b"synthetic candidate"); other.write_bytes(b"preserve another build")
source = (root / "scripts/collect_physical_runtime_pair.sh").read_text()
restore = source.split("restore() {", 1)[1].split("\n}", 1)[0]
command = next(line for line in restore.splitlines() if "/tmp" in line and "aetherroute-candidate-$BUILD.dmg" in line)
command = command.replace("/tmp", str(alias)).replace('\\"', '"')
subprocess.run(["sh", "-c", command], env={**os.environ, "BUILD": "regression"}, check=True)
assert not target.exists(), "Physical candidate leaked through symlinked tmp root"
assert other.read_bytes() == b"preserve another build", "Another build was removed"
assert alias.is_symlink(), "Temporary root was removed"
print("Physical candidate cleanup: symlinked tmp works and other builds survive")
PYTEST

recursive_remove=$(printf 'rm%srf' ' -')
for script in "$ROOT"/scripts/*.sh; do
  grep -q 'mktemp' "$script" || continue
  grep -q 'trap ' "$script" || {
    echo "Temporary cleanup guard is missing an exit trap: $script" >&2
    exit 1
  }
  for condition in EXIT HUP INT TERM; do
    grep -q "$condition" "$script" || {
      echo "Temporary cleanup guard is missing $condition handling: $script" >&2
      exit 1
    }
  done
  if grep -F "$recursive_remove" "$script" >/dev/null; then
    echo "Temporary cleanup must use an exact find target: $script" >&2
    exit 1
  fi
done

printf 'Temporary cleanup guards passed: early exits clean and every mktemp script handles EXIT/HUP/INT/TERM\n'
