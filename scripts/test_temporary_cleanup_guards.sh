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
