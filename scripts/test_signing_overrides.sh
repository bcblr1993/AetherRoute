#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-signing-overrides.XXXXXX")
cleanup() {
  if [ -d "$TEST_DIRECTORY" ]; then
    find "$TEST_DIRECTORY" -depth -delete
  fi
}
trap cleanup EXIT HUP INT TERM

CONFIG="$TEST_DIRECTORY/Signing.json"
OUTPUT="$TEST_DIRECTORY/AetherRouteSigning.xcconfig"
sed \
  -e 's/TEAMID1234/ABCDE12345/g' \
  -e 's/com\.yourcompany\.aetherroute/com.acme.aetherroute/g' \
  "$ROOT/Config/Signing.example.json" >"$CONFIG"

"$ROOT/scripts/generate_signing_overrides.sh" "$CONFIG" "$OUTPUT" >/dev/null
test "$(stat -f '%Lp' "$OUTPUT")" = 600
grep -qx 'AETHERROUTE_DEVELOPMENT_TEAM = ABCDE12345' "$OUTPUT"
grep -qx 'AETHERROUTE_BUNDLE_ID = com.acme.aetherroute' "$OUTPUT"
grep -qx 'AETHERROUTE_APP_GROUP = group.com.acme.aetherroute' "$OUTPUT"
grep -qx 'AETHERROUTE_KEYCHAIN_GROUP_SUFFIX = com.acme.aetherroute.shared' "$OUTPUT"
if grep -Eq 'SHA1|provision|/absolute/path' "$OUTPUT"; then
  echo "generated xcconfig leaked signing material" >&2
  exit 1
fi

if command -v xcodebuild >/dev/null 2>&1 && \
  [ -d "$ROOT/AetherRoute.xcodeproj" ]; then
  settings="$TEST_DIRECTORY/build-settings.json"
  mkdir -p "$TEST_DIRECTORY/DerivedData"
  if [ -d "$ROOT/build/DerivedData/SourcePackages" ]; then
    ditto "$ROOT/build/DerivedData/SourcePackages" "$TEST_DIRECTORY/DerivedData/SourcePackages"
  fi
  xcodebuild \
    -quiet \
    -project "$ROOT/AetherRoute.xcodeproj" \
    -scheme AetherRoute \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$TEST_DIRECTORY/DerivedData" \
    -xcconfig "$OUTPUT" \
    -showBuildSettings \
    -json >"$settings"

  verify_target() {
    target=$1
    expected_bundle=$2
    jq -e \
      --arg target "$target" \
      --arg bundle "$expected_bundle" '
        [.[] | select(.target == $target) | .buildSettings] as $matches
        | ($matches | length) == 1
        and $matches[0].PRODUCT_BUNDLE_IDENTIFIER == $bundle
        and $matches[0].AETHERROUTE_APP_GROUP == "group.com.acme.aetherroute"
        and $matches[0].AETHERROUTE_KEYCHAIN_GROUP_SUFFIX == "com.acme.aetherroute.shared"
        and $matches[0].DEVELOPMENT_TEAM == "ABCDE12345"
      ' "$settings" >/dev/null
  }
  verify_target AetherRoute com.acme.aetherroute
  verify_target AetherRouteTransparentProxy \
    com.acme.aetherroute.transparent-proxy
  verify_target AetherRoutePacketTunnel com.acme.aetherroute.tunnel
fi

invalid="$TEST_DIRECTORY/Invalid.json"
sed 's/com\.acme\.aetherroute\.tunnel/com.acme.aetherroute.wrong/' \
  "$CONFIG" >"$invalid"
if "$ROOT/scripts/generate_signing_overrides.sh" "$invalid" \
  "$TEST_DIRECTORY/invalid.xcconfig" >/dev/null 2>&1; then
  echo "mismatched extension identifier was accepted" >&2
  exit 1
fi

echo "Signing override generation tests passed."
