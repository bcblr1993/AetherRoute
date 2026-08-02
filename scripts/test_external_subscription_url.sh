#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${AETHERROUTE_ALLOW_EXTERNAL_SUBSCRIPTION:-NO}" != "YES" ]; then
  echo "set AETHERROUTE_ALLOW_EXTERNAL_SUBSCRIPTION=YES for an authorized URL" >&2
  exit 64
fi
if [ "$#" -ne 0 ]; then
  echo "usage: printf '%s\\n' URL | $0" >&2
  exit 64
fi
IFS= read -r SUBSCRIPTION_URL || {
  echo "an HTTPS subscription URL is required on standard input" >&2
  exit 64
}

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-external-subscription-url.XXXXXX")
chmod 700 "$TEMP_DIR"
cleanup() {
  SUBSCRIPTION_URL=
  find "$TEMP_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

swiftc -parse-as-library \
  "$ROOT/Sources/AetherRouteKit/ProfileImportValidator.swift" \
  "$ROOT/Sources/AetherRouteKit/ProfileConfigurationSummary.swift" \
  "$ROOT/Sources/AetherRouteKit/AetherNode.swift" \
  "$ROOT/Sources/AetherRouteKit/SubscriptionPayloadNormalizer.swift" \
  "$ROOT/Sources/AetherRouteKit/ProfileSubscription.swift" \
  "$ROOT/Tests/ExternalSubscriptions/main.swift" \
  -o "$TEMP_DIR/subscription_fixture_verifier"

CANONICAL_PROFILE="$TEMP_DIR/canonical-profile.yaml"
printf '%s\n' "$SUBSCRIPTION_URL" \
  | "$TEMP_DIR/subscription_fixture_verifier" fetch "$CANONICAL_PROFILE"
SUBSCRIPTION_URL=

if [ -n "${AETHERROUTE_EXTERNAL_ASSET_DIR:-}" ]; then
  case "$AETHERROUTE_EXTERNAL_ASSET_DIR" in
    /*) ;;
    *) echo "AETHERROUTE_EXTERNAL_ASSET_DIR must be absolute" >&2; exit 64 ;;
  esac
  for ASSET in Country.mmdb GeoSite.dat; do
    if [ -f "$AETHERROUTE_EXTERNAL_ASSET_DIR/$ASSET" ]; then
      cp "$AETHERROUTE_EXTERNAL_ASSET_DIR/$ASSET" "$TEMP_DIR/$ASSET"
      chmod 600 "$TEMP_DIR/$ASSET"
    fi
  done
fi

"$ROOT/scripts/test_external_profiles.sh" "$CANONICAL_PROFILE"
printf '%s\n' \
  'Authorized HTTPS subscription verified on both cores with networking denied.'
