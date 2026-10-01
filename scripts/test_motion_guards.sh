#!/bin/sh
set -eu

# Every animation must respect Reduce Motion. A motion token used bare
# (`.animation(AetherVisual.quickFade, ...)` or
# `withAnimation(AetherVisual.gentleSpring)`) skips that check; it has to go
# through `AetherVisual.animation(_:)` instead. See Docs/Design.md.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# The look-behind keeps the wrapped form
# `AetherVisual.animation(AetherVisual.quickFade)` from matching itself.
if find "$ROOT/Sources/AetherRouteApp" -name '*.swift' -print0 | xargs -0 perl -ne '
  BEGIN { $tokens = "quickFade|gentleSpring|panelSpring|pageEntrance|valueChange|disclosure|pressFeedback" }
  if (/(?<!AetherVisual)\.animation\(AetherVisual\.(?:$tokens)[,)]/ || /withAnimation\(AetherVisual\.(?:$tokens)\)/) {
    print "$ARGV:$.: $_"; $found = 1
  }
  close ARGV if eof;
  END { exit($found ? 1 : 0) }
'; then
  echo "Motion guards passed: every motion token respects Reduce Motion."
else
  echo "Motion tokens must be wrapped in AetherVisual.animation(_:) so Reduce Motion applies." >&2
  exit 1
fi
