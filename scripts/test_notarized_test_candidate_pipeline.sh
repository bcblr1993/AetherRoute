#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

SOURCE_MANIFEST=$(
  "$ROOT/scripts/source_manifest.sh"
)
for required_build_input in \
  AetherRoute.xcodeproj/project.pbxproj \
  AetherRoute.xcodeproj/project.xcworkspace/contents.xcworkspacedata \
  AetherRoute.xcodeproj/xcshareddata/xcschemes/AetherRoute.xcscheme
do
  printf '%s\n' "$SOURCE_MANIFEST" \
    | grep -F "  $required_build_input" >/dev/null || {
      echo "source manifest omitted Xcode build input: $required_build_input" >&2
      exit 1
    }
done
printf '%s\n' "$SOURCE_MANIFEST" | grep -E 'xcuserdata|\.xcuserstate' \
  >/dev/null && {
    echo "source manifest included local Xcode user state" >&2
    exit 1
  }
SCRIPT="$ROOT/scripts/build_notarized_test_candidate.sh"

sh -n "$SCRIPT"
if "$SCRIPT" >/dev/null 2>&1; then
  echo "notarized test candidate script accepted missing inputs" >&2
  exit 1
fi

for required in \
  'scripts/signing_preflight.sh' \
  'scripts/verify_developer_id_private_key_access.sh' \
  'scripts/generate_signing_overrides.sh' \
  'AETHERROUTE_TEST_CORE_VARIANT:-diagnostics' \
  'scripts/test_candidate_core.sh" build "$CORE_VARIANT"' \
  'scripts/test_candidate_core.sh" built "$CORE_VARIANT" "$APP"' \
  'scripts/test_candidate_core.sh" bind "$CORE_VARIANT" "$SOURCE_BEFORE" "$CORE_METADATA"' \
  'core:$core' \
  'scripts/generate_licenses.sh' \
  'scripts/verify_licenses.sh" source' \
  'scripts/verify_licenses.sh" built' \
  'CODE_SIGN_STYLE = Manual' \
  'OTHER_CODE_SIGN_FLAGS = --timestamp=http:/$()/timestamp.apple.com/ts01' \
  'codesign --force --timestamp=http://timestamp.apple.com/ts01' \
  'codesign_with_timestamp_retry()' \
  'timestamp service is not available' \
  "grep -Eq '^[[:space:]]*CodeSign '" \
  'retrying archive' \
  'AETHERROUTE_RELEASE_CHANNEL = beta' \
  'Authority=Developer ID Application' \
  'scripts/verify_product_metadata.sh' \
  'scripts/verify_transparent_proxy_metadata.sh' \
  'test candidate contains non-arm64 Mach-O' \
  'xcrun notarytool submit' \
  'Apple notarization upload unavailable; retrying submission' \
  'while test "$attempt" -le 8' \
  'abortedUpload|deadlineExceeded|HTTPClientError' \
  'create_finalized_dmg' \
  'write_once="${finalized%.dmg}.write-once.dmg"' \
  'hdiutil verify "$finalized"' \
  'hdiutil detach "$attached_root"' \
  'write-once DMG resolved to multiple root devices' \
  'AetherRoute-app-notarization.dmg' \
  'app-notary-stage' \
  'app-notary-result.json' \
  'dmg-notary-result.json' \
  'AETHERROUTE_NOTARY_KEYCHAIN' \
  '--keychain "$NOTARY_KEYCHAIN"' \
  'xcrun stapler staple' \
  'xcrun stapler validate "$APP"' \
  'syspolicy_check distribution "$APP"' \
  'spctl --assess --type open' \
  'spctl --assess --type execute' \
  'releaseStatus: "notarized-test-candidate"' \
  'SIGNING_CONFIG_SHA256=$(shasum -a 256 "$SIGNING_CONFIG"' \
  'bundle_cdhash()' \
  'bundle_executable_sha256()' \
  'signing: {configurationSHA256: $signingConfigurationSHA256' \
  'packetTunnel: {bundleID: $packetBundleID, cdhash: $packetCDHash' \
  'transparentProxy: {bundleID: $transparentBundleID' \
  'appTicketStapled: true, dmgTicketStapled: true' \
  'productionApproved: false' \
  'diagnosticsIncluded:$core.diagnosticsIncluded' \
  'networkActivatedDuringBuild: false' \
  'system network state changed while building' \
  'source changed while building' \
  'signing configuration changed while building' \
  'shasum -a 256' \
  'chmod 644'
