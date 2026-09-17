#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-engine-reconnect.XXXXXX")
trap 'find "$TEST_TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$ROOT/Sources/AetherRouteKit/NetworkEngineReconnectCoordinator.swift" \
  "$ROOT/Tests/EngineReconnect/main.swift" -o "$TEST_TEMP/test"
"$TEST_TEMP/test"
