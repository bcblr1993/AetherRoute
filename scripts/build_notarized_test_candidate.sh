#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SIGNING_CONFIG=${1:-}
NOTARY_PROFILE=${2:-}
VERSION=${3:-}
BUILD_NUMBER=${4:-}
OUTPUT_DIRECTORY=${5:-}
NOTARY_KEYCHAIN=${AETHERROUTE_NOTARY_KEYCHAIN:-}
CORE_VARIANT=${AETHERROUTE_TEST_CORE_VARIANT:-diagnostics}
case "$CORE_VARIANT" in normal|diagnostics) ;; *)
  echo 'AETHERROUTE_TEST_CORE_VARIANT must be normal or diagnostics' >&2; exit 64 ;;
esac

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
if [ -n "$NOTARY_KEYCHAIN" ]; then
  case "$NOTARY_KEYCHAIN" in
    /*) ;;
    *) echo "AETHERROUTE_NOTARY_KEYCHAIN must be absolute" >&2; exit 64 ;;
  esac
  test -f "$NOTARY_KEYCHAIN" || {
    echo "configured notary Keychain is missing" >&2
    exit 66
  }
fi
test "$(uname -m)" = arm64 || {
  echo "notarized test candidates require Apple silicon" >&2
  exit 1
}
for command in codesign ditto file hdiutil jq lipo plutil realpath security \
  shasum spctl strings syspolicy_check xcodebuild xcrun; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "notarized test candidate requires $command" >&2
    exit 1
  }
done

"$ROOT/scripts/signing_preflight.sh" "$SIGNING_CONFIG"
SIGNING_CONFIG_SHA256=$(shasum -a 256 "$SIGNING_CONFIG" | awk '{print $1}')
IDENTITY=$(jq -r '.developerIDIdentitySHA1 | ascii_upcase' "$SIGNING_CONFIG")
"$ROOT/scripts/verify_developer_id_private_key_access.sh" "$IDENTITY"

# The shared policy first verifies the normal protocol archives. Normal keeps
# those bytes; diagnostics records its distinct actual archive hashes.
CORE_METADATA=$("$ROOT/scripts/test_candidate_core.sh" build "$CORE_VARIANT")
"$ROOT/scripts/generate_licenses.sh"
"$ROOT/scripts/verify_licenses.sh" source
"$ROOT/scripts/bootstrap.sh"
if [ -n "$NOTARY_KEYCHAIN" ]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
    --keychain "$NOTARY_KEYCHAIN" --output-format json >/dev/null
else
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
    --output-format json >/dev/null
fi

submit_for_notarization() {
  artifact=$1
  result_path=$2
  attempt=1
  while test "$attempt" -le 5; do
    output=
    if [ -n "$NOTARY_KEYCHAIN" ]; then
      if output=$(xcrun notarytool submit "$artifact" \
        --keychain-profile "$NOTARY_PROFILE" \
        --keychain "$NOTARY_KEYCHAIN" \
        --wait \
        --output-format json 2>&1); then
        printf '%s\n' "$output" >"$result_path"
        test "$(jq -r '.status' "$result_path")" = Accepted || {
          jq '{id,status,message}' "$result_path" >&2
          return 1
        }
        return 0
      fi
    else
      if output=$(xcrun notarytool submit "$artifact" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json 2>&1); then
        printf '%s\n' "$output" >"$result_path"
        test "$(jq -r '.status' "$result_path")" = Accepted || {
          jq '{id,status,message}' "$result_path" >&2
          return 1
        }
        return 0
      fi
    fi
    if test "$attempt" -lt 5 \
      && printf '%s\n' "$output" \
        | grep -Eiq 'abortedUpload|deadlineExceeded|HTTPClientError|timed out|network connection was lost|connection reset|temporarily unavailable|service unavailable'; then
      echo "Apple notarization upload unavailable; retrying submission ($attempt/5)" >&2
      attempt=$((attempt+1))
      sleep 15
      continue
    fi
    printf '%s\n' "$output" >&2
    return 1
  done
  return 1
}

bundle_cdhash() {
  codesign -dv --verbose=4 "$1" 2>&1 \
    | awk -F= '$1 == "CDHash" {print $2; exit}'
}

bundle_executable_sha256() {
  bundle=$1
  executable_name=$(plutil -extract CFBundleExecutable raw -o - \
    "$bundle/Contents/Info.plist")
  executable="$bundle/Contents/MacOS/$executable_name"
  test -x "$executable" || {
    echo "bundle executable is missing: $executable" >&2
    exit 1
  }
  shasum -a 256 "$executable" | awk '{print $1}'
}

codesign_with_timestamp_retry() {
  attempt=1
  while test "$attempt" -le 3; do
    output=
    if output=$(codesign --force --timestamp=http://timestamp.apple.com/ts01 \
      "$@" 2>&1); then
      test -z "$output" || printf '%s\n' "$output"
      return 0
    fi
    if test "$attempt" -lt 3 \
      && printf '%s\n' "$output" \
        | grep -Eiq 'timestamp service is not available'; then
      echo "Apple timestamp service unavailable; retrying codesign ($attempt/3)" >&2
      attempt=$((attempt+1))
      sleep 5
      continue
    fi
    printf '%s\n' "$output" >&2
    return 1
  done
  return 1
}

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

# macOS 26 can return from `hdiutil create` while its write-once DiskImages
# device still owns the destination. Passing that path directly to notarytool
# can then block in open(2), and detaching the device removes the write-once
# path. Always copy the completed bytes to an independent file, verify that
# copy as UDIF, and only then detach the private work image.
create_finalized_dmg() {
  finalized=$1
  volume_name=$2
  source_directory=$3
  case "$finalized" in
    *.dmg) write_once="${finalized%.dmg}.write-once.dmg" ;;
    *)
      echo "finalized DMG path must end in .dmg" >&2
      exit 1
      ;;
  esac
  test ! -e "$finalized" || {
    echo "refusing to overwrite finalized DMG: $finalized" >&2
    exit 1
  }
  test ! -e "$write_once" || {
    echo "refusing to overwrite write-once DMG: $write_once" >&2
    exit 1
  }

  hdiutil create \
    -volname "$volume_name" \
    -srcfolder "$source_directory" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$write_once" >/dev/null
  test -f "$write_once" && test ! -L "$write_once" || {
    echo "hdiutil did not produce a regular write-once DMG" >&2
    exit 1
  }
  ditto "$write_once" "$finalized"
  test -f "$finalized" && test ! -L "$finalized" || {
    echo "finalized DMG copy is invalid" >&2
    exit 1
  }
  hdiutil verify "$finalized" >/dev/null

  canonical_write_once=$(realpath "$write_once")
  attached_root=$(hdiutil info -plist \
    | plutil -convert json -o - - \
    | jq -r --arg raw "$write_once" --arg canonical "$canonical_write_once" '
        .images[]
        | select(
            ((."image-path" // "") | gsub("//"; "/")) == $raw
            or (."image-alias" // "") == $canonical
          )
        | ."system-entities"[]
        | select(."content-hint" == "GUID_partition_scheme")
        | ."dev-entry"
      ')
  case "$attached_root" in
    '') ;;
    /dev/disk[0-9]*)
      test "$(printf '%s\n' "$attached_root" | wc -l | tr -d ' ')" -eq 1 || {
        echo "write-once DMG resolved to multiple root devices" >&2
        exit 1
      }
      hdiutil detach "$attached_root" >/dev/null
      ;;
    *)
      echo "write-once DMG resolved to an invalid root device" >&2
      exit 1
      ;;
  esac
  hdiutil verify "$finalized" >/dev/null
}

SOURCE_BEFORE="$TEMPORARY/source-before.txt"
SOURCE_AFTER="$TEMPORARY/source-after.txt"
NETWORK_BEFORE="$TEMPORARY/network-before.txt"
NETWORK_AFTER="$TEMPORARY/network-after.txt"
"$ROOT/scripts/source_manifest.sh" >"$SOURCE_BEFORE"
"$ROOT/scripts/test_candidate_core.sh" bind "$CORE_VARIANT" "$SOURCE_BEFORE" "$CORE_METADATA"
network_snapshot >"$NETWORK_BEFORE"
SOURCE_SHA256=$(awk '$1 == "MANIFEST_SHA256" {print $2}' "$SOURCE_BEFORE")
RELEASE_TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

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
  # xcconfig treats // as a comment delimiter. The empty build-setting
  # expansion preserves the RFC 3161 URL as http:// in the codesign command.
  printf 'OTHER_CODE_SIGN_FLAGS = --timestamp=http:/$()/timestamp.apple.com/ts01\n'
  printf 'MARKETING_VERSION = %s\n' "$VERSION"
  printf 'CURRENT_PROJECT_VERSION = %s\n' "$BUILD_NUMBER"
  printf 'AETHERROUTE_RELEASE_CHANNEL = beta\n'
  # Distribution candidate: the Developer ID guard rejects the QA automation
  # fixture outright when this is set, so an unattended-connect build can never
  # be notarized by mistake.
  printf 'AETHERROUTE_NOTARIZED_CANDIDATE = YES\n'
  printf 'AETHERROUTE_RELEASE_TIMESTAMP = %s\n' "$RELEASE_TIMESTAMP"
  printf 'AETHERROUTE_HOST_PROFILE_SPECIFIER = %s\n' "$HOST_PROFILE"
  printf 'AETHERROUTE_TRANSPARENT_PROXY_PROFILE_SPECIFIER = %s\n' \
    "$TRANSPARENT_PROFILE"
  printf 'AETHERROUTE_PACKET_TUNNEL_PROFILE_SPECIFIER = %s\n' \
    "$TUNNEL_PROFILE"
} >>"$SIGNING_OVERRIDES"
chmod 600 "$SIGNING_OVERRIDES"

ARCHIVE=
BUILD_LOG=
archive_attempt=1
while test "$archive_attempt" -le 3; do
  candidate_archive="$TEMPORARY/AetherRoute-$archive_attempt.xcarchive"
  candidate_log="$TEMPORARY/archive-$archive_attempt.log"
  if xcodebuild \
    -project "$ROOT/AetherRoute.xcodeproj" \
    -scheme AetherRoute \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$TEMPORARY/DerivedData" \
    -archivePath "$candidate_archive" \
    -xcconfig "$SIGNING_OVERRIDES" \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    archive >"$candidate_log" 2>&1; then
    ARCHIVE=$candidate_archive
    BUILD_LOG=$candidate_log
    break
  fi
  archive_retryable=0
  if grep -Eiq 'timestamp service is not available' "$candidate_log"; then
    archive_retryable=1
  elif grep -Eq '^\*\* ARCHIVE FAILED \*\*$' "$candidate_log" \
    && grep -Eq '^[[:space:]]*CodeSign ' "$candidate_log"; then
    # Xcode occasionally suppresses the timestamp-service diagnostic and only
    # reports the affected CodeSign build command. A bounded clean archive
    # retry is safe; the final attempt still surfaces the complete build log.
    archive_retryable=1
  fi
  if test "$archive_attempt" -lt 3 && test "$archive_retryable" -eq 1; then
    echo "Apple signing service unavailable; retrying archive ($archive_attempt/3)" >&2
    archive_attempt=$((archive_attempt+1))
    sleep 5
    continue
  fi
  grep -nE '(^|[[:space:]])(error:|fatal error:)' "$candidate_log" >&2 || true
  tail -160 "$candidate_log" >&2
  exit 1
done
test -n "$ARCHIVE" && test -n "$BUILD_LOG" || {
  echo "archive retry budget exhausted" >&2
  exit 1
}

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
"$ROOT/scripts/test_candidate_core.sh" built "$CORE_VARIANT" "$APP"
test "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" \
  = "$HOST_BUNDLE"
test "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" \
  = "$BUILD_NUMBER"

"$ROOT/scripts/thin_sparkle_framework.sh" "$APP" "$IDENTITY"

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
"$ROOT/scripts/verify_licenses.sh" built "$PRODUCTS_DIRECTORY"

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

# Network Extensions are validated from the installed app bundle. A ticket
# stapled only to the outer DMG is insufficient on a Mac that cannot reach
# Apple's notarization service, and sysextd reports that case as code signature
# invalid. Submit a compact bootstrap DMG so Apple issues a ticket for the app,
# then staple the app before constructing the final DMG. This avoids unreliable
# large ZIP uploads while preserving independent app and final-DMG submissions.
APP_NOTARY_STAGE="$TEMPORARY/app-notary-stage"
APP_NOTARY_ARCHIVE="$TEMPORARY/AetherRoute-app-notarization.dmg"
APP_NOTARY_RESULT="$TEMPORARY/app-notary-result.json"
mkdir -p "$APP_NOTARY_STAGE"
ditto "$APP" "$APP_NOTARY_STAGE/AetherRoute.app"
create_finalized_dmg \
  "$APP_NOTARY_ARCHIVE" \
  "AetherRoute App Notarization" \
  "$APP_NOTARY_STAGE"
codesign_with_timestamp_retry \
  --sign "$IDENTITY" "$APP_NOTARY_ARCHIVE"
submit_for_notarization "$APP_NOTARY_ARCHIVE" "$APP_NOTARY_RESULT"
APP_SUBMISSION_ID=$(jq -r '.id' "$APP_NOTARY_RESULT")
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
syspolicy_check distribution "$APP"

STAGE="$TEMPORARY/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/AetherRoute.app"
ln -s /Applications "$STAGE/Applications"
printf '%s\n' \
  'AetherRoute notarized test candidate.' \
  'This build is for signed cross-machine verification and is not production-approved.' \
  "Core variant: $CORE_VARIANT. See the manifest for actual and protocol-reference hashes." \
  >"$TEMPORARY/README.txt"
cp "$TEMPORARY/README.txt" "$STAGE/测试版本说明.txt"

ARTIFACT_NAME="AetherRoute-$VERSION-build-$BUILD_NUMBER-arm64-Notarized-Test"
if [ "$CORE_VARIANT" = normal ]; then ARTIFACT_NAME="$ARTIFACT_NAME-Normal-Core"; fi
DMG="$TEMPORARY/$ARTIFACT_NAME.dmg"
create_finalized_dmg \
  "$DMG" \
  "AetherRoute Test $VERSION" \
  "$STAGE"
codesign_with_timestamp_retry \
  --sign "$IDENTITY" "$DMG"

NOTARY_RESULT="$TEMPORARY/dmg-notary-result.json"
submit_for_notarization "$DMG" "$NOTARY_RESULT"
DMG_SUBMISSION_ID=$(jq -r '.id' "$NOTARY_RESULT")
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature \
  --verbose=4 "$DMG"

mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -quiet
MOUNTED=1
INSTALLED_APP="$MOUNT_POINT/AetherRoute.app"
codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
xcrun stapler validate "$INSTALLED_APP"
spctl --assess --type execute --verbose=4 "$INSTALLED_APP"
syspolicy_check distribution "$INSTALLED_APP"
test "$(plutil -extract CFBundleVersion raw -o - \
  "$INSTALLED_APP/Contents/Info.plist")" = "$BUILD_NUMBER"
hdiutil detach "$MOUNT_POINT" -quiet
MOUNTED=0

APP_CDHASH=$(bundle_cdhash "$APP")
PACKET_CDHASH=$(bundle_cdhash "$PACKET")
TRANSPARENT_CDHASH=$(bundle_cdhash "$TRANSPARENT")
APP_EXECUTABLE_SHA256=$(bundle_executable_sha256 "$APP")
PACKET_EXECUTABLE_SHA256=$(bundle_executable_sha256 "$PACKET")
TRANSPARENT_EXECUTABLE_SHA256=$(bundle_executable_sha256 "$TRANSPARENT")
for value in "$APP_CDHASH" "$PACKET_CDHASH" "$TRANSPARENT_CDHASH"; do
  printf '%s\n' "$value" | grep -Eq '^[0-9a-f]{40}$' || {
    echo "bundle CDHash is invalid: $value" >&2
    exit 1
  }
done
for value in "$APP_EXECUTABLE_SHA256" "$PACKET_EXECUTABLE_SHA256" \
  "$TRANSPARENT_EXECUTABLE_SHA256"; do
  printf '%s\n' "$value" | grep -Eq '^[0-9a-f]{64}$' || {
    echo "bundle executable SHA256 is invalid: $value" >&2
    exit 1
  }
done

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
test "$(shasum -a 256 "$SIGNING_CONFIG" | awk '{print $1}')" \
  = "$SIGNING_CONFIG_SHA256" || {
  echo "signing configuration changed while building the notarized test candidate" >&2
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
  --argjson core "$CORE_METADATA" \
  --arg signingConfigurationSHA256 "$SIGNING_CONFIG_SHA256" \
  --arg hostBundleID "$HOST_BUNDLE" \
  --arg appCDHash "$APP_CDHASH" \
  --arg appExecutableSHA256 "$APP_EXECUTABLE_SHA256" \
  --arg packetBundleID "$PACKET_BUNDLE" \
  --arg packetCDHash "$PACKET_CDHASH" \
  --arg packetExecutableSHA256 "$PACKET_EXECUTABLE_SHA256" \
  --arg transparentBundleID "$TRANSPARENT_BUNDLE" \
  --arg transparentCDHash "$TRANSPARENT_CDHASH" \
  --arg transparentExecutableSHA256 "$TRANSPARENT_EXECUTABLE_SHA256" \
  --arg dmgSHA256 "$DMG_SHA256" \
  --arg appNotarySubmissionID "$APP_SUBMISSION_ID" \
  --arg dmgNotarySubmissionID "$DMG_SUBMISSION_ID" \
  --argjson dmgBytes "$DMG_BYTES" \
  '{schemaVersion: 1, releaseStatus: "notarized-test-candidate",
    product: $product, author: $author, version: $version, build: $build,
    createdAt: $createdAt, architecture: $architecture,
    safety: {productionApproved: false, networkActivatedDuringBuild: false,
      systemNetworkState: "unchanged", diagnosticsIncluded:$core.diagnosticsIncluded},
    core:$core,
    sourceManifestSHA256: $sourceManifestSHA256,
    signing: {configurationSHA256: $signingConfigurationSHA256,
      app: {bundleID: $hostBundleID, cdhash: $appCDHash,
        executableSHA256: $appExecutableSHA256},
      packetTunnel: {bundleID: $packetBundleID, cdhash: $packetCDHash,
        executableSHA256: $packetExecutableSHA256},
      transparentProxy: {bundleID: $transparentBundleID,
        cdhash: $transparentCDHash,
        executableSHA256: $transparentExecutableSHA256}},
    dmg: {sha256: $dmgSHA256, bytes: $dmgBytes},
    notarization: {status: "Accepted",
      submissionID: $dmgNotarySubmissionID,
      appSubmissionID: $appNotarySubmissionID,
      dmgSubmissionID: $dmgNotarySubmissionID,
      appTicketStapled: true, dmgTicketStapled: true}}' \
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
echo "App notary submission: $APP_SUBMISSION_ID"
echo "DMG notary submission: $DMG_SUBMISSION_ID"
