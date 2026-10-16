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
