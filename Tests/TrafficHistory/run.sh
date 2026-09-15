#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-traffic-history.XXXXXX")
trap 'rm -f "$TEST_TEMP/test"; rmdir "$TEST_TEMP"' EXIT
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$ROOT/Sources/AetherRouteApp/TrafficHistory.swift" \
  "$ROOT/Tests/TrafficHistory/main.swift" -o "$TEST_TEMP/test"
"$TEST_TEMP/test"
