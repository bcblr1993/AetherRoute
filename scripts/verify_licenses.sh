#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPORT="$ROOT/Config/Licenses/ThirdPartyLicenses.json"
MODE=${1:-source}
PRODUCTS=${2:-}
"$ROOT/scripts/verify_bundled_routing_resources.sh"

jq -e '
  .schemaVersion == 1
  and .surface == "independent"
  and (.components | length > 0)
  and (.licenses | length > 0)
  and ([.components[] |
    (.name | length > 0)
    and (.version | length > 0)
    and (.license | length > 0)
  ] | all)
' "$REPORT" >/dev/null

# Validating the resource pack alone does not prove its notices reached the
# app's license browser. Require every bundled component and complete notice
# in the combined report, including attribution and source metadata.
jq -e --slurpfile bundled "$ROOT/Config/RoutingResources/notices.json" '
  . as $report |
  all($bundled[0].components[];
    . as $required | any($report.components[]; . == $required))
  and all($bundled[0].licenses[];
    . as $required | any($report.licenses[];
      .id == $required.id and .name == $required.name and .text == $required.text
      and (($required.components - .components) | length == 0)))
' "$REPORT" >/dev/null || {
  echo "Bundled routing component or complete notice is missing from $REPORT" >&2
  exit 1
}

if jq -er '.components[].license' "$REPORT" |
  grep -Eiq '(^|[^[:alpha:]])(GPL|AGPL|LGPL|MPL)([^[:alpha:]]|$)'; then
  echo "Forbidden copyleft runtime component in $REPORT" >&2
  exit 1
fi
if grep -Eq '(/Users/|/tmp/|source_path|manifest_path)' "$REPORT"; then
  echo "Build path leaked into $REPORT" >&2
  exit 1
fi

temp_components=$(mktemp "${TMPDIR:-/tmp}/aetherroute-components.XXXXXX")
temp_notices=$(mktemp "${TMPDIR:-/tmp}/aetherroute-notices.XXXXXX")
cleanup() {
  find "$temp_components" "$temp_notices" -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
jq -r '.components[] | "\(.name)@\(.version)"' "$REPORT" |
  LC_ALL=C sort -u > "$temp_components"
jq -r '.licenses[].components[]' "$REPORT" |
  LC_ALL=C sort -u > "$temp_notices"
if ! cmp -s "$temp_components" "$temp_notices"; then
  echo "Component-to-notice coverage is incomplete in $REPORT" >&2
  exit 1
fi

transparent_hash=$(shasum -a 256 \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" | awk '{print $1}')
packet_hash=$(shasum -a 256 \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" | awk '{print $1}')
test "$(jq -r '.coreArtifacts.transparentProxy' "$REPORT")" = \
  "$transparent_hash"
test "$(jq -r '.coreArtifacts.packetTunnel' "$REPORT")" = \
  "$packet_hash"

case "$MODE" in
  source)
    ;;
  built)
    test -n "$PRODUCTS"
    app="$PRODUCTS/AetherRoute.app"
    packaged="$app/Contents/Resources/ThirdPartyLicenses.json"
    test -f "$packaged"
    cmp -s "$REPORT" "$packaged"
    "$ROOT/scripts/verify_bundled_routing_resources.sh" \
      "$app/Contents/Resources/RoutingResources"
    test ! -e "$app/Contents/Resources/StoreThirdPartyLicenses.json"
    test ! -e "$app/Contents/Resources/DirectThirdPartyLicenses.json"
    ;;
  *)
    echo "Usage: $0 source|built [products-dir]" >&2
    exit 64
    ;;
esac

count=$(jq '.components | length' "$REPORT")
printf 'License notices verified: %s components (%s)\n' "$count" "$MODE"
