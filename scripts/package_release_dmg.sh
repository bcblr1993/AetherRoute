#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:-}
SIGNING_CONFIG=${2:-}
NOTARY_PROFILE=${3:-}
VERSION=${4:-}
BUILD_NUMBER=${5:-}
OUTPUT_DIRECTORY=${6:-}

usage() {
  cat << 'EOF' >&2
usage: package_release_dmg.sh /path/to/AetherRoute.app-or-candidate.dmg /absolute/path/to/Signing.json notary-profile version build-number /absolute/output-dir

Packages a clean, production-grade DMG without test markers or test explanation files.
EOF
}

if [ -z "$SOURCE" ] || [ -z "$SIGNING_CONFIG" ] || [ -z "$NOTARY_PROFILE" ] || \
   [ -z "$VERSION" ] || [ -z "$BUILD_NUMBER" ] || [ -z "$OUTPUT_DIRECTORY" ]; then
  usage
  exit 64
fi

case "$SIGNING_CONFIG" in /*) ;; *) usage; exit 64 ;; esac
case "$OUTPUT_DIRECTORY" in /*) ;; *) usage; exit 64 ;; esac
test -f "$SIGNING_CONFIG" || { echo "Signing config missing: $SIGNING_CONFIG" >&2; exit 66; }

for cmd in codesign ditto hdiutil jq plutil realpath security shasum spctl syspolicy_check xcrun; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

IDENTITY=$(jq -r '.developerIDIdentitySHA1 // empty' "$SIGNING_CONFIG")
test -n "$IDENTITY" || { echo "Signing config missing developerIDIdentitySHA1" >&2; exit 1; }

TEMPORARY=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-release-dmg.XXXXXX")
MOUNT_POINT="$TEMPORARY/mount"
STAGE="$TEMPORARY/stage"
IS_MOUNTED=0

cleanup() {
  set +e
  if [ "$IS_MOUNTED" -eq 1 ]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  fi
  rm -rf "$TEMPORARY" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$STAGE" "$MOUNT_POINT"

echo "==> Resolving AetherRoute.app from source: $SOURCE"
if [ -d "$SOURCE" ] && [ -f "$SOURCE/Contents/Info.plist" ]; then
  ditto "$SOURCE" "$STAGE/AetherRoute.app"
elif [ -f "$SOURCE" ]; then
  case "$SOURCE" in
    *.dmg)
      hdiutil attach "$SOURCE" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -quiet
      IS_MOUNTED=1
      test -d "$MOUNT_POINT/AetherRoute.app" || {
        echo "Source DMG does not contain AetherRoute.app" >&2
        exit 1
      }
      ditto "$MOUNT_POINT/AetherRoute.app" "$STAGE/AetherRoute.app"
      hdiutil detach "$MOUNT_POINT" -quiet
      IS_MOUNTED=0
      ;;
    *)
      echo "Source must be .app directory or .dmg file: $SOURCE" >&2
      exit 64
      ;;
  esac
else
  echo "Source not found: $SOURCE" >&2
  exit 66
fi

APP="$STAGE/AetherRoute.app"

echo "==> Verifying stapled Developer ID signatures on AetherRoute.app"
codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
syspolicy_check distribution "$APP"

APP_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
APP_BUILD=$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")
test "$APP_VERSION" = "$VERSION" || {
  echo "App version ($APP_VERSION) does not match expected version ($VERSION)" >&2
  exit 1
}
test "$APP_BUILD" = "$BUILD_NUMBER" || {
  echo "App build ($APP_BUILD) does not match expected build ($BUILD_NUMBER)" >&2
  exit 1
}

echo "==> Preparing pristine production DMG staging layout (Zero test notes)"
rm -f "$STAGE/测试版本说明.txt" "$STAGE/README.txt" "$STAGE/.DS_Store"
ln -s /Applications "$STAGE/Applications"

# Enforce Zero-test-note invariant
test ! -e "$STAGE/测试版本说明.txt" || {
  echo "FATAL: 测试版本说明.txt still present in release stage" >&2
  exit 1
}

DMG_NAME="AetherRoute-$VERSION-build-$BUILD_NUMBER-arm64.dmg"
VOLUME_NAME="AetherRoute $VERSION"
WRITE_ONCE_DMG="$TEMPORARY/${DMG_NAME%.dmg}.write-once.dmg"
FINAL_LOCAL_DMG="$TEMPORARY/$DMG_NAME"

echo "==> Building compressed DMG: volume name '$VOLUME_NAME'"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$WRITE_ONCE_DMG" >/dev/null

ditto "$WRITE_ONCE_DMG" "$FINAL_LOCAL_DMG"
hdiutil verify "$FINAL_LOCAL_DMG" >/dev/null

echo "==> Signing DMG with Developer ID"
codesign --force --timestamp=http://timestamp.apple.com/ts01 --sign "$IDENTITY" "$FINAL_LOCAL_DMG"

echo "==> Submitting DMG to Apple Notarization (profile: $NOTARY_PROFILE)..."
NOTARY_RESULT="$TEMPORARY/dmg-notary-result.json"
xcrun notarytool submit \
  "$FINAL_LOCAL_DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json >"$NOTARY_RESULT"

NOTARY_STATUS=$(jq -r '.status' "$NOTARY_RESULT")
test "$NOTARY_STATUS" = "Accepted" || {
  echo "Apple notarization failed: $NOTARY_STATUS" >&2
  cat "$NOTARY_RESULT" >&2
  exit 1
}

echo "==> Stapling notarization ticket to DMG"
xcrun stapler staple "$FINAL_LOCAL_DMG"
xcrun stapler validate "$FINAL_LOCAL_DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$FINAL_LOCAL_DMG"

echo "==> Verifying mounted production DMG contents"
hdiutil attach "$FINAL_LOCAL_DMG" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -quiet
IS_MOUNTED=1

test -d "$MOUNT_POINT/AetherRoute.app" || { echo "Mounted DMG missing AetherRoute.app" >&2; exit 1; }
test -L "$MOUNT_POINT/Applications" || { echo "Mounted DMG missing Applications symlink" >&2; exit 1; }
if [ -e "$MOUNT_POINT/测试版本说明.txt" ]; then
  echo "FATAL: Mounted production DMG contains '测试版本说明.txt'!" >&2
  exit 1
fi
if [ -e "$MOUNT_POINT/README.txt" ]; then
  echo "FATAL: Mounted production DMG contains 'README.txt'!" >&2
  exit 1
fi

hdiutil detach "$MOUNT_POINT" -quiet
IS_MOUNTED=0

mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DMG="$OUTPUT_DIRECTORY/$DMG_NAME"
mv "$FINAL_LOCAL_DMG" "$OUTPUT_DMG"

(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 "$DMG_NAME" > SHA256SUMS
)

DMG_SHA256=$(awk '{print $1}' "$OUTPUT_DIRECTORY/SHA256SUMS")
DMG_SIZE=$(stat -f '%z' "$OUTPUT_DMG")

echo "========================================================"
echo "✓ Production Release DMG packaged successfully!"
echo "  Path:     $OUTPUT_DMG"
echo "  Volume:   $VOLUME_NAME"
echo "  Size:     $DMG_SIZE bytes"
echo "  SHA256:   $DMG_SHA256"
echo "  Notary:   Accepted & Stapled"
echo "  Contents: Clean (Zero test notes, AetherRoute.app + Applications only)"
echo "========================================================"
