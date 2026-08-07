#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SIGNING_CONFIG=${1:-}
NOTARY_PROFILE=${2:-}
VERSION=${3:-}
BUILD_NUMBER=${4:-}
OUTPUT_DIRECTORY=${5:-}

usage() {
  echo "usage: $0 /absolute/Signing.json notary-profile version build-number /absolute/new-output-directory" >&2
}

if [ -z "$SIGNING_CONFIG" ] || [ -z "$NOTARY_PROFILE" ] \
  || [ -z "$VERSION" ] || [ -z "$BUILD_NUMBER" ] \
  || [ -z "$OUTPUT_DIRECTORY" ]; then
  usage
  exit 64
fi
case "$SIGNING_CONFIG:$OUTPUT_DIRECTORY" in
  /*:/*) ;;
  *) usage; exit 64 ;;
esac
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || {
  echo "version must use numeric major.minor or major.minor.patch form" >&2
  exit 64
}
printf '%s\n' "$BUILD_NUMBER" | grep -Eq '^[1-9][0-9]*$' || {
  echo "build number must be a positive integer" >&2
  exit 64
}
test -f "$SIGNING_CONFIG" || {
  echo "signing configuration is missing" >&2
  exit 66
}
test ! -e "$OUTPUT_DIRECTORY" || {
  echo "refusing to overwrite test candidate output" >&2
  exit 1
}
test -d "$(dirname -- "$OUTPUT_DIRECTORY")" || {
  echo "test candidate output parent does not exist" >&2
  exit 1
}
test "$(uname -m)" = arm64 || {
  echo "notarized test candidates require Apple silicon" >&2
  exit 1
}
for command in codesign ditto file hdiutil jq lipo plutil security \
  shasum spctl xcodebuild xcrun; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "notarized test candidate requires $command" >&2
    exit 1
  }
done

"$ROOT/scripts/signing_preflight.sh" "$SIGNING_CONFIG"
"$ROOT/scripts/bootstrap.sh"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
  --output-format json >/dev/null

TEMPORARY=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-notarized-test.XXXXXX")
MOUNTED=0
MOUNT_POINT="$TEMPORARY/mount"
OUTPUT_CREATED=0
cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  fi
  find "$TEMPORARY" -depth -delete 2>/dev/null || true
  if [ "$OUTPUT_CREATED" -eq 1 ] && [ ! -f "$OUTPUT_DIRECTORY/SHA256SUMS" ]; then
    find "$OUTPUT_DIRECTORY" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM

network_snapshot() {
  {
    /usr/sbin/scutil --proxy
    /usr/sbin/scutil --dns
    /usr/sbin/netstat -rn -f inet | awk '$1 == "default" {print}'
    /usr/sbin/netstat -rn -f inet6 | awk '$1 == "default" {print}'
    /sbin/ifconfig -l
  }
}

SOURCE_BEFORE="$TEMPORARY/source-before.txt"
SOURCE_AFTER="$TEMPORARY/source-after.txt"
NETWORK_BEFORE="$TEMPORARY/network-before.txt"
NETWORK_AFTER="$TEMPORARY/network-after.txt"
"$ROOT/scripts/source_manifest.sh" >"$SOURCE_BEFORE"
network_snapshot >"$NETWORK_BEFORE"
SOURCE_SHA256=$(awk '$1 == "MANIFEST_SHA256" {print $2}' "$SOURCE_BEFORE")
RELEASE_TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

SIGNING_OVERRIDES="$TEMPORARY/AetherRouteSigning.xcconfig"
"$ROOT/scripts/generate_signing_overrides.sh" \
  "$SIGNING_CONFIG" "$SIGNING_OVERRIDES" >/dev/null
IDENTITY=$(jq -r '.developerIDIdentitySHA1 | ascii_upcase' "$SIGNING_CONFIG")

profile_uuid() {
  role=$1
  profile_path=$(jq -r --arg role "$role" \
    '.profiles[] | select(.role == $role) | .path' "$SIGNING_CONFIG")
  decoded="$TEMPORARY/$role.plist"
  security cms -D -i "$profile_path" >"$decoded" 2>/dev/null
  plutil -extract UUID raw -o - "$decoded"
}

HOST_PROFILE=$(profile_uuid direct-host)
TRANSPARENT_PROFILE=$(profile_uuid transparent-proxy)
TUNNEL_PROFILE=$(profile_uuid packet-tunnel)
{
  printf 'CODE_SIGN_STYLE = Manual\n'
  printf 'CODE_SIGN_IDENTITY = %s\n' "$IDENTITY"
  printf 'OTHER_CODE_SIGN_FLAGS = --timestamp\n'
  printf 'MARKETING_VERSION = %s\n' "$VERSION"
  printf 'CURRENT_PROJECT_VERSION = %s\n' "$BUILD_NUMBER"
  printf 'AETHERROUTE_RELEASE_CHANNEL = development\n'
  printf 'AETHERROUTE_RELEASE_TIMESTAMP = %s\n' "$RELEASE_TIMESTAMP"
  printf 'AETHERROUTE_HOST_PROFILE_SPECIFIER = %s\n' "$HOST_PROFILE"
  printf 'AETHERROUTE_TRANSPARENT_PROXY_PROFILE_SPECIFIER = %s\n' \
    "$TRANSPARENT_PROFILE"
  printf 'AETHERROUTE_PACKET_TUNNEL_PROFILE_SPECIFIER = %s\n' \
    "$TUNNEL_PROFILE"
} >>"$SIGNING_OVERRIDES"
chmod 600 "$SIGNING_OVERRIDES"

ARCHIVE="$TEMPORARY/AetherRoute.xcarchive"
BUILD_LOG="$TEMPORARY/archive.log"
if ! xcodebuild \
  -project "$ROOT/AetherRoute.xcodeproj" \
  -scheme AetherRoute \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$TEMPORARY/DerivedData" \
  -archivePath "$ARCHIVE" \
  -xcconfig "$SIGNING_OVERRIDES" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  archive >"$BUILD_LOG" 2>&1; then
  grep -nE '(^|[[:space:]])(error:|fatal error:)' "$BUILD_LOG" >&2 || true
  tail -160 "$BUILD_LOG" >&2
  exit 1
fi

APP="$ARCHIVE/Products/Applications/AetherRoute.app"
HOST_BUNDLE=$(jq -r \
  '.profiles[] | select(.role == "direct-host") | .bundleID' \
  "$SIGNING_CONFIG")
PACKET_BUNDLE=$(jq -r \
  '.profiles[] | select(.role == "packet-tunnel") | .bundleID' \
  "$SIGNING_CONFIG")
TRANSPARENT_BUNDLE=$(jq -r \
  '.profiles[] | select(.role == "transparent-proxy") | .bundleID' \
  "$SIGNING_CONFIG")
PACKET="$APP/Contents/Library/SystemExtensions/$PACKET_BUNDLE.systemextension"
TRANSPARENT="$APP/Contents/Library/SystemExtensions/$TRANSPARENT_BUNDLE.systemextension"
test -d "$APP" && test -d "$PACKET" && test -d "$TRANSPARENT"
test "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" \
  = "$HOST_BUNDLE"
test "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" \
  = "$BUILD_NUMBER"

for bundle in "$APP" "$PACKET" "$TRANSPARENT"; do
  codesign --verify --deep --strict --verbose=2 "$bundle"
  codesign -dv --verbose=4 "$bundle" 2>&1 \
    | grep -F 'Authority=Developer ID Application' >/dev/null
  codesign -dv --verbose=4 "$bundle" 2>&1 | grep -Eq 'flags=.*runtime'
  codesign -dv --verbose=4 "$bundle" 2>&1 | grep -F 'Timestamp=' >/dev/null
done
PRODUCTS_DIRECTORY=$(dirname -- "$APP")
"$ROOT/scripts/verify_product_metadata.sh" built "$PRODUCTS_DIRECTORY"
"$ROOT/scripts/verify_transparent_proxy_metadata.sh" built "$PRODUCTS_DIRECTORY"

MACH_O_MANIFEST="$TEMPORARY/mach-o-files.txt"
find "$APP" -type f -exec file {} \; \
  | awk -F ': ' '$2 ~ /^Mach-O/ {print $1}' >"$MACH_O_MANIFEST"
test -s "$MACH_O_MANIFEST"
while IFS= read -r executable; do
  architectures=$(lipo -archs "$executable")
  test "$architectures" = arm64 || {
    echo "test candidate contains non-arm64 Mach-O: $executable ($architectures)" >&2
    exit 1
  }
done <"$MACH_O_MANIFEST"

STAGE="$TEMPORARY/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/AetherRoute.app"
ln -s /Applications "$STAGE/Applications"
printf '%s\n' \
  'AetherRoute notarized test candidate.' \
  'This build is for signed cross-machine verification and is not production-approved.' \
  >"$TEMPORARY/README.txt"
cp "$TEMPORARY/README.txt" "$STAGE/测试版本说明.txt"

ARTIFACT_NAME="AetherRoute-$VERSION-build-$BUILD_NUMBER-arm64-Notarized-Test"
DMG="$TEMPORARY/$ARTIFACT_NAME.dmg"
hdiutil create \
  -volname "AetherRoute Test $VERSION" \
  -srcfolder "$STAGE" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

NOTARY_RESULT="$TEMPORARY/notary-result.json"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json >"$NOTARY_RESULT"
test "$(jq -r '.status' "$NOTARY_RESULT")" = Accepted || {
  jq '{id,status,message}' "$NOTARY_RESULT" >&2
  exit 1
}
SUBMISSION_ID=$(jq -r '.id' "$NOTARY_RESULT")
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature \
  --verbose=4 "$DMG"

mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -quiet
MOUNTED=1
INSTALLED_APP="$MOUNT_POINT/AetherRoute.app"
codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
spctl --assess --type execute --verbose=4 "$INSTALLED_APP"
test "$(plutil -extract CFBundleVersion raw -o - \
  "$INSTALLED_APP/Contents/Info.plist")" = "$BUILD_NUMBER"
hdiutil detach "$MOUNT_POINT" -quiet
MOUNTED=0

"$ROOT/scripts/source_manifest.sh" >"$SOURCE_AFTER"
network_snapshot >"$NETWORK_AFTER"
cmp -s "$SOURCE_BEFORE" "$SOURCE_AFTER" || {
  echo "source changed while building the notarized test candidate" >&2
  exit 1
}
cmp -s "$NETWORK_BEFORE" "$NETWORK_AFTER" || {
  echo "system network state changed while building the notarized test candidate" >&2
  exit 1
}

DMG_SHA256=$(shasum -a 256 "$DMG" | awk '{print $1}')
DMG_BYTES=$(stat -f '%z' "$DMG")
MANIFEST="$TEMPORARY/$ARTIFACT_NAME.json"
jq -n \
  --arg product AetherRoute \
  --arg author '陈艳男 (ChenYanNan)' \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg createdAt "$RELEASE_TIMESTAMP" \
  --arg architecture arm64 \
  --arg sourceManifestSHA256 "$SOURCE_SHA256" \
  --arg dmgSHA256 "$DMG_SHA256" \
  --arg notarySubmissionID "$SUBMISSION_ID" \
  --argjson dmgBytes "$DMG_BYTES" \
  '{schemaVersion: 1, releaseStatus: "notarized-test-candidate",
    product: $product, author: $author, version: $version, build: $build,
    createdAt: $createdAt, architecture: $architecture,
    safety: {productionApproved: false, networkActivatedDuringBuild: false,
      systemNetworkState: "unchanged"},
    sourceManifestSHA256: $sourceManifestSHA256,
    dmg: {sha256: $dmgSHA256, bytes: $dmgBytes},
    notarization: {status: "Accepted", submissionID: $notarySubmissionID}}' \
  >"$MANIFEST"

mkdir "$OUTPUT_DIRECTORY"
OUTPUT_CREATED=1
mv "$DMG" "$OUTPUT_DIRECTORY/$ARTIFACT_NAME.dmg"
mv "$MANIFEST" "$OUTPUT_DIRECTORY/$ARTIFACT_NAME.json"
cp "$SOURCE_BEFORE" "$OUTPUT_DIRECTORY/source-manifest.txt"
cp "$TEMPORARY/README.txt" "$OUTPUT_DIRECTORY/README.txt"
(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 "$ARTIFACT_NAME.dmg" "$ARTIFACT_NAME.json" \
    source-manifest.txt README.txt >SHA256SUMS
)
chmod 644 \
  "$OUTPUT_DIRECTORY/$ARTIFACT_NAME.dmg" \
  "$OUTPUT_DIRECTORY/$ARTIFACT_NAME.json" \
  "$OUTPUT_DIRECTORY/source-manifest.txt" \
  "$OUTPUT_DIRECTORY/README.txt" \
  "$OUTPUT_DIRECTORY/SHA256SUMS"

echo "Notarized test candidate passed: $OUTPUT_DIRECTORY/$ARTIFACT_NAME.dmg"
echo "Notary submission: $SUBMISSION_ID"
