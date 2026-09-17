#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-product-tests.XXXXXX")
trap 'find "$TEST_TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
DERIVED_DATA_PATH=${AETHERROUTE_DERIVED_DATA_PATH:-"$TEST_TEMP/DerivedData"}
"$ROOT/scripts/bootstrap.sh"
mkdir -p "$DERIVED_DATA_PATH"
if [ -d "$ROOT/build/DerivedData/SourcePackages" ] && [ "$DERIVED_DATA_PATH" != "$ROOT/build/DerivedData" ]; then
  ditto "$ROOT/build/DerivedData/SourcePackages" "$DERIVED_DATA_PATH/SourcePackages"
fi

xcodebuild \
  -project "$ROOT/AetherRoute.xcodeproj" \
  -scheme AetherRouteUnitTests \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS= \
  CODE_SIGN_IDENTITY=- \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  build-for-testing

"$ROOT/scripts/verify_transparent_proxy_metadata.sh" built \
  "$DERIVED_DATA_PATH/Build/Products/Debug"
"$ROOT/scripts/verify_product_metadata.sh" built \
  "$DERIVED_DATA_PATH/Build/Products/Debug"
"$ROOT/scripts/verify_licenses.sh" built \
  "$DERIVED_DATA_PATH/Build/Products/Debug"
if strings \
  "$DERIVED_DATA_PATH/Build/Products/Debug/AetherRoute.app/Contents/MacOS/AetherRoute" \
  | grep -F 'AETHERROUTE_PERFORMANCE_MEASUREMENT' >/dev/null; then
  echo "Performance measurement fixture escaped into the standard app build" >&2
  exit 1
fi

# Xcode 26 occasionally fails to instantiate a valid, ad-hoc-signed macOS
# test bundle through test-without-building. Run the produced bundle directly;
# this keeps the local and remote gate deterministic while still building the
# complete independent app and both embedded Network Extensions above.
for TEST_BUNDLE in \
  "$DERIVED_DATA_PATH/Build/Products/Debug/AetherRouteTests.xctest" \
  "$DERIVED_DATA_PATH/Build/Products/Debug/AetherRouteTransparentProxySupportTests.xctest" \
  "$DERIVED_DATA_PATH/Build/Products/Debug/AetherRouteFlowCoreBridgeTests.xctest"
do
  codesign --verify --deep --strict "$TEST_BUNDLE"
  xcrun xctest "$TEST_BUNDLE"
done
AETHERROUTE_PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/Debug" \
  sh "$ROOT/Tests/LicenseExpiry/run.sh"
