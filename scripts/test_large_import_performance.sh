#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-large-import.XXXXXX")
cleanup() {
  find "$TEMP" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

if [ "$(uname -m)" != arm64 ]; then
  echo "Large import performance gate requires Apple silicon" >&2
  exit 1
fi

"$ROOT/scripts/bootstrap.sh" >/dev/null
mkdir -p "$TEMP/DerivedData"
if [ -d "$ROOT/build/DerivedData/SourcePackages" ]; then
  ditto "$ROOT/build/DerivedData/SourcePackages" "$TEMP/DerivedData/SourcePackages"
fi
xcodebuild -quiet \
  -project "$ROOT/AetherRoute.xcodeproj" \
  -scheme AetherRouteUnitTests \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$TEMP/DerivedData" \
  AETHERROUTE_ALLOW_ISOLATED_RELEASE_TEST_BUILD=YES \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS= \
  CODE_SIGN_IDENTITY=- \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  ENABLE_TESTABILITY=YES \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) AETHERROUTE_DEVELOPMENT_PREVIEW' \
  build-for-testing

bundle="$TEMP/DerivedData/Build/Products/Release/AetherRouteTests.xctest"
test -d "$bundle" || {
  echo "Release AetherRouteTests bundle is missing" >&2
  exit 1
}
codesign --verify --deep --strict "$bundle"

env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  xcrun xctest -XCTest \
  'ProfileFileImporterTests/testCancellationBeforeValidationDoesNotCommitProfile,ProfileFileImporterTests/testFiveThousandNodeImportMeetsReleaseBudget,ProfileImportValidatorTests/testLargeValidationHonorsCancellationDuringLineScan' \
  "$bundle"

echo 'Large import release performance and cancellation gate passed.'
