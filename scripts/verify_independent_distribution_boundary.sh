#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
  echo "Independent distribution boundary failed: $*" >&2
  exit 1
}

if /usr/bin/grep -R -E -n -i \
  '(^|[^A-Za-z])(import[[:space:]]+StoreKit|SKPayment|SKProduct|appStoreReceiptURL|_MASReceipt|com\.apple\.developer\.in-app-payments)' \
  "$ROOT/Sources" "$ROOT/Config" "$ROOT/project.yml" >/dev/null; then
  fail "a Mac App Store commerce or receipt API remains in the product"
fi

if /usr/bin/grep -R -E -n -i \
  '(3rd Party Mac Developer|Mac App Distribution|CODE_SIGN_IDENTITY.*Apple Distribution|method.*(app-store|mac-application))' \
  "$ROOT/Sources" "$ROOT/Config" "$ROOT/project.yml" \
  "$ROOT/scripts/release.sh" >/dev/null; then
  fail "a Mac App Store signing or export setting remains in the product"
fi

if /usr/bin/grep -R -E -n \
  'com\.apple\.product-type\.application\.on-demand-install-capable|com\.apple\.product-type\.watchkit|com\.apple\.product-type\.app-extension\.messages' \
  "$ROOT/project.yml" "$ROOT/Config" >/dev/null; then
  fail "an unrelated Store product type remains in the release graph"
fi

test -f "$ROOT/Sources/AetherRouteKit/IndependentDistribution.swift" \
  || fail "owner-operated licensing client is missing"
test -f "$ROOT/Sources/AetherRouteKit/VerifiedSoftwareUpdate.swift" \
  || fail "independent verified updater is missing"
test -x "$ROOT/scripts/release.sh" \
  || fail "Developer ID release entrypoint is missing or not executable"

/usr/bin/grep -F \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) AETHERROUTE_INDEPENDENT' \
  "$ROOT/project.yml" >/dev/null \
  || fail "the host target is not pinned to the independent distribution mode"

/usr/bin/grep -F 'outside the Mac App Store' "$ROOT/README.md" >/dev/null \
  || fail "README does not declare the independent distribution boundary"
/usr/bin/grep -F 'Developer ID Application' "$ROOT/scripts/release.sh" >/dev/null \
  || fail "release pipeline does not require Developer ID Application"
/usr/bin/grep -F 'notarytool submit' "$ROOT/scripts/release.sh" >/dev/null \
  || fail "release pipeline does not submit for notarization"

printf '%s\n' \
  'Independent distribution boundary verified: Developer ID + notarized DMG, independent build mode, no StoreKit, Store receipt, Store signing, or Store export path.'
