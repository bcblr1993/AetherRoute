#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SANITIZER_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-sanitizers.XXXXXX")
cleanup() {
  find "$SANITIZER_ROOT" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

XCTEST_BINARY=$(xcrun --find xctest)
"$ROOT/scripts/bootstrap.sh" >/dev/null

run_gate() {
  gate_name=$1
  shift
  derived_data="$SANITIZER_ROOT/$gate_name"
  printf 'Sanitizer gate %s: build started\n' "$gate_name"
  xcodebuild -quiet \
    -project "$ROOT/AetherRoute.xcodeproj" \
    -scheme AetherRouteUnitTests \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS= \
    CODE_SIGN_IDENTITY=- \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    ENABLE_DEBUG_DYLIB=NO \
    "$@" \
    build-for-testing

  for bundle_name in \
    AetherRouteTests \
    AetherRouteTransparentProxySupportTests \
    AetherRouteFlowCoreBridgeTests
  do
    bundle="$derived_data/Build/Products/Debug/$bundle_name.xctest"
    test -d "$bundle" || {
      echo "Sanitizer test bundle is missing: $bundle_name" >&2
      exit 1
    }
    libraries=$(find "$bundle/Contents/Frameworks" \
      -type f -name 'libclang_rt.*san*_osx_dynamic.dylib' \
      | LC_ALL=C sort | paste -sd: -)
    test -n "$libraries" || {
      echo "Sanitizer runtime is missing: $gate_name/$bundle_name" >&2
      exit 1
    }

    result="$SANITIZER_ROOT/$gate_name-$bundle_name.log"
    if ! DYLD_INSERT_LIBRARIES="$libraries" \
      "$XCTEST_BINARY" "$bundle" >"$result" 2>&1; then
      tail -80 "$result" >&2
      exit 1
    fi
    if grep -Eq \
      'Interceptors are not working|WARNING: ThreadSanitizer|ERROR: AddressSanitizer|runtime error:' \
      "$result"; then
      echo "Sanitizer report detected: $gate_name/$bundle_name" >&2
      tail -80 "$result" >&2
      exit 1
    fi
    tail -5 "$result"
  done
  printf 'Sanitizer gate %s: passed\n' "$gate_name"
}

run_gate thread -enableThreadSanitizer YES
run_gate address-undefined \
  -enableAddressSanitizer YES \
  -enableUndefinedBehaviorSanitizer YES

echo 'Current-source sanitizer gates passed.'
