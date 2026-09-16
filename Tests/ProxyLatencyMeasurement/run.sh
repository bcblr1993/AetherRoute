#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-proxy-latency.XXXXXX")
trap 'rm -rf "$TEST_TEMP"' EXIT
DERIVED_DIR="$HOME/Library/Developer/Xcode/DerivedData/AetherRoute-eilzqhmycyrffzgbdcagtxnbfweg/Build/Products/Debug"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -I "$DERIVED_DIR" \
  -F "$DERIVED_DIR" \
  -Xlinker -rpath -Xlinker "$DERIVED_DIR" \
  "$ROOT/Tests/ProxyLatencyMeasurement/main.swift" -o "$TEST_TEMP/test"
"$TEST_TEMP/test"
