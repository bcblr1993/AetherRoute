#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
if [ -z "${AETHERROUTE_PRODUCTS_DIR:-}" ] || [ ! -d "$AETHERROUTE_PRODUCTS_DIR" ]; then
  if [ -d "$ROOT/build/DerivedData-unit/Build/Products/Debug" ]; then
    AETHERROUTE_PRODUCTS_DIR="$ROOT/build/DerivedData-unit/Build/Products/Debug"
  elif [ -d "$ROOT/build/DerivedData/Build/Products/Debug" ]; then
    AETHERROUTE_PRODUCTS_DIR="$ROOT/build/DerivedData/Build/Products/Debug"
  elif [ -d "$ROOT/build/Debug/Build/Products/Debug" ]; then
    AETHERROUTE_PRODUCTS_DIR="$ROOT/build/Debug/Build/Products/Debug"
  fi
fi

if [ -z "${AETHERROUTE_PRODUCTS_DIR:-}" ] || [ ! -d "$AETHERROUTE_PRODUCTS_DIR" ]; then
  echo "SparkleAutoUpdateDebounce requires built frameworks, skipping (no products dir found)"
  exit 0
fi

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
