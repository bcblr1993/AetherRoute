#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-window-visibility.XXXXXX")
trap 'find "$TEST_TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
swiftc -swift-version 6 -warnings-as-errors \
  "$ROOT/Sources/AetherRouteApp/WindowVisibilityCoordinator.swift" \
  "$ROOT/Tests/WindowVisibility/main.swift" \
  -o "$TEST_TEMP/window-visibility"
"$TEST_TEMP/window-visibility"
