#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/Sources/AetherRouteApp"

fail_if_found() {
  description=$1
  pattern=$2
  matches=$(rg -n -U "$pattern" "$APP" -g '*.swift' || true)
  test -z "$matches" || {
    echo "UI design-token violation: $description" >&2
    printf '%s\n' "$matches" >&2
    exit 1
  }
}

fail_if_found \
  "aetherPanel owns the only card radius and cannot accept overrides" \
  'aetherPanel\([[:space:]]*[^[:space:)]]'

fail_if_found \
  "legacy 13-22pt card radii are forbidden; use AetherVisual control/inset/panel tokens" \
  '(cornerRadius:|cornerRadius\()[[:space:]]*(13|14|15|16|17|18|19|20|21|22)([^0-9]|$)'

fail_if_found \
  "off-grid 15/18/22/26/28pt padding is forbidden" \
  '\.padding\([^\n)]*(15|18|22|26|28)([^0-9]|$)[^\n)]*\)'

fail_if_found \
  "hard-coded light/dark text colors are forbidden; use primary/secondary/tertiary" \
  'foregroundStyle\([^)]*colorScheme[[:space:]]*==[[:space:]]*\.dark[[:space:]]*\?[^:]*white[^:]*:[^)]*black'

bare_values=$(rg --pcre2 -n \
  '\.(padding|cornerRadius)\([^\n)]*(?<![A-Za-z0-9_.])\d|cornerRadius:[[:space:]]*\d|spacing:[[:space:]]*[1-9][0-9]*' \
  "$APP" -g '*.swift' -g '!AetherRouteVisualSystem.swift' || true)
test -z "$bare_values" || {
  echo "UI design-token violation: padding, spacing and radius must use AetherVisual tokens" >&2
  printf '%s\n' "$bare_values" >&2
  exit 1
}

echo "UI design tokens verified."
