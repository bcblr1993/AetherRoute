#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FLOW_BUILD="$ROOT/scripts/build_core.sh"
PACKET_BUILD="$ROOT/scripts/build_direct_core.sh"

for build_script in "$FLOW_BUILD" "$PACKET_BUILD"; do
  grep -F -- '--remap-path-prefix=$CORE_SOURCE=/aetherroute-core' \
    "$build_script" >/dev/null || {
    echo "core builder does not remap the source root: $build_script" >&2
    exit 1
  }
  grep -F -- '--remap-path-prefix=$CARGO_TARGET_DIR=/aetherroute-target' \
    "$build_script" >/dev/null || {
    echo "core builder does not remap the Cargo target root: $build_script" >&2
    exit 1
  }
  if CARGO_TARGET_DIR='/tmp/aetherroute invalid target' \
    "$build_script" >/dev/null 2>&1; then
    echo "core builder accepted a target path that cannot be encoded safely" >&2
    exit 1
  fi
done

for artifact in \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a"
do
  test -f "$artifact" || {
    echo "core reproducibility guard is missing an artifact: $artifact" >&2
    exit 1
  }
  if strings "$artifact" | grep -F "$ROOT/" >/dev/null; then
    echo "core artifact embeds the local source root: $artifact" >&2
    exit 1
  fi
  if strings "$artifact" | grep -E \
    '/(private/)?tmp/aetherroute-(flow|direct)-remapped\.' >/dev/null; then
    echo "core artifact embeds a temporary Cargo target root: $artifact" >&2
    exit 1
  fi
done

echo 'Core reproducibility guards passed: source and Cargo target paths are remapped.'
