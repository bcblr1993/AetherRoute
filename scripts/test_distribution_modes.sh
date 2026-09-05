#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GATE="$ROOT/scripts/verify_distribution_configuration.sh"
PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
PRODUCT=com.aetherroute.desktop

expect_rejection() {
  if "$GATE" "$@" >/dev/null 2>&1; then
    echo "Distribution mode gate accepted invalid configuration" >&2
    exit 1
  fi
}
"$GATE" free "$PRODUCT" '' '' ''
"$GATE" licensed "$PRODUCT" https://license.example/v1/license \
  https://updates.example/stable.json "$PUBLIC_KEY"
expect_rejection licensed "$PRODUCT" '' '' ''
expect_rejection licensed "$PRODUCT" https://license.example/v1/license '' "$PUBLIC_KEY"
expect_rejection licensed "$PRODUCT" http://license.example/v1/license \
  https://updates.example/stable.json "$PUBLIC_KEY"
expect_rejection licensed "$PRODUCT" https://license.example/v1/license \
  https://updates.example/stable.json invalid
expect_rejection free "$PRODUCT" https://license.example/v1/license '' ''
expect_rejection free "$PRODUCT" '' https://updates.example/stable.json ''
expect_rejection free "$PRODUCT" '' '' "$PUBLIC_KEY"
expect_rejection development "$PRODUCT" '' '' ''
expect_rejection '' "$PRODUCT" '' '' ''
expect_rejection free 'invalid product' '' '' ''

TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-free-release-test.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
set +e
output=$(env -u AETHERROUTE_LICENSE_SERVICE_URL -u AETHERROUTE_UPDATE_MANIFEST_URL \
  -u AETHERROUTE_DISTRIBUTION_PUBLIC_KEY -u AETHERROUTE_SOAK_EVIDENCE_DIRECTORY \
  AETHERROUTE_DISTRIBUTION_MODE=free \
  "$ROOT/scripts/release.sh" "$ROOT/Config/Signing.example.json" test-notary \
  1.0.0 100 "$TEMP" 2>&1)
status=$?
set -e
test "$status" -eq 64
printf '%s\n' "$output" \
  | grep -F 'stable release requires AETHERROUTE_SOAK_EVIDENCE_DIRECTORY' >/dev/null
echo "Free and licensed distribution mode tests passed; free releases retain stability gates."
