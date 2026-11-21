#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

if grep -Fq 'sizingOptions = .preferredContentSize' "$ROOT/Sources/AetherRouteApp/AppUpdateWindow.swift"; then
  echo "AppUpdateWindow.swift must not use NSHostingController.sizingOptions = .preferredContentSize (triggers macOS 27 NSDisplayCycle crash)" >&2
  exit 1
fi

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

SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx swiftc -sdk "$SDK_PATH" -swift-version 6 -warnings-as-errors -D DEBUG -parse-as-library \
  -F "$AETHERROUTE_PRODUCTS_DIR" -I "$AETHERROUTE_PRODUCTS_DIR" \
  -Xlinker -rpath -Xlinker "$AETHERROUTE_PRODUCTS_DIR" \
  -framework Sparkle -framework AetherRouteKit \
  "$ROOT/Sources/AetherRouteApp/AppLanguageController.swift" \
  "$ROOT/Sources/AetherRouteApp/AppUpdateWindow.swift" \
  "$ROOT/Sources/AetherRouteApp/SparkleUpdaterController.swift" \
  "$ROOT/Tests/SparkleAutoUpdateDebounce/main.swift" \
  -o "$TEST_TEMP/sparkle-auto-update-debounce"
"$TEST_TEMP/sparkle-auto-update-debounce"

xcrun --sdk macosx swiftc -sdk "$SDK_PATH" -swift-version 6 -warnings-as-errors -D DEBUG -parse-as-library \
  -F "$AETHERROUTE_PRODUCTS_DIR" -I "$AETHERROUTE_PRODUCTS_DIR" \
  -Xlinker -rpath -Xlinker "$AETHERROUTE_PRODUCTS_DIR" \
  -framework Sparkle -framework AetherRouteKit \
  "$ROOT/Sources/AetherRouteApp/AppLanguageController.swift" \
  "$ROOT/Sources/AetherRouteApp/AppUpdateWindow.swift" \
  "$ROOT/Tests/SparkleAutoUpdateDebounce/WindowLayoutRegression.swift" \
  -o "$TEST_TEMP/app-update-window-layout-regression"

if [ "$(launchctl managername 2>/dev/null || true)" = "Aqua" ]; then
  "$TEST_TEMP/app-update-window-layout-regression" -AppleLanguages '(zh-Hans)'
  "$TEST_TEMP/app-update-window-layout-regression" -AppleLanguages '(en)'
else
  echo "Skipping live AppUpdateWindow layout regression (non-Aqua session)"
fi
