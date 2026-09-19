#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
: "${AETHERROUTE_PRODUCTS_DIR:="$ROOT/build/Debug/Build/Products/Debug"}"
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-sparkle-debounce.XXXXXX")
trap 'find "$TEST_TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

swiftc -swift-version 6 -warnings-as-errors -D DEBUG -parse-as-library \
  -F "$AETHERROUTE_PRODUCTS_DIR" -I "$AETHERROUTE_PRODUCTS_DIR" \
  -Xlinker -rpath -Xlinker "$AETHERROUTE_PRODUCTS_DIR" \
  -framework Sparkle -framework AetherRouteKit \
  "$ROOT/Sources/AetherRouteApp/AppLanguageController.swift" \
  "$ROOT/Sources/AetherRouteApp/SparkleUpdaterController.swift" \
  "$ROOT/Tests/SparkleAutoUpdateDebounce/main.swift" \
  -o "$TEST_TEMP/sparkle-auto-update-debounce"
"$TEST_TEMP/sparkle-auto-update-debounce"
