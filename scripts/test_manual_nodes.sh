#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-manual-nodes.XXXXXX")
chmod 700 "$TEMP_DIR"
cleanup() {
  find "$TEMP_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

swiftc -parse-as-library \
  "$ROOT/Sources/AetherRouteKit/ProfileImportValidator.swift" \
  "$ROOT/Sources/AetherRouteKit/AetherNode.swift" \
  "$ROOT/Tests/ManualNodes/main.swift" \
  -o "$TEMP_DIR/manual_node_fixture_generator"
"$TEMP_DIR/manual_node_fixture_generator" "$TEMP_DIR/profiles"

COMMON_FLAGS="-std=c17 -Wall -Wextra -Werror -mmacosx-version-min=14.0"
clang $COMMON_FLAGS \
  -DAETHER_EXTERNAL_FLOW_ONLY \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/external_profile_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" \
  -framework Security \
  -framework SystemConfiguration \
  -framework CoreFoundation \
  -framework CoreServices \
  -lresolv \
  -o "$TEMP_DIR/flow_profile_smoke"

clang $COMMON_FLAGS \
  -DAETHER_EXTERNAL_PACKET \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/external_profile_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" \
  -framework Security \
  -framework SystemConfiguration \
  -framework CoreFoundation \
  -framework CoreServices \
  -lresolv \
  -o "$TEMP_DIR/packet_profile_smoke"

mkdir -m 700 "$TEMP_DIR/runtime"
failures=0
count=0
for profile in "$TEMP_DIR"/profiles/*.yaml; do
  count=$((count + 1))
  protocol=$(basename "$profile" .yaml)
  if /usr/bin/sandbox-exec \
    -p '(version 1) (allow default) (deny network*)' \
    "$TEMP_DIR/flow_profile_smoke" "$profile" "$TEMP_DIR/runtime" \
    >/dev/null; then
    printf '%s flow-only=pass ' "$protocol"
  else
    printf '%s flow-only=fail ' "$protocol" >&2
    failures=$((failures + 1))
  fi
  if /usr/bin/sandbox-exec \
    -p '(version 1) (allow default) (deny network*)' \
    "$TEMP_DIR/packet_profile_smoke" "$profile" "$TEMP_DIR/runtime" \
    >/dev/null; then
    printf 'packet-tunnel=pass\n'
  else
    printf 'packet-tunnel=fail\n' >&2
    failures=$((failures + 1))
  fi
done

test "$count" -eq 12 || {
  echo "manual node gate expected 12 protocol profiles, found $count" >&2
  exit 1
}
test "$failures" -eq 0 || {
  echo "manual node isolation gate failed on $failures core surface(s)" >&2
  exit 1
}
echo "Manual nodes verified: protocols=12 core_surfaces=24 network=denied"
