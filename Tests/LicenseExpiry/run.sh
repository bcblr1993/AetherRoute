#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
: "${AETHERROUTE_PRODUCTS_DIR:?Pass the product directory from the current build}"
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-license-expiry.XXXXXX")
trap 'find "$TEST_TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -F "$AETHERROUTE_PRODUCTS_DIR" -I "$AETHERROUTE_PRODUCTS_DIR" \
  -Xlinker -rpath -Xlinker "$AETHERROUTE_PRODUCTS_DIR" \
  "$ROOT/Sources/AetherRouteApp/IndependentDistributionController.swift" \
  "$ROOT/Tests/LicenseExpiry/main.swift" -o "$TEST_TEMP/test"
"$TEST_TEMP/test"
