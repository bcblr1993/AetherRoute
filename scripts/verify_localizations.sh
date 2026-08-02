#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CATALOG="$ROOT/Sources/AetherRouteApp/Localizable.xcstrings"
LEGACY="$ROOT/Sources/AetherRouteApp/zh-Hans.lproj/Localizable.strings"

fail() {
  echo "Localization verification failed: $*" >&2
  exit 1
}

test -f "$CATALOG" || fail "Localizable.xcstrings is missing"
test ! -e "$LEGACY" || fail "legacy Localizable.strings still exists"

jq -e '
  .sourceLanguage == "en"
  and .version == "1.0"
  and (.strings | length >= 480)
  and ([.strings[] |
    .localizations["zh-Hans"].stringUnit.state == "translated"
    and (.localizations["zh-Hans"].stringUnit.value | length > 0)
  ] | all)
  and ([.strings[] | .extractionState? != "stale"] | all)
' "$CATALOG" >/dev/null || fail "catalog contains stale or untranslated entries"

for key in \
  'Overview' \
  'TUN' \
  'DNS & Fake-IP' \
  'Independent app runtime' \
  'About AetherRoute' \
  'Application language' \
  'Follow System' \
  'Language changes apply immediately throughout AetherRoute.'
do
  jq -e --arg key "$key" '.strings[$key] != null' "$CATALOG" >/dev/null \
    || fail "required key is missing: $key"
done

for removed in 'Direct + Store runtime' 'Store runtime'; do
  if jq -e --arg key "$removed" '.strings[$key] != null' "$CATALOG" >/dev/null; then
    fail "obsolete Store-specific key remains: $removed"
  fi
done

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-localizations.XXXXXX")
cleanup() {
  find "$TEMP_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

xcrun xcstringstool compile "$CATALOG" \
  --output-directory "$TEMP_DIR/compiled" \
  --language zh-Hans \
  --serialization-format text >/dev/null

# AppLanguageController deliberately resolves a previously extracted
# String.LocalizationValue against the user's selected bundle. Feeding that
# dynamic wrapper back into the literal-key extractor produces a misleading
# "non-literal key" warning, while the file contains no user-facing literals.
grep -Fq 'String(localized: value' \
  "$ROOT/Sources/AetherRouteApp/AppLanguageController.swift"
find "$ROOT/Sources/AetherRouteApp" -name '*.swift' \
  ! -name 'AppLanguageController.swift' -print0 \
  | xargs -0 xcrun xcstringstool extract \
      --modern-localizable-strings \
      --SwiftUI \
      --avoid-arg-placeholder \
      --output-format xcstrings \
      --output-directory "$TEMP_DIR/extracted" 2>/dev/null

jq -r '.strings | keys[]' "$CATALOG" | LC_ALL=C sort \
  > "$TEMP_DIR/catalog.keys"
jq -r '.strings | keys[]' "$TEMP_DIR/extracted/Localizable.xcstrings" \
  | awk 'length > 0' \
  | LC_ALL=C sort > "$TEMP_DIR/extracted.keys"
comm -23 "$TEMP_DIR/extracted.keys" "$TEMP_DIR/catalog.keys" \
  > "$TEMP_DIR/missing.keys"
if test -s "$TEMP_DIR/missing.keys"; then
  sed 's/^/Missing extracted key: /' "$TEMP_DIR/missing.keys" >&2
  fail "source contains keys absent from the catalog"
fi

count=$(jq '.strings | length' "$CATALOG")
printf 'Localization catalog verified: %s keys, en + zh-Hans\n' "$count"
