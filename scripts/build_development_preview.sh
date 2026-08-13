#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-}
if [ -z "$OUTPUT" ]; then
  echo "usage: $0 /absolute/development-preview-output-directory" >&2
  exit 64
fi
case "$OUTPUT" in
  /*) ;;
  *) echo "Development preview output must be absolute" >&2; exit 64 ;;
esac
test ! -e "$OUTPUT" || {
  echo "Refusing to overwrite development preview output: $OUTPUT" >&2
  exit 1
}
test -d "$(dirname "$OUTPUT")" || {
  echo "Development preview parent directory does not exist" >&2
  exit 1
}
if [ "$(uname -m)" != arm64 ]; then
  echo "Development preview requires Apple silicon" >&2
  exit 1
fi
for command in codesign file hdiutil jq lipo shasum xcodebuild; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Development preview requires $command" >&2
    exit 1
  }
done

TASK_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-development-preview.XXXXXX")
mounted=0
mount_point="$TASK_TEMP/mount"
cleanup() {
  if [ "$mounted" -eq 1 ]; then
    hdiutil detach "$mount_point" -quiet 2>/dev/null || true
  fi
  find "$TASK_TEMP" -depth -delete 2>/dev/null || true
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

source_before="$TASK_TEMP/source-before.txt"
source_after="$TASK_TEMP/source-after.txt"
network_before="$TASK_TEMP/network-before.txt"
network_after="$TASK_TEMP/network-after.txt"
"$ROOT/scripts/source_manifest.sh" >"$source_before"
network_snapshot >"$network_before"
source_sha=$(awk '$1 == "MANIFEST_SHA256" {print $2}' "$source_before")
short_sha=$(printf '%s' "$source_sha" | cut -c1-12)
timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
artifact_name="AetherRoute-UNSIGNED-UI-PREVIEW-$short_sha-arm64"

"$ROOT/scripts/bootstrap.sh"
if ! xcodebuild \
  -project "$ROOT/AetherRoute.xcodeproj" \
  -scheme AetherRoute \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$TASK_TEMP/DerivedData" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS= \
  CODE_SIGN_IDENTITY=- \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) AETHERROUTE_DEVELOPMENT_PREVIEW' \
  AETHERROUTE_BUNDLE_ID=com.aetherroute.preview \
  AETHERROUTE_ALLOW_ISOLATED_RELEASE_TEST_BUILD=YES \
  AETHERROUTE_RELEASE_CHANNEL=development \
  AETHERROUTE_RELEASE_TIMESTAMP="$timestamp" \
  build >"$TASK_TEMP/build.log" 2>&1; then
  grep -nE '(^|[[:space:]])(error:|fatal error:)' \
    "$TASK_TEMP/build.log" >&2 || true
  tail -160 "$TASK_TEMP/build.log" >&2
  exit 1
fi

app="$TASK_TEMP/DerivedData/Build/Products/Release/AetherRoute.app"
test -d "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$app/Contents/Info.plist")" = com.aetherroute.preview || {
  echo "Development preview has an unexpected product identifier" >&2
  exit 1
}
codesign --force --sign - --options runtime \
  --entitlements "$ROOT/Config/DevelopmentPreview.entitlements" \
  "$app"
codesign --verify --deep --strict --verbose=2 "$app"

app_info="$app/Contents/Info.plist"
tunnel_bundle=$(/usr/libexec/PlistBuddy -c \
  'Print :AetherRouteTunnelBundleIdentifier' "$app_info")
transparent_bundle=$(/usr/libexec/PlistBuddy -c \
  'Print :AetherRouteTransparentProxyBundleIdentifier' "$app_info")

mach_o_manifest="$TASK_TEMP/mach-o-files.txt"
find "$app" -type f -exec file {} \; \
  | awk -F ': ' '$2 ~ /^Mach-O/ {print $1}' >"$mach_o_manifest"
test -s "$mach_o_manifest"
while IFS= read -r executable; do
  architectures=$(lipo -archs "$executable")
  test "$architectures" = arm64 || {
    echo "Preview contains non-arm64 Mach-O: $executable ($architectures)" >&2
    exit 1
  }
done <"$mach_o_manifest"

for bundle in \
  "$app" \
  "$app/Contents/Library/SystemExtensions/$tunnel_bundle.systemextension" \
  "$app/Contents/Library/SystemExtensions/$transparent_bundle.systemextension"
do
  test -d "$bundle"
  codesign --verify --strict --verbose=2 "$bundle"
  entitlements="$TASK_TEMP/$(basename "$bundle").entitlements.plist"
  codesign -d --entitlements :- "$bundle" >"$entitlements" 2>/dev/null || true
  if grep -Fq 'com.apple.developer.networking.networkextension' "$entitlements"; then
    echo "Development preview unexpectedly retains Network Extension entitlement" >&2
    exit 1
  fi
done
preview_entitlements="$TASK_TEMP/preview-app.entitlements.plist"
codesign -d --entitlements :- "$app" >"$preview_entitlements" 2>/dev/null
test "$(/usr/libexec/PlistBuddy \
  -c 'Print :com.apple.security.cs.disable-library-validation' \
  "$preview_entitlements")" = true || {
  echo "Development preview is missing its ad-hoc library-validation exception" >&2
  exit 1
}

stage="$TASK_TEMP/stage"
mkdir -p "$stage"
ditto "$app" "$stage/AetherRoute.app"
cp "$ROOT/Docs/DevelopmentPreview.md" "$stage/开发预览说明.md"
ln -s /Applications "$stage/Applications"
dmg="$TASK_TEMP/$artifact_name.dmg"
hdiutil create \
  -volname "AetherRoute UI Preview" \
  -srcfolder "$stage" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$dmg" >/dev/null
codesign --force --sign - "$dmg"

mkdir -p "$mount_point"
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount_point" -quiet
mounted=1
test -d "$mount_point/AetherRoute.app"
test -f "$mount_point/开发预览说明.md"
codesign --verify --deep --strict --verbose=2 "$mount_point/AetherRoute.app"
hdiutil detach "$mount_point" -quiet
mounted=0

"$ROOT/scripts/source_manifest.sh" >"$source_after"
network_snapshot >"$network_after"
cmp -s "$source_before" "$source_after" || {
  echo "Source changed while building the development preview" >&2
  exit 1
}
cmp -s "$network_before" "$network_after" || {
  echo "System network state changed while building the development preview" >&2
  exit 1
}

dmg_sha=$(shasum -a 256 "$dmg" | awk '{print $1}')
dmg_bytes=$(stat -f '%z' "$dmg")
app_sha=$(shasum -a 256 "$app/Contents/MacOS/AetherRoute" | awk '{print $1}')
jq -n \
  --arg product AetherRoute \
  --arg author '陈艳男 (ChenYanNan)' \
  --arg createdAt "$timestamp" \
  --arg architecture arm64 \
  --arg sourceManifestSHA256 "$source_sha" \
  --arg dmgSHA256 "$dmg_sha" \
  --arg appExecutableSHA256 "$app_sha" \
  --argjson dmgBytes "$dmg_bytes" \
  '{schemaVersion: 1, releaseStatus: "unsigned-ui-preview",
    product: $product, author: $author, createdAt: $createdAt,
    architecture: $architecture,
    safety: {networkExtensionEntitlements: "removed",
      libraryValidation: "disabled-for-ad-hoc-preview-only",
      systemNetworkState: "unchanged", notarized: false,
      intendedUse: "UI and interaction review only"},
    sourceManifestSHA256: $sourceManifestSHA256,
    appExecutableSHA256: $appExecutableSHA256,
    dmg: {sha256: $dmgSHA256, bytes: $dmgBytes}}' \
  >"$TASK_TEMP/preview-manifest.json"

mkdir "$OUTPUT"
mv "$dmg" "$OUTPUT/$artifact_name.dmg"
mv "$TASK_TEMP/preview-manifest.json" "$OUTPUT/$artifact_name.json"
cp "$source_before" "$OUTPUT/source-manifest.txt"
cp "$ROOT/Docs/DevelopmentPreview.md" "$OUTPUT/README.md"
(
  cd "$OUTPUT"
  shasum -a 256 "$artifact_name.dmg" "$artifact_name.json" \
    source-manifest.txt README.md >SHA256SUMS
)
echo "Development UI preview passed: $OUTPUT/$artifact_name.dmg"
