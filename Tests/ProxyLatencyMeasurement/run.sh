#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-proxy-latency.XXXXXX")
trap 'rm -rf "$TEST_TEMP"' EXIT

# Build the actual latency model from this checkout, never a cached framework.
swiftc -swift-version 6 -warnings-as-errors -emit-library -emit-module \
  -module-name AetherRouteKit \
  "$ROOT/Sources/AetherRouteKit/ProxyLatencyIndex.swift" \
  -emit-module-path "$TEST_TEMP/AetherRouteKit.swiftmodule" \
  -o "$TEST_TEMP/libAetherRouteKit.dylib"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -I "$TEST_TEMP" -L "$TEST_TEMP" -lAetherRouteKit \
  -Xlinker -rpath -Xlinker "$TEST_TEMP" \
  "$ROOT/Tests/ProxyLatencyMeasurement/main.swift" -o "$TEST_TEMP/test"
"$TEST_TEMP/test"
