#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SIGNING_CONFIG=${1:-}
VERSION=${2:-}
BUILD_NUMBER=${3:-}
OUTPUT_DIRECTORY=${4:-}

usage() {
  echo "usage: $0 /absolute/Signing.json version build-number /absolute/new-output-directory" >&2
}

if [ -z "$SIGNING_CONFIG" ] || [ -z "$VERSION" ] \
  || [ -z "$BUILD_NUMBER" ] || [ -z "$OUTPUT_DIRECTORY" ]; then
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
  echo "refusing to overwrite local signed candidate output" >&2
  exit 1
}
test -d "$(dirname -- "$OUTPUT_DIRECTORY")" || {
  echo "local signed candidate output parent does not exist" >&2
  exit 1
}
test "$(uname -m)" = arm64 || {
  echo "local signed candidates require Apple silicon" >&2
  exit 1
}
for command in codesign ditto file jq lipo plutil security shasum strings xcodebuild; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "local signed candidate requires $command" >&2
    exit 1
  }
done

"$ROOT/scripts/signing_preflight.sh" "$SIGNING_CONFIG"
IDENTITY=$(jq -r '.developerIDIdentitySHA1 | ascii_upcase' "$SIGNING_CONFIG")
"$ROOT/scripts/verify_developer_id_private_key_access.sh" "$IDENTITY"

# Local QA candidates deliberately include privacy-safe numeric flow stages.
# Production release scripts retain the diagnostics-free default feature set.
AETHERROUTE_CORE_FEATURES='aether-flow-only,aether-diagnostics' \
  "$ROOT/scripts/build_core.sh" >/dev/null
AETHERROUTE_DIRECT_CORE_FEATURES='aether-embedded,aether-diagnostics' \
  "$ROOT/scripts/build_direct_core.sh" >/dev/null
strings "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" \
  | grep -F 'aether_flow stage=' >/dev/null || {
  echo "local signed candidate core is missing privacy-safe flow diagnostics" >&2
  exit 1
}
strings "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" \
  | grep -F 'aether_packet stage=' >/dev/null || {
  echo "local signed candidate Packet core is missing privacy-safe diagnostics" >&2
  exit 1
}
"$ROOT/scripts/bootstrap.sh"

TEMPORARY=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-signed-local.XXXXXX")
OUTPUT_CREATED=0
cleanup() {
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
CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

SIGNING_OVERRIDES="$TEMPORARY/AetherRouteSigning.xcconfig"
"$ROOT/scripts/generate_signing_overrides.sh" \
  "$SIGNING_CONFIG" "$SIGNING_OVERRIDES" >/dev/null
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
  printf 'AETHERROUTE_RELEASE_TIMESTAMP = %s\n' "$CREATED_AT"
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
FLOW_BRIDGE="$TRANSPARENT/Contents/Frameworks/AetherRouteFlowCoreBridge.framework/Versions/Current/AetherRouteFlowCoreBridge"
test -x "$FLOW_BRIDGE"
strings "$FLOW_BRIDGE" | grep -F 'aether_flow stage=' >/dev/null || {
  echo "local signed candidate dropped privacy-safe flow diagnostics" >&2
  exit 1
}
test "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" \
  = "$HOST_BUNDLE"
test "$(plutil -extract CFBundleShortVersionString raw -o - \
  "$APP/Contents/Info.plist")" = "$VERSION"
test "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" \
  = "$BUILD_NUMBER"

expected_profile_for_bundle() {
  bundle=$1
  case "$bundle" in
    "$APP") printf '%s\n' "$HOST_PROFILE" ;;
    "$PACKET") printf '%s\n' "$TUNNEL_PROFILE" ;;
    "$TRANSPARENT") printf '%s\n' "$TRANSPARENT_PROFILE" ;;
    *) return 1 ;;
  esac
}

for bundle in "$APP" "$PACKET" "$TRANSPARENT"; do
  codesign --verify --deep --strict --verbose=2 "$bundle"
  codesign -dv --verbose=4 "$bundle" 2>&1 \
    | grep -F 'Authority=Developer ID Application' >/dev/null
  codesign -dv --verbose=4 "$bundle" 2>&1 | grep -Eq 'flags=.*runtime'
  codesign -dv --verbose=4 "$bundle" 2>&1 | grep -F 'Timestamp=' >/dev/null
  entitlements="$TEMPORARY/$(basename "$bundle").entitlements.plist"
  codesign -d --entitlements :- "$bundle" >"$entitlements" 2>/dev/null
  if [ "$(plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - \
    "$entitlements" 2>/dev/null || echo false)" = true ]; then
    echo "local signed candidate contains get-task-allow: $bundle" >&2
    exit 1
  fi

  embedded="$bundle/Contents/embedded.provisionprofile"
  decoded="$TEMPORARY/$(basename "$bundle").embedded.plist"
  test -f "$embedded"
  security cms -D -i "$embedded" >"$decoded" 2>/dev/null
  test "$(plutil -extract UUID raw -o - "$decoded")" \
    = "$(expected_profile_for_bundle "$bundle")" || {
    echo "local signed candidate embedded an unexpected provisioning profile: $bundle" >&2
    exit 1
  }
  test "$(plutil -extract IsXcodeManaged raw -o - "$decoded" 2>/dev/null \
    || echo false)" = false || {
    echo "Xcode-managed Mac Team profile escaped into local signed candidate" >&2
    exit 1
  }
  test "$(plutil -extract ProvisionsAllDevices raw -o - "$decoded" 2>/dev/null \
    || echo false)" = true || {
    echo "local signed candidate profile is not Developer ID all-device" >&2
    exit 1
  }
