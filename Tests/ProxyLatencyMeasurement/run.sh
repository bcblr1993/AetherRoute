#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-proxy-latency.XXXXXX")
trap 'rm -rf "$TEST_TEMP"' EXIT

# The project builds into ./build, matching the other release scripts. This
# runner previously hard-coded one machine's DerivedData hash, so on any other
# Mac it either failed to resolve the framework or silently linked whatever
# stale copy happened to sit at that path.
PRODUCTS_DIR="${AETHERROUTE_PRODUCTS_DIR:-$ROOT/build/Debug}"

if [ ! -d "$PRODUCTS_DIR/AetherRouteKit.framework" ]; then
  echo "AetherRouteKit.framework not found under $PRODUCTS_DIR" >&2
  echo "Build it first, for example:" >&2
  echo "  xcodebuild -project AetherRoute.xcodeproj -target AetherRouteKit \\" >&2
  echo "    -configuration Debug build" >&2
  echo "Or set AETHERROUTE_PRODUCTS_DIR to the directory holding it." >&2
  exit 1
fi

swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -I "$PRODUCTS_DIR" \
  -F "$PRODUCTS_DIR" \
  -Xlinker -rpath -Xlinker "$PRODUCTS_DIR" \
  "$ROOT/Tests/ProxyLatencyMeasurement/main.swift" -o "$TEST_TEMP/test"
"$TEST_TEMP/test"
