#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
HERE="$ROOT/Tests/SignedNEProbe"
SELECTED_DEVELOPER=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}
PLATFORM="$SELECTED_DEVELOPER/Platforms/MacOSX.platform/Developer"
umask 077
work=$(mktemp -d /private/tmp/aether-signed-probe-tests.XXXXXXXX)
cleanup() { find "$work" -depth -delete; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
framework=$(CDPATH= cd -- "$SELECTED_DEVELOPER/Library/Frameworks/Python3.framework/Versions/Current" && pwd -P)
version=$(basename -- "$framework")
runtime="$framework/bin/python$version"
mkdir "$work/helper"
sh "$ROOT/scripts/prepare_signed_ne_python_runtime.sh" "$runtime" "$work/helper/python-runtime.json"
cp "$ROOT/scripts/validation/controlled_probe.py" "$work/helper/controlled_probe.py"
export AETHERROUTE_OFFLINE_RUNTIME_RECORD="$work/helper/python-runtime.json"
export AETHERROUTE_OFFLINE_HELPER="$work/helper/controlled_probe.py"
export AETHERROUTE_OFFLINE_ARTIFACTS="${AETHERROUTE_OFFLINE_ARTIFACTS:-$work}"
export AETHERROUTE_OFFLINE_CONSUMER="$work/swift-input-consumer"
/usr/bin/xcrun swiftc -swift-version 6 -warnings-as-errors -D SIGNED_NE_PROBE_OFFLINE_TESTING \
  -I "$PLATFORM/usr/lib" -L "$PLATFORM/usr/lib" -lXCTestSwiftSupport \
  -F "$PLATFORM/Library/Frameworks" -framework XCTest \
  -Xlinker -rpath -Xlinker "$PLATFORM/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$PLATFORM/usr/lib" \
  "$ROOT/Tests/AetherRouteUITests/SignedNEPythonRuntime.swift" "$ROOT/Tests/AetherRouteUITests/SignedNEProbe.swift" \
  "$HERE/SignedNEProbeTests.swift" "$HERE/CycleBindingsTests.swift" "$HERE/CancellationTests.swift" "$HERE/RuntimeTests.swift" "$HERE/main.swift" \
  -o "$work/probe-tests"
"$work/probe-tests"
/usr/bin/xcrun swiftc -swift-version 6 -warnings-as-errors \
  "$ROOT/Tests/AetherRouteUITests/SignedNEPythonRuntime.swift" "$ROOT/Tests/AetherRouteUITests/SignedNEProbe.swift" \
  "$HERE/SwiftInputConsumer.swift" -o "$AETHERROUTE_OFFLINE_CONSUMER"
# Python source and full resources have already passed native Apple verification.
PYTHONDONTWRITEBYTECODE=1 "$runtime" -I -B "$ROOT/scripts/test_signed_ne_controlled_dispatch.py"
PYTHONDONTWRITEBYTECODE=1 "$runtime" -I -B "$ROOT/scripts/test_signed_ne_prebuilt_sources.py"
# These are the helper's explicitly offline classes; RealTLSTests is separate.
PYTHONDONTWRITEBYTECODE=1 "$runtime" -I -B "$ROOT/scripts/validation/test_controlled_probe.py" \
  PlanAndPhaseTests PrivateFileTests ProcessTests
