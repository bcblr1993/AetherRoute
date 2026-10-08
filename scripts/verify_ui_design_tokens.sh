#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/Sources/AetherRouteApp"
CONNECTIONS="$APP/ConnectionsPageView.swift"

command -v rg >/dev/null 2>&1 || {
  echo "UI design-token verification requires ripgrep (rg). Install it with: brew install ripgrep" >&2
  exit 1
}

# Every rule runs and every violation is listed before the script fails.
# Stopping at the first one hid the rest: fixing it only revealed the next.
violations=0

fail_if_found() {
  description=$1
  pattern=$2
  shift 2
  if matches=$(rg -n -U "$pattern" "$APP" -g '*.swift' "$@"); then
    echo "UI design-token violation: $description" >&2
    printf '%s\n' "$matches" >&2
    violations=$((violations + 1))
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
  '\.padding\([^\n)]*(?<![0-9.])(15|18|22|26|28)(?![0-9.])[^\n)]*\)' \
  --pcre2

fail_if_found \
  "hard-coded light/dark text colors are forbidden; use primary/secondary/tertiary" \
  'foregroundStyle\([^)]*colorScheme[[:space:]]*==[[:space:]]*\.dark[[:space:]]*\?[^:]*white[^:]*:[^)]*black'

fail_if_found \
  "padding, spacing and radius must use AetherVisual tokens" \
  '\.(padding|cornerRadius)\([^\n)]*(?<![A-Za-z0-9_.])\d|cornerRadius:[[:space:]]*\d|spacing:[[:space:]]*[1-9][0-9]*' \
  --pcre2 -g '!AetherRouteVisualSystem.swift'

fail_if_found \
  "spacer minimums must use AetherVisual spacing tokens" \
  'minLength:[[:space:]]*[1-9][0-9]*'

fail_if_found \
  "corner radii must use a radius token (badge/control/inset/card/compactPanel/panel/sidebar), not a spacing token" \
  'cornerRadius:[[:space:]]*AetherVisual\.s(Micro|Compact|Row|[0-9])'

fail_if_found \
  "icon tiles take one of the five AetherVisual tile sizes" \
  '(AetherIconTile|AetherMonogramTile|AetherStatusSymbol|AetherRouteBrandTile)\([^)]*size:[[:space:]]*[0-9]'

fail_if_found \
  "drawn grey backgrounds use AetherVisual.subtleFill, hoverFill or neutralFill" \
  '\.background\([[:space:]]*Color\.(secondary|primary)\.opacity\(' \
  -g '!AetherRouteVisualSystem.swift'

fail_if_found \
  "interface copy goes through AppLocalization.string so the in-app language applies (use Text(verbatim:) for names)" \
  '\b(Text|Label|Button|Toggle|Section|Picker|TextField|SecureField|LabeledContent|help|accessibilityLabel|accessibilityHint|confirmationDialog)\([[:space:]]*"[^"]'

fail_if_found \
  "colour opacities come from AetherVisual fills (subtleFill, neutralFill, tintFill, tintWash, tintBorder ...)" \
  'Color\.[A-Za-z]+\.opacity\(' \
  -g '!AetherRouteVisualSystem.swift'

fail_if_found \
  "dividers use the system separator as is; do not fade them" \
  'Divider\(\)[^\n]*\.opacity\(|Divider\(\)\n[[:space:]]*\.opacity\(' \
  -g '!AetherRouteVisualSystem.swift'

fail_if_found \
  "row heights use AetherVisual.rowHeight, compactRowHeight, listRowHeight, tableRowHeight or twoLineRowHeight" \
  '\.frame\([^)]*minHeight:[[:space:]]*[1-9][0-9]*[,)]' \
  -g '!AetherRouteVisualSystem.swift'

fail_if_found \
  "state colours on text and symbols use AetherReadableTint or AetherInlineMessage, not the raw system colour" \
  '\.foregroundStyle\([[:space:]]*\.(red|orange|yellow|green)[[:space:]]*\)' \
  -g '!AetherRouteVisualSystem.swift'

fail_if_found \
  "literal font sizes are forbidden; use a system text style such as .caption or .body (sizes relative to a container are allowed)" \
  '\.system\([[:space:]]*size:[[:space:]]*[0-9]'

fail_if_found \
  "custom RGB colors are forbidden outside AetherVisual; use system semantic colors" \
  'Color\([[:space:]]*red:' \
  -g '!AetherRouteVisualSystem.swift'

fail_if_found \
  "shadows and glows are forbidden; use fills, separators and motion for emphasis" \
  '\.shadow\('

# The header must be localized *and* carry the column budget. Matching a bare
# "Duration" literal here meant the guard demanded the untranslated string, so
# localizing the header turned this into a false failure that blocked main even
# though the budget it exists to protect was untouched. The budget is
# 56/60/100: durations use the app-wide abbreviated format ("2小时11分钟",
# "49m 2s") and wrap onto a second line rather than widen the column, which
# 1.3.0 narrowed to make room for the source-app column.
if rg -Uq \
  'TableColumn\(AppLocalization\.string\("Duration"\)\)[^{]*\{[^}]*\}[[:space:]]*\.width\(min:[[:space:]]*56,[[:space:]]*ideal:[[:space:]]*60,[[:space:]]*max:[[:space:]]*100\)' \
  "$CONNECTIONS"; then
  :
else
  search_status=$?
  if [ "$search_status" -ne 1 ]; then
    echo "UI design-token verification failed: rg exited with status $search_status" >&2
    exit "$search_status"
  fi
  echo "UI design-token violation: the localized Duration header needs its 56...100pt column budget" >&2
  violations=$((violations + 1))
fi

if [ "$violations" -ne 0 ]; then
  echo "UI design-token verification failed: $violations rule(s) violated." >&2
  exit 1
fi

echo "UI design tokens verified."
