#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-dmg-upgrade.XXXXXX")
ACTIVE_MOUNT=
PHASE=initialization

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "DMG upgrade/rollback gate failed during phase: $PHASE" >&2
    if [ -n "$ACTIVE_MOUNT" ]; then
      printf '%s\n' "Active temporary mount at failure: $ACTIVE_MOUNT" >&2
    fi
  fi
  if [ -n "$ACTIVE_MOUNT" ]; then
    hdiutil detach "$ACTIVE_MOUNT" -quiet 2>/dev/null || true
  fi
  find "$TEMP_DIR" -depth -delete 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

build_app() {
  version=$1
  build=$2
  destination=$3
  log=$4
  if ! xcodebuild \
    -project "$ROOT/AetherRoute.xcodeproj" \
    -scheme AetherRoute \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$TEMP_DIR/DerivedData" \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build" \
    AETHERROUTE_RELEASE_CHANNEL=beta \
    AETHERROUTE_RELEASE_TIMESTAMP=2026-08-01T00:00:00Z \
    AETHERROUTE_ALLOW_ISOLATED_RELEASE_TEST_BUILD=YES \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS= \
    CODE_SIGN_IDENTITY=- \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) AETHERROUTE_DEVELOPMENT_PREVIEW' \
    build >"$log" 2>&1; then
    grep -nE '(^|[[:space:]])(error:|fatal error:)' "$log" >&2 || true
    tail -160 "$log" >&2
    return 1
  fi
  product="$TEMP_DIR/DerivedData/Build/Products/Release/AetherRoute.app"
  test -d "$product"
  ditto "$product" "$destination"
  codesign --verify --deep --strict "$destination"
}

verify_app() {
  app=$1
  version=$2
  build=$3
  app_info="$app/Contents/Info.plist"
  tunnel_bundle=$(/usr/libexec/PlistBuddy -c \
    'Print :AetherRouteTunnelBundleIdentifier' "$app_info")
  transparent_bundle=$(/usr/libexec/PlistBuddy -c \
    'Print :AetherRouteTransparentProxyBundleIdentifier' "$app_info")
  for bundle in \
    "$app" \
    "$app/Contents/Library/SystemExtensions/$transparent_bundle.systemextension" \
    "$app/Contents/Library/SystemExtensions/$tunnel_bundle.systemextension"
  do
    info="$bundle/Contents/Info.plist"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" = \
      "$version"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")" = \
      "$build"
    codesign --verify --deep --strict "$bundle"
  done

  manifest="$TEMP_DIR/mach-o-files.txt"
  find "$app" -type f -exec file {} \; \
    | awk -F ': ' '$2 ~ /^Mach-O/ { print $1 }' >"$manifest"
  test -s "$manifest"
  while IFS= read -r binary; do
    test "$(lipo -archs "$binary")" = arm64
  done <"$manifest"
}

make_dmg() {
  app=$1
  version=$2
  output=$3
  stage="$TEMP_DIR/stage-$version"
  mkdir -p "$stage"
  ditto "$app" "$stage/AetherRoute.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create \
    -volname "AetherRoute $version" \
    -srcfolder "$stage" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$output" >/dev/null
}

attach_dmg() {
  dmg=$1
  mount=$2
  mkdir -p "$mount"
  hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount" -quiet
  ACTIVE_MOUNT=$mount
  test -d "$mount/AetherRoute.app"
  test -L "$mount/Applications"
  test "$(readlink "$mount/Applications")" = /Applications
}

detach_active() {
  test -n "$ACTIVE_MOUNT"
  hdiutil detach "$ACTIVE_MOUNT" -quiet
  ACTIVE_MOUNT=
}

replace_installed_app() {
  source=$1
  target="$TEMP_DIR/Applications/AetherRoute.app"
  staged="$TEMP_DIR/Applications/.AetherRoute.app.new"
  previous="$TEMP_DIR/Applications/.AetherRoute.app.previous"
  test ! -e "$staged"
  test ! -e "$previous"
  ditto "$source" "$staged"
  codesign --verify --deep --strict "$staged"
  if [ -d "$target" ]; then
    mv "$target" "$previous"
  fi
  mv "$staged" "$target"
  if [ -d "$previous" ]; then
    find "$previous" -depth -delete
  fi
}

mkdir -p "$TEMP_DIR/v1" "$TEMP_DIR/v2" "$TEMP_DIR/Applications"
V1_APP="$TEMP_DIR/v1/AetherRoute.app"
V2_APP="$TEMP_DIR/v2/AetherRoute.app"
V1_DMG="$TEMP_DIR/AetherRoute-1.0.0-arm64.dmg"
V2_DMG="$TEMP_DIR/AetherRoute-1.0.1-arm64.dmg"

PHASE='building version 1.0.0'
build_app 1.0.0 100 "$V1_APP" "$TEMP_DIR/build-v1.log"
PHASE='verifying version 1.0.0'
verify_app "$V1_APP" 1.0.0 100
PHASE='building version 1.0.1'
build_app 1.0.1 101 "$V2_APP" "$TEMP_DIR/build-v2.log"
PHASE='verifying version 1.0.1'
verify_app "$V2_APP" 1.0.1 101
PHASE='creating version 1.0.0 DMG'
make_dmg "$V1_APP" 1.0.0 "$V1_DMG"
PHASE='creating version 1.0.1 DMG'
make_dmg "$V2_APP" 1.0.1 "$V2_DMG"

PHASE='creating external profile-data sentinel'
USER_DATA="$TEMP_DIR/UserData/Application Support/AetherRoute"
mkdir -p "$USER_DATA"
printf '%s\n' 'encrypted-profile-library-sentinel' >"$USER_DATA/profiles.enc"
SENTINEL_SHA=$(shasum -a 256 "$USER_DATA/profiles.enc" | awk '{print $1}')

PHASE='installing version 1.0.0 from DMG'
attach_dmg "$V1_DMG" "$TEMP_DIR/mount-v1-install"
replace_installed_app "$ACTIVE_MOUNT/AetherRoute.app"
verify_app "$TEMP_DIR/Applications/AetherRoute.app" 1.0.0 100
detach_active

PHASE='upgrading to version 1.0.1 from DMG'
attach_dmg "$V2_DMG" "$TEMP_DIR/mount-v2-upgrade"
replace_installed_app "$ACTIVE_MOUNT/AetherRoute.app"
verify_app "$TEMP_DIR/Applications/AetherRoute.app" 1.0.1 101
detach_active

PHASE='rolling back to version 1.0.0 from DMG'
attach_dmg "$V1_DMG" "$TEMP_DIR/mount-v1-rollback"
replace_installed_app "$ACTIVE_MOUNT/AetherRoute.app"
verify_app "$TEMP_DIR/Applications/AetherRoute.app" 1.0.0 100
detach_active

PHASE='verifying rollback cleanup and profile-data preservation'
test "$(shasum -a 256 "$USER_DATA/profiles.enc" | awk '{print $1}')" = \
  "$SENTINEL_SHA"
test ! -e "$TEMP_DIR/Applications/.AetherRoute.app.new"
test ! -e "$TEMP_DIR/Applications/.AetherRoute.app.previous"

printf '%s\n' \
  'Unsigned DMG install, 1.0.0→1.0.1 upgrade, rollback, arm64 inventory, and external profile-data preservation passed in a temporary root.'