do
  grep -F -- "$required" "$SCRIPT" >/dev/null || {
    echo "notarized test candidate pipeline is missing gate: $required" >&2
    exit 1
  }
done

core_build_line=$(grep -nF \
  'scripts/test_candidate_core.sh" build "$CORE_VARIANT"' \
  "$SCRIPT" | cut -d: -f1)
license_generation_line=$(grep -nF \
  '"$ROOT/scripts/generate_licenses.sh"' "$SCRIPT" | cut -d: -f1)
license_gate_line=$(grep -nF \
  '"$ROOT/scripts/verify_licenses.sh" source' "$SCRIPT" | cut -d: -f1)
bootstrap_line=$(grep -nF '"$ROOT/scripts/bootstrap.sh"' "$SCRIPT" | cut -d: -f1)
license_built_line=$(grep -nF \
  '"$ROOT/scripts/verify_licenses.sh" built' "$SCRIPT" | cut -d: -f1)
signature_line=$(grep -nF \
  'codesign --verify --deep --strict --verbose=2 "$bundle"' "$SCRIPT" | cut -d: -f1)
package_line=$(grep -nF 'ditto "$APP" "$APP_NOTARY_STAGE/AetherRoute.app"' \
  "$SCRIPT" | cut -d: -f1)
if [ "$core_build_line" -ge "$license_generation_line" ] \
  || [ "$license_generation_line" -ge "$license_gate_line" ] \
  || [ "$license_gate_line" -ge "$bootstrap_line" ] \
  || [ "$signature_line" -ge "$license_built_line" ] \
  || [ "$license_built_line" -ge "$package_line" ]; then
  echo "core evidence and notices must be current before project generation and notarization" >&2
  exit 1
fi

keychain_test_temp=$(mktemp -d \
  "${TMPDIR:-/tmp}/aetherroute-notary-keychain-guard.XXXXXX")
trap 'find "$keychain_test_temp" -depth -delete 2>/dev/null || true' \
  EXIT HUP INT TERM
set +e
invalid_keychain_output=$(AETHERROUTE_NOTARY_KEYCHAIN=relative.keychain \
  "$SCRIPT" "$ROOT/Config/Signing.example.json" test-profile 1.0.0 100 \
  "$keychain_test_temp/output" 2>&1)
invalid_keychain_status=$?
set -e
test "$invalid_keychain_status" -eq 64 || {
  echo "notarized test candidate did not reject a relative notary Keychain" >&2
  exit 1
}
printf '%s\n' "$invalid_keychain_output" \
  | grep -F 'AETHERROUTE_NOTARY_KEYCHAIN must be absolute' >/dev/null || {
  echo "notarized test candidate did not identify the invalid notary Keychain" >&2
  exit 1
}

grep -F 'profile does not grant required App Group' \
  "$ROOT/scripts/signing_preflight.sh" >/dev/null || {
  echo "production signing preflight must reject profiles without the registered App Group" >&2
  exit 1
}

for forbidden in \
  'systemextensionsctl' \
  'launchctl' \
  'networksetup' \
  'scutil --set'
do
  if grep -F "$forbidden" "$SCRIPT" >/dev/null; then
    echo "notarized test candidate must not install, activate, or change networking: $forbidden" >&2
    exit 1
  fi
done
if grep -Eq '(cp|ditto|mv|install)[^\n]*/Applications(/|[[:space:]])' "$SCRIPT"; then
  echo "notarized test candidate must not write into /Applications" >&2
  exit 1
fi
if grep -Eq '(^|[[:space:]])(curl|scp|rsync|aws|rclone)[[:space:]]' "$SCRIPT"; then
  echo "notarized test candidate must not download, upload, or publish artifacts" >&2
  exit 1
fi

echo "Notarized cross-machine test candidate pipeline static tests passed."
