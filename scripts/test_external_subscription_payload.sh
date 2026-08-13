#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -ne 1 ]; then
  echo "usage: $0 /absolute/subscription-payload" >&2
  exit 64
fi

PAYLOAD=$1
case "$PAYLOAD" in
  /*) ;;
  *) echo "subscription payload path must be absolute" >&2; exit 64 ;;
esac
test -f "$PAYLOAD" && test -r "$PAYLOAD" || {
  echo "subscription payload is not a readable regular file" >&2
  exit 66
}

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-external-subscription.XXXXXX")
chmod 700 "$TEMP_DIR"
cleanup() {
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
"$TEMP_DIR/subscription_fixture_verifier" \
  normalize "$PAYLOAD" "$CANONICAL_PROFILE"

# A validated YAML provider body may reference local GeoIP/GeoSite data. Keep
# those read-only runtime inputs adjacent to the canonical temporary profile so
# the existing dual-core gate sees the same resources as the original fixture.
PAYLOAD_DIRECTORY=$(dirname -- "$PAYLOAD")
PAYLOAD_PARENT_DIRECTORY=$(dirname -- "$PAYLOAD_DIRECTORY")
for ASSET in Country.mmdb GeoSite.dat; do
  LOWERCASE_ASSET=$(printf '%s' "$ASSET" | tr '[:upper:]' '[:lower:]')
  for SOURCE in \
    "$PAYLOAD_DIRECTORY/$ASSET" \
    "$PAYLOAD_DIRECTORY/$LOWERCASE_ASSET" \
    "$PAYLOAD_PARENT_DIRECTORY/$ASSET" \
    "$PAYLOAD_PARENT_DIRECTORY/$LOWERCASE_ASSET"; do
    if [ -f "$SOURCE" ] && [ ! -L "$SOURCE" ]; then
      cp "$SOURCE" "$TEMP_DIR/$ASSET"
      chmod 600 "$TEMP_DIR/$ASSET"
      break
    fi
  done
done

"$ROOT/scripts/test_external_profiles.sh" "$CANONICAL_PROFILE"

printf '%s\n' \
  'External subscription payload verified on both cores with networking denied.'
