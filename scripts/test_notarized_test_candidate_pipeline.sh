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
  'scripts/generate_signing_overrides.sh' \
  'CODE_SIGN_STYLE = Manual' \
  'OTHER_CODE_SIGN_FLAGS = --timestamp' \
  'AETHERROUTE_RELEASE_CHANNEL = development' \
  'Authority=Developer ID Application' \
  'scripts/verify_product_metadata.sh' \
  'scripts/verify_transparent_proxy_metadata.sh' \
  'test candidate contains non-arm64 Mach-O' \
  'xcrun notarytool submit' \
  'xcrun stapler staple' \
  'spctl --assess --type open' \
  'spctl --assess --type execute' \
  'releaseStatus: "notarized-test-candidate"' \
  'productionApproved: false' \
  'networkActivatedDuringBuild: false' \
  'system network state changed while building' \
  'source changed while building' \
  'shasum -a 256' \
  'chmod 644'
do
  grep -F "$required" "$SCRIPT" >/dev/null || {
    echo "notarized test candidate pipeline is missing gate: $required" >&2
    exit 1
  }
done

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
