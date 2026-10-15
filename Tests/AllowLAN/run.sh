#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-allow-lan.XXXXXX")
trap 'find "$TEST_TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$ROOT/Sources/AetherRouteKit/LocalProxySettings.swift" \
  "$ROOT/Sources/AetherRouteKit/LANAddressResolver.swift" \
  "$ROOT/Tests/AllowLAN/main.swift" \
  -o "$TEST_TEMP/allow-lan-test"

"$TEST_TEMP/allow-lan-test"
