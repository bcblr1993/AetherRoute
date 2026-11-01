#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-menubar-traffic.XXXXXX")
trap 'find "$TEST_TEMP" -depth -delete 2>/dev/null; true' EXIT HUP INT TERM
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$ROOT/Sources/AetherRouteApp/AppMenuBarIconController.swift" \
  "$ROOT/Sources/AetherRouteApp/MenuBarTrafficController.swift" \
  "$ROOT/Tests/MenuBarTraffic/main.swift" -o "$TEST_TEMP/test"
"$TEST_TEMP/test"

swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$ROOT/Sources/AetherRouteApp/AppMenuBarIconController.swift" \
  "$ROOT/Sources/AetherRouteApp/MenuBarTrafficController.swift" \
  "$ROOT/Tests/MenuBarTraffic/transforms.swift" -o "$TEST_TEMP/transforms"
"$TEST_TEMP/transforms"

# Exercise the native status-item consumer as well as offscreen rasterization.
# The old lazy image crashed here in CoreText during changing-rate updates.
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$ROOT/Sources/AetherRouteApp/AppMenuBarIconController.swift" \
  "$ROOT/Sources/AetherRouteApp/MenuBarTrafficController.swift" \
  "$ROOT/Tests/MenuBarTraffic/status-item.swift" -o "$TEST_TEMP/status-item"
"$TEST_TEMP/status-item"
