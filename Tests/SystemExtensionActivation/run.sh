#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-system-extension-tests.XXXXXX")
trap 'find "$TEST_TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

swiftc -swift-version 6 -warnings-as-errors -emit-library -emit-module \
  -module-name AetherRouteKit \
  "$ROOT/Sources/AetherRouteKit/SystemExtensionActivationPolicy.swift" \
  "$ROOT/Sources/AetherRouteKit/AppLog.swift" \
  -emit-module-path "$TEST_TEMP/AetherRouteKit.swiftmodule" \
  -o "$TEST_TEMP/libAetherRouteKit.dylib"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -I "$TEST_TEMP" -L "$TEST_TEMP" -lAetherRouteKit \
  -Xlinker -rpath -Xlinker "$TEST_TEMP" \
  "$ROOT/Sources/AetherRouteApp/SystemExtensionActivationCoordinator.swift" \
  "$ROOT/Tests/SystemExtensionActivation/main.swift" \
  -o "$TEST_TEMP/system-extension-activation"
"$TEST_TEMP/system-extension-activation"