done

verify_grant() {
  bundle=$1
  expected=$2
  entitlements="$TEMPORARY/$(basename "$bundle").entitlements.plist"
  plutil -extract 'com\.apple\.developer\.networking\.networkextension' json \
    -o - "$entitlements" \
    | jq -e --arg expected "$expected" 'index($expected) != null' >/dev/null
  test "$(plutil -extract 'com\.apple\.security\.network\.server' raw -o - \
    "$entitlements" 2>/dev/null || echo false)" = true || {
    echo "local signed Network Extension is missing network.server: $bundle" >&2
    exit 1
  }
}
verify_grant "$PACKET" packet-tunnel-provider-systemextension
verify_grant "$TRANSPARENT" app-proxy-provider-systemextension

"$ROOT/scripts/verify_product_metadata.sh" built "$(dirname -- "$APP")"
"$ROOT/scripts/verify_transparent_proxy_metadata.sh" built "$(dirname -- "$APP")"

MACH_O_MANIFEST="$TEMPORARY/mach-o-files.txt"
find "$APP" -type f -exec file {} \; \
  | awk -F ': ' '$2 ~ /^Mach-O/ {print $1}' >"$MACH_O_MANIFEST"
test -s "$MACH_O_MANIFEST"
while IFS= read -r executable; do
  architectures=$(lipo -archs "$executable")
  test "$architectures" = arm64 || {
    echo "local signed candidate contains non-arm64 Mach-O: $executable ($architectures)" >&2
    exit 1
  }
done <"$MACH_O_MANIFEST"

"$ROOT/scripts/source_manifest.sh" >"$SOURCE_AFTER"
network_snapshot >"$NETWORK_AFTER"
cmp -s "$SOURCE_BEFORE" "$SOURCE_AFTER" || {
  echo "source changed while building the local signed candidate" >&2
  exit 1
}
cmp -s "$NETWORK_BEFORE" "$NETWORK_AFTER" || {
  echo "system network state changed while building the local signed candidate" >&2
  exit 1
}

ARTIFACT_NAME="AetherRoute-$VERSION-build-$BUILD_NUMBER-arm64-Signed-Local-QA"
ZIP="$TEMPORARY/$ARTIFACT_NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
ZIP_SHA256=$(shasum -a 256 "$ZIP" | awk '{print $1}')
ZIP_BYTES=$(stat -f '%z' "$ZIP")
APP_CDHASH=$(codesign -dv --verbose=4 "$APP" 2>&1 \
  | awk -F= '$1 == "CDHash" {print $2; exit}')
printf '%s\n' "$APP_CDHASH" | grep -Eq '^[0-9a-fA-F]{40,64}$' || {
  echo "could not resolve the signed application CDHash" >&2
  exit 1
}
MANIFEST="$TEMPORARY/$ARTIFACT_NAME.json"
jq -n \
  --arg product AetherRoute \
  --arg author '陈艳男 (ChenYanNan)' \
  --arg version "$VERSION" \
  --arg build "$BUILD_NUMBER" \
  --arg createdAt "$CREATED_AT" \
  --arg architecture arm64 \
  --arg sourceManifestSHA256 "$SOURCE_SHA256" \
  --arg applicationCDHash "$(printf '%s' "$APP_CDHASH" | tr '[:upper:]' '[:lower:]')" \
  --arg zipSHA256 "$ZIP_SHA256" \
  --argjson zipBytes "$ZIP_BYTES" \
  '{schemaVersion: 1, releaseStatus: "signed-local-test-candidate",
    product: $product, author: $author, version: $version, build: $build,
    createdAt: $createdAt, architecture: $architecture,
    safety: {productionApproved: false, crossMachineApproved: false,
      networkActivatedDuringBuild: false, systemNetworkState: "unchanged"},
    sourceManifestSHA256: $sourceManifestSHA256,
    application: {cdHash: $applicationCDHash,
      signingAuthority: "Developer ID Application", notarized: false},
    zip: {sha256: $zipSHA256, bytes: $zipBytes},
    notarization: {status: "NotSubmitted"}}' >"$MANIFEST"

printf '%s\n' \
  'AetherRoute Developer ID signed local QA candidate.' \
  'It is not notarized, not approved for cross-machine distribution, and cannot be promoted to production.' \
  'Use only on this development Mac for real Transparent Proxy and TUN validation.' \
  >"$TEMPORARY/README.txt"

mkdir "$OUTPUT_DIRECTORY"
OUTPUT_CREATED=1
mv "$ZIP" "$OUTPUT_DIRECTORY/$ARTIFACT_NAME.zip"
mv "$MANIFEST" "$OUTPUT_DIRECTORY/$ARTIFACT_NAME.json"
cp "$SOURCE_BEFORE" "$OUTPUT_DIRECTORY/source-manifest.txt"
cp "$TEMPORARY/README.txt" "$OUTPUT_DIRECTORY/README.txt"
(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 "$ARTIFACT_NAME.zip" "$ARTIFACT_NAME.json" \
    source-manifest.txt README.txt >SHA256SUMS
)
chmod 644 "$OUTPUT_DIRECTORY"/*

echo "Developer ID signed local QA candidate passed: $OUTPUT_DIRECTORY/$ARTIFACT_NAME.zip"
echo "Production and cross-machine distribution remain blocked until notarization and release gates pass."

