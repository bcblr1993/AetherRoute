#!/bin/sh
set -eu
umask 077

# Profile overrides (1.7.0): applies a fixed override to flow, block and
# JSON profiles and starts both cores on each result with networking denied,
# so a rewritten group can never stop a profile from loading.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-profile-override.XXXXXX")
chmod 700 "$TEMP_DIR"
cleanup() {
  find "$TEMP_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

KIT="$ROOT/Sources/AetherRouteKit"
swiftc -parse-as-library \
  "$KIT/ProfileOverride.swift" \
  "$KIT/ProfileOverrideCompiler.swift" \
  "$KIT/NodeRegion.swift" \
  "$KIT/GeoSiteCategoryIndex.swift" \
  "$KIT/EngineCapabilities.swift" \
  "$KIT/ProfileConfigurationSummary.swift" \
  "$KIT/ProxySelectionMode.swift" \
  "$KIT/CustomRule.swift" \
  "$ROOT/Tests/ProfileOverride/main.swift" \
  -o "$TEMP_DIR/profile_override_fixture_generator"
"$TEMP_DIR/profile_override_fixture_generator" "$TEMP_DIR/profiles"

COMMON_FLAGS="-std=c17 -Wall -Wextra -Werror -mmacosx-version-min=14.0"
clang $COMMON_FLAGS \
  -DAETHER_EXTERNAL_FLOW_ONLY \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/external_profile_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" \
  -framework Security -framework SystemConfiguration -framework CoreFoundation \
  -framework CoreServices -lresolv \
  -o "$TEMP_DIR/flow_profile_smoke"
clang $COMMON_FLAGS \
  -DAETHER_EXTERNAL_PACKET \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/external_profile_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" \
  -framework Security -framework SystemConfiguration -framework CoreFoundation \
  -framework CoreServices -lresolv \
  -o "$TEMP_DIR/packet_profile_smoke"

mkdir -m 700 "$TEMP_DIR/runtime"
failures=0
count=0
for profile in "$TEMP_DIR"/profiles/*.yaml; do
  count=$((count + 1))
  layout=$(basename "$profile" .yaml)
  for surface in flow packet; do
    if /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
      "$TEMP_DIR/${surface}_profile_smoke" "$profile" "$TEMP_DIR/runtime" >/dev/null; then
      printf '%s %s=pass\n' "$layout" "$surface"
    else
      printf '%s %s=fail\n' "$layout" "$surface" >&2
      failures=$((failures + 1))
    fi
  done
done

test "$count" -eq 3 || { echo "expected 3 override layouts, found $count" >&2; exit 1; }
test "$failures" -eq 0 || { echo "profile override core gate failed on $failures surface(s)" >&2; exit 1; }
echo "Profile overrides verified: layouts=3 core_surfaces=6 network=denied"
