#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SIGNING_CONFIG=${1:-}
NOTARY_PROFILE=${2:-}
VERSION=${3:-}
BUILD_NUMBER=${4:-}
OUTPUT_DIRECTORY=${5:-}
notary_keychain=${AETHERROUTE_NOTARY_KEYCHAIN:-}

usage() {
  echo "usage: $0 /absolute/path/to/Signing.json notary-keychain-profile version build-number /absolute/output/directory" >&2
}

if [ -z "$SIGNING_CONFIG" ] || [ -z "$NOTARY_PROFILE" ] || \
   [ -z "$VERSION" ] || [ -z "$BUILD_NUMBER" ] || \
   [ -z "$OUTPUT_DIRECTORY" ]; then
  usage
  exit 64
fi
case "$SIGNING_CONFIG" in /*) ;; *) usage; exit 64 ;; esac
case "$OUTPUT_DIRECTORY" in /*) ;; *) usage; exit 64 ;; esac
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || {
  echo "version must use numeric major.minor or major.minor.patch form" >&2
  exit 64
}
printf '%s\n' "$BUILD_NUMBER" | grep -Eq '^[1-9][0-9]*$' || {
  echo "build number must be a positive integer" >&2
  exit 64
}
test -d "$OUTPUT_DIRECTORY" || {
  echo "output directory does not exist: $OUTPUT_DIRECTORY" >&2
  exit 1
}
if [ -n "$notary_keychain" ]; then
  case "$notary_keychain" in
    /*) ;;
    *) echo "AETHERROUTE_NOTARY_KEYCHAIN must be absolute" >&2; exit 64 ;;
  esac
  test -f "$notary_keychain" || {
    echo "configured notary Keychain is missing" >&2
    exit 66
  }
fi

for command in codesign ditto file git hdiutil jq lipo plutil realpath security \
  shasum spctl syspolicy_check xcodebuild xcrun; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "release requires $command" >&2
    exit 1
  }
done

license_service_url=${AETHERROUTE_LICENSE_SERVICE_URL:-}
update_manifest_url=${AETHERROUTE_UPDATE_MANIFEST_URL:-}
distribution_public_key=${AETHERROUTE_DISTRIBUTION_PUBLIC_KEY:-}
distribution_mode=${AETHERROUTE_DISTRIBUTION_MODE:-free}
soak_evidence_directory=${AETHERROUTE_SOAK_EVIDENCE_DIRECTORY:-}
signed_ne_evidence_directory=${AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY:-}
distribution_product_id=${AETHERROUTE_DISTRIBUTION_PRODUCT_ID:-$(
  jq -r '.profiles[] | select(.role == "direct-host") | .bundleID' \
    "$SIGNING_CONFIG"
)}
"$ROOT/scripts/verify_distribution_configuration.sh" \
  "$distribution_mode" "$distribution_product_id" \
  "$license_service_url" "$update_manifest_url" "$distribution_public_key"
test -n "$soak_evidence_directory" || {
  echo "stable release requires AETHERROUTE_SOAK_EVIDENCE_DIRECTORY" >&2
  exit 64
}
case "$soak_evidence_directory" in
  /*) ;;
  *) echo "AETHERROUTE_SOAK_EVIDENCE_DIRECTORY must be absolute" >&2; exit 64 ;;
esac
test -n "$signed_ne_evidence_directory" || {
  echo "stable release requires AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY" >&2
  exit 64
}
case "$signed_ne_evidence_directory" in
  /*) ;;
  *) echo "AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY must be absolute" >&2; exit 64 ;;
esac
update_signing_public_key_sha256=
if [ "$distribution_mode" = licensed ]; then
  update_signing_public_key_sha256=$(printf '%s' "$distribution_public_key" \
    | base64 -D | shasum -a 256 | awk '{print $1}')
fi

git -C "$ROOT" diff --quiet -- || {
  echo "stable release requires a clean source tree" >&2
  exit 1
}
git -C "$ROOT" diff --cached --quiet -- || {
  echo "stable release requires a clean source tree" >&2
  exit 1
}
test -z "$(git -C "$ROOT" ls-files --others --exclude-standard)" || {
  echo "stable release requires a clean source tree" >&2
  exit 1
}
release_branch=$(git -C "$ROOT" symbolic-ref --quiet --short HEAD || true)
test "$release_branch" = main || {
  echo "stable release candidates must be created from main" >&2
  exit 1
}
git_commit=$(git -C "$ROOT" rev-parse HEAD)
printf '%s\n' "$git_commit" | grep -Eq '^[0-9a-f]{40}$' || {
  echo "could not resolve the frozen release commit" >&2
  exit 1
}

artifact_name="AetherRoute-$VERSION-arm64"
final_dmg="$OUTPUT_DIRECTORY/$artifact_name.dmg"
final_manifest="$OUTPUT_DIRECTORY/$artifact_name.candidate.json"
test ! -e "$final_dmg" || {
  echo "refusing to overwrite existing release: $final_dmg" >&2
  exit 1
}
test ! -e "$final_manifest" || {
  echo "refusing to overwrite existing manifest: $final_manifest" >&2
  exit 1
}

"$ROOT/scripts/verify_release_soak_evidence.sh" "$soak_evidence_directory"
soak_evidence_sha256=$(shasum -a 256 \
  "$soak_evidence_directory/SHA256SUMS" | awk '{print $1}')
soak_duration_seconds=$(awk -F= \
  '$1 == "actual_duration_seconds" {print $2}' \
  "$soak_evidence_directory/result.txt")
soak_rounds=$(awk -F= '$1 == "rounds" {print $2}' \
  "$soak_evidence_directory/result.txt")
"$ROOT/scripts/verify_signed_network_extension_evidence.sh" \
  "$signed_ne_evidence_directory"
signed_ne_evidence_sha256=$(shasum -a 256 \
  "$signed_ne_evidence_directory/SHA256SUMS" | awk '{print $1}')
signed_ne_cycles=$(awk -F= '$1 == "cycles_per_engine" {print $2}' \
  "$signed_ne_evidence_directory/result.txt")

"$ROOT/scripts/signing_preflight.sh" "$SIGNING_CONFIG"
identity=$(jq -r '.developerIDIdentitySHA1 | ascii_upcase' "$SIGNING_CONFIG")
"$ROOT/scripts/verify_developer_id_private_key_access.sh" "$identity"
"$ROOT/scripts/bootstrap.sh"
if [ -n "$notary_keychain" ]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
    --keychain "$notary_keychain" --output-format json >/dev/null
else
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
    --output-format json >/dev/null
fi

submit_for_notarization() {
  artifact=$1
  result_path=$2
  if [ -n "$notary_keychain" ]; then
    xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARY_PROFILE" \
      --keychain "$notary_keychain" \
      --wait \
      --output-format json >"$result_path"
  else
    xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait \
      --output-format json >"$result_path"
  fi
  test "$(jq -r '.status' "$result_path")" = Accepted || {
    jq '{id,status,message}' "$result_path" >&2
    exit 1
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

temporary=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-release.XXXXXX")
mounted=0
mount_point="$temporary/mount"
cleanup() {
  if [ "$mounted" -eq 1 ]; then
    hdiutil detach "$mount_point" -quiet 2>/dev/null || true
  fi
  if [ -d "$temporary" ]; then
    find "$temporary" -depth -delete
  fi
}
trap cleanup EXIT HUP INT TERM

source_manifest_before="$temporary/source-before.txt"
source_manifest_after="$temporary/source-after.txt"
"$ROOT/scripts/source_manifest.sh" >"$source_manifest_before"
source_manifest_sha256=$(awk \
  '$1 == "MANIFEST_SHA256" {print $2}' "$source_manifest_before")
printf '%s\n' "$source_manifest_sha256" | grep -Eq '^[0-9a-f]{64}$' || {
  echo "could not resolve the frozen source manifest" >&2
  exit 1
}
AETHERROUTE_DERIVED_DATA_PATH="$temporary/ReleaseValidationDerivedData" \
  "$ROOT/scripts/test.sh"
"$ROOT/scripts/test_sanitizers.sh"
"$ROOT/scripts/source_manifest.sh" >"$source_manifest_after"
if ! cmp -s "$source_manifest_before" "$source_manifest_after"; then
  echo "source tree changed during release validation" >&2
  exit 1
fi

overrides="$temporary/AetherRouteRelease.xcconfig"
"$ROOT/scripts/generate_signing_overrides.sh" \
  "$SIGNING_CONFIG" "$overrides" >/dev/null

profile_uuid() {
  role=$1
  profile_path=$(jq -r --arg role "$role" \
    '.profiles[] | select(.role == $role) | .path' "$SIGNING_CONFIG")
  decoded="$temporary/$role.plist"
  security cms -D -i "$profile_path" >"$decoded" 2>/dev/null
  plutil -extract UUID raw -o - "$decoded"
}

host_profile=$(profile_uuid direct-host)
transparent_profile=$(profile_uuid transparent-proxy)
tunnel_profile=$(profile_uuid packet-tunnel)

home_directory=$(cd && pwd -P)
profile_is_installed() {
  uuid=$1
  for directory in \
    "$home_directory/Library/MobileDevice/Provisioning Profiles" \
    "$home_directory/Library/Developer/Xcode/UserData/Provisioning Profiles"
  do
    if [ -f "$directory/$uuid.provisionprofile" ] || \
       [ -f "$directory/$uuid.mobileprovision" ]; then
      return 0
    fi
  done
  return 1
}
for profile in "$host_profile" "$transparent_profile" "$tunnel_profile"; do
  profile_is_installed "$profile" || {
    echo "Developer ID provisioning profile is validated but not installed: $profile" >&2
    exit 2
  }
done

release_timestamp=${AETHERROUTE_RELEASE_TIMESTAMP:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}
printf '%s\n' "$release_timestamp" \
  | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || {
    echo "AETHERROUTE_RELEASE_TIMESTAMP must be UTC RFC 3339" >&2
    exit 64
  }

{
  printf 'CODE_SIGN_STYLE = Manual\n'
  printf 'CODE_SIGN_IDENTITY = %s\n' "$identity"
  printf 'OTHER_CODE_SIGN_FLAGS = --timestamp\n'
  printf 'MARKETING_VERSION = %s\n' "$VERSION"
  printf 'CURRENT_PROJECT_VERSION = %s\n' "$BUILD_NUMBER"
  printf 'AETHERROUTE_RELEASE_CHANNEL = stable\n'
  printf 'AETHERROUTE_RELEASE_TIMESTAMP = %s\n' "$release_timestamp"
  printf 'AETHERROUTE_DISTRIBUTION_PRODUCT_ID = %s\n' \
    "$distribution_product_id"
  printf 'AETHERROUTE_DISTRIBUTION_MODE = %s\n' "$distribution_mode"
  printf 'AETHERROUTE_LICENSE_SERVICE_URL = %s\n' "$license_service_url"
  printf 'AETHERROUTE_UPDATE_MANIFEST_URL = %s\n' "$update_manifest_url"
  printf 'AETHERROUTE_DISTRIBUTION_PUBLIC_KEY = %s\n' \
    "$distribution_public_key"
  printf 'AETHERROUTE_HOST_PROFILE_SPECIFIER = %s\n' "$host_profile"
  printf 'AETHERROUTE_TRANSPARENT_PROXY_PROFILE_SPECIFIER = %s\n' \
    "$transparent_profile"
  printf 'AETHERROUTE_PACKET_TUNNEL_PROFILE_SPECIFIER = %s\n' \
    "$tunnel_profile"
} >>"$overrides"
chmod 600 "$overrides"

archive="$temporary/AetherRoute.xcarchive"
build_log="$temporary/archive.log"
if ! xcodebuild \
  -project "$ROOT/AetherRoute.xcodeproj" \
  -scheme AetherRoute \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$temporary/DerivedData" \
  -archivePath "$archive" \
  -xcconfig "$overrides" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  archive >"$build_log" 2>&1; then
  tail -80 "$build_log" >&2
  exit 1
fi

app="$archive/Products/Applications/AetherRoute.app"
actual_product_id=$(plutil -extract CFBundleIdentifier raw -o - \
  "$app/Contents/Info.plist")
test "$actual_product_id" = "$distribution_product_id" || {
  echo "release product identifier differs from the signed host bundle" >&2
  exit 1
}
minimum_system_version=$(plutil -extract LSMinimumSystemVersion raw -o - \
  "$app/Contents/Info.plist")
printf '%s\n' "$minimum_system_version" \
  | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || {
  echo "release app contains an invalid minimum system version" >&2
  exit 1
}
packet_bundle=$(jq -r '.profiles[] | select(.role == "packet-tunnel") | .bundleID' \
  "$SIGNING_CONFIG")
transparent_bundle=$(jq -r \
  '.profiles[] | select(.role == "transparent-proxy") | .bundleID' \
  "$SIGNING_CONFIG")
packet="$app/Contents/Library/SystemExtensions/$packet_bundle.systemextension"
transparent="$app/Contents/Library/SystemExtensions/$transparent_bundle.systemextension"
for bundle in "$app" "$packet" "$transparent"; do
  test -d "$bundle"
  codesign --verify --deep --strict --verbose=2 "$bundle"
  codesign -dv --verbose=4 "$bundle" 2>&1 \
    | grep -F 'Authority=Developer ID Application' >/dev/null
  codesign -dv --verbose=4 "$bundle" 2>&1 \
    | grep -Eq 'flags=.*runtime'
  codesign -dv --verbose=4 "$bundle" 2>&1 \
    | grep -F 'Timestamp=' >/dev/null
  entitlements="$temporary/$(basename "$bundle").entitlements.plist"
  codesign -d --entitlements :- "$bundle" >"$entitlements" 2>/dev/null
  if [ "$(plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - \
    "$entitlements" 2>/dev/null || echo false)" = true ]; then
    echo "release bundle contains get-task-allow: $bundle" >&2
    exit 1
  fi
done

packet_entitlements="$temporary/$(basename "$packet").entitlements.plist"
if [ "$(plutil -extract 'com\.apple\.security\.network\.server' raw -o - \
  "$packet_entitlements" 2>/dev/null || echo false)" != true ]; then
  echo "packet tunnel is missing its loopback listener entitlement" >&2
  exit 1
fi
transparent_entitlements="$temporary/$(basename "$transparent").entitlements.plist"
if [ "$(plutil -extract 'com\.apple\.security\.network\.server' raw -o - \
  "$transparent_entitlements" 2>/dev/null || echo false)" != true ]; then
  echo "transparent proxy is missing its UDP receive entitlement" >&2
  exit 1
fi
for bundle in "$app"; do
  entitlements="$temporary/$(basename "$bundle").entitlements.plist"
  if plutil -extract 'com\.apple\.security\.network\.server' raw -o - \
    "$entitlements" >/dev/null 2>&1; then
    echo "network.server escaped the Network Extension boundary: $bundle" >&2
    exit 1
  fi
done

mach_o_manifest="$temporary/mach-o-files.txt"
find "$app" -type f -exec file {} \; \
  | awk -F ': ' '$2 ~ /^Mach-O/ { print $1 }' \
  >"$mach_o_manifest"
test -s "$mach_o_manifest" || {
  echo "release app contains no inspectable Mach-O files" >&2
  exit 1
}
mach_o_count=0
while IFS= read -r mach_o_file; do
  mach_o_count=$((mach_o_count + 1))
  architectures=$(lipo -archs "$mach_o_file")
  test "$architectures" = arm64 || {
    echo "release bundle contains non-arm64 Mach-O: $mach_o_file ($architectures)" >&2
    exit 1
  }
done <"$mach_o_manifest"
test "$mach_o_count" -ge 3 || {
  echo "release bundle architecture inventory is unexpectedly small: $mach_o_count" >&2
  exit 1
}

# sysextd validates the installed app, not merely the enclosing DMG. Submit a
# compact bootstrap DMG first and staple the app ticket so Network Extensions
# can activate even when the destination Mac cannot contact Apple's
# notarization service. The bootstrap DMG avoids unreliable large ZIP uploads.
app_notary_stage="$temporary/app-notary-stage"
app_notary_archive="$temporary/AetherRoute-app-notarization.dmg"
app_notary_result="$temporary/app-notary-result.json"
mkdir -p "$app_notary_stage"
ditto "$app" "$app_notary_stage/AetherRoute.app"
create_finalized_dmg \
  "$app_notary_archive" \
  "AetherRoute App Notarization" \
  "$app_notary_stage"
codesign --force --timestamp --sign "$identity" "$app_notary_archive"
submit_for_notarization "$app_notary_archive" "$app_notary_result"
app_submission_id=$(jq -r '.id' "$app_notary_result")
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=4 "$app"
syspolicy_check distribution "$app"

stage="$temporary/stage"
mkdir -p "$stage"
ditto "$app" "$stage/AetherRoute.app"
ln -s /Applications "$stage/Applications"
unsigned_dmg="$temporary/$artifact_name.dmg"
create_finalized_dmg \
  "$unsigned_dmg" \
  "AetherRoute $VERSION" \
  "$stage"
codesign --force --timestamp --sign "$identity" "$unsigned_dmg"

notary_result="$temporary/dmg-notary-result.json"
submit_for_notarization "$unsigned_dmg" "$notary_result"
dmg_submission_id=$(jq -r '.id' "$notary_result")
xcrun stapler staple "$unsigned_dmg"
xcrun stapler validate "$unsigned_dmg"
spctl --assess --type open --context context:primary-signature \
  --verbose=4 "$unsigned_dmg"

mkdir -p "$mount_point"
hdiutil attach "$unsigned_dmg" -readonly -nobrowse \
  -mountpoint "$mount_point" -quiet
mounted=1
installed_app="$mount_point/AetherRoute.app"
codesign --verify --deep --strict --verbose=2 "$installed_app"
xcrun stapler validate "$installed_app"
spctl --assess --type execute --verbose=4 "$installed_app"
syspolicy_check distribution "$installed_app"
hdiutil detach "$mount_point" -quiet
mounted=0

dmg_sha256=$(shasum -a 256 "$unsigned_dmg" | awk '{print $1}')
dmg_bytes=$(stat -f '%z' "$unsigned_dmg")
jq -n \
  --arg product AetherRoute \
  --arg author '陈艳男 (ChenYanNan)' \
  --arg productID "$distribution_product_id" \
  --arg version "$VERSION" \
  --argjson build "$BUILD_NUMBER" \
  --arg releasedAt "$release_timestamp" \
  --arg minimumSystemVersion "$minimum_system_version" \
  --arg architecture arm64 \
  --arg gitCommit "$git_commit" \
  --arg sourceManifestSHA256 "$source_manifest_sha256" \
  --arg updateSigningPublicKeySHA256 "$update_signing_public_key_sha256" \
  --arg distributionMode "$distribution_mode" \
  --arg sha256 "$dmg_sha256" \
  --arg appNotarySubmissionID "$app_submission_id" \
  --arg dmgNotarySubmissionID "$dmg_submission_id" \
  --arg soakEvidenceSHA256 "$soak_evidence_sha256" \
  --arg signedNEEvidenceSHA256 "$signed_ne_evidence_sha256" \
  --argjson bytes "$dmg_bytes" \
  --argjson soakDurationSeconds "$soak_duration_seconds" \
  --argjson soakRounds "$soak_rounds" \
  --argjson signedNECycles "$signed_ne_cycles" \
  '{schemaVersion: 1, releaseStatus: "notarized-candidate",
    product: $product, author: $author,
    productID: $productID,
    version: $version, build: $build, releasedAt: $releasedAt,
    minimumSystemVersion: $minimumSystemVersion,
    architecture: $architecture,
    source: {gitCommit: $gitCommit,
      manifestSHA256: $sourceManifestSHA256},
    distribution: {
      mode: $distributionMode,
      updateSigningPublicKeySHA256:
        (if $distributionMode == "free" then null else $updateSigningPublicKeySHA256 end)},
    dmg: {sha256: $sha256, bytes: $bytes},
    notarization: {status: "Accepted",
      submissionID: $dmgNotarySubmissionID,
      appSubmissionID: $appNotarySubmissionID,
      dmgSubmissionID: $dmgNotarySubmissionID,
      appTicketStapled: true, dmgTicketStapled: true},
    stability: {schema: 2, evidenceSHA256: $soakEvidenceSHA256,
      durationSeconds: $soakDurationSeconds, rounds: $soakRounds},
    signedRuntime: {schema: 1, evidenceSHA256: $signedNEEvidenceSHA256,
      engines: ["tun", "transparent"], cyclesPerEngine: $signedNECycles}}' \
  >"$temporary/release.json"

mv "$unsigned_dmg" "$final_dmg"
mv "$temporary/release.json" "$final_manifest"
echo "Notarized Developer ID candidate passed: $final_dmg"
echo "Candidate manifest: $final_manifest"
echo "Production promotion remains blocked until the exact DMG passes installed signed-runtime, leak, sleep/wake, path-change, and clean-machine gates."
