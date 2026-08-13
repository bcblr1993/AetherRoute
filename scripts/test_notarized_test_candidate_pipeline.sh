#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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
  "AETHERROUTE_CORE_FEATURES='aether-flow-only,aether-diagnostics'" \
  "AETHERROUTE_DIRECT_CORE_FEATURES='aether-embedded,aether-diagnostics'" \
  "grep -F 'aether_flow stage='" \
  "grep -F 'aether_packet stage='" \
  'CODE_SIGN_STYLE = Manual' \
  'OTHER_CODE_SIGN_FLAGS = --timestamp' \
  'AETHERROUTE_RELEASE_CHANNEL = beta' \
  'Authority=Developer ID Application' \
  'scripts/verify_product_metadata.sh' \
  'scripts/verify_transparent_proxy_metadata.sh' \
  'test candidate contains non-arm64 Mach-O' \
  'xcrun notarytool submit' \
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
  'appTicketStapled: true, dmgTicketStapled: true' \
  'productionApproved: false' \
  'diagnosticsIncluded: true' \
  'networkActivatedDuringBuild: false' \
  'system network state changed while building' \
  'source changed while building' \
  'shasum -a 256' \
  'chmod 644'
do
  grep -F -- "$required" "$SCRIPT" >/dev/null || {
    echo "notarized test candidate pipeline is missing gate: $required" >&2
    exit 1
  }
done

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
