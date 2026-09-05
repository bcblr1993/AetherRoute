#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/Sources/AetherRouteApp"
CONNECTIONS="$APP/ConnectionsPageView.swift"

command -v rg >/dev/null 2>&1 || {
  echo "UI design-token verification requires ripgrep (rg). Install it with: brew install ripgrep" >&2
  exit 1
}

fail_if_found() {
  description=$1
  pattern=$2
  shift 2
  if matches=$(rg -n -U "$pattern" "$APP" -g '*.swift' "$@"); then
    echo "UI design-token violation: $description" >&2
    printf '%s\n' "$matches" >&2
    exit 1
  else
    search_status=$?
    if [ "$search_status" -ne 1 ]; then
      echo "UI design-token verification failed: rg exited with status $search_status" >&2
      exit "$search_status"
    fi
  fi
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

fail_if_found \
  "padding, spacing and radius must use AetherVisual tokens" \
  '\.(padding|cornerRadius)\([^\n)]*(?<![A-Za-z0-9_.])\d|cornerRadius:[[:space:]]*\d|spacing:[[:space:]]*[1-9][0-9]*' \
  --pcre2 -g '!AetherRouteVisualSystem.swift'

if rg -Uq \
  'TableColumn\("Duration"\)[^{]*\{[^}]*\}[[:space:]]*\.width\(min:[[:space:]]*64,[[:space:]]*ideal:[[:space:]]*68,[[:space:]]*max:[[:space:]]*76\)' \
  "$CONNECTIONS"; then
  :
else
  search_status=$?
  if [ "$search_status" -ne 1 ]; then
    echo "UI design-token verification failed: rg exited with status $search_status" >&2
    exit "$search_status"
  fi
  echo "UI design-token violation: the localized Duration header needs its 64...76pt column budget" >&2
  exit 1
fi

echo "UI design tokens verified."
