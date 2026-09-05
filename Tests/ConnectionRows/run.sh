#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-connection-rows.XXXXXX")
trap 'find "$TEST_TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

# Compile the real telemetry model and real UI projection without launching
# the app, starting extensions, or copying any Rust build cache.
swiftc -swift-version 6 -warnings-as-errors -emit-library -emit-module \
  -module-name AetherRouteKit \
  "$ROOT/Sources/AetherRouteKit/NetworkTelemetry.swift" \
  -emit-module-path "$TEST_TEMP/AetherRouteKit.swiftmodule" \
  -o "$TEST_TEMP/libAetherRouteKit.dylib"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -I "$TEST_TEMP" -L "$TEST_TEMP" -lAetherRouteKit \
  -Xlinker -rpath -Xlinker "$TEST_TEMP" \
  "$ROOT/Sources/AetherRouteApp/ConnectionTableItem.swift" \
  "$ROOT/Tests/ConnectionRows/main.swift" \
  -o "$TEST_TEMP/connection-rows"
"$TEST_TEMP/connection-rows"
