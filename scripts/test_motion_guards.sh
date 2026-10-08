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
  BEGIN { $tokens = "quickFade|gentleSpring|panelSpring|pageEntrance|valueChange|disclosure|pressFeedback|switchToggle|attentionPulse" }
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

# Timing lives only in the token files. A hand-tuned curve elsewhere
# (`withAnimation(.easeInOut(duration: 1.2))`) drifts from the vocabulary in
# Docs/Design.md; add a token instead.
if find "$ROOT/Sources/AetherRouteApp" -name '*.swift' \
  ! -name 'AetherMotion.swift' ! -name 'AetherRouteVisualSystem.swift' -print0 | xargs -0 perl -ne '
  BEGIN { $curves = "easeIn|easeOut|easeInOut|spring|interpolatingSpring|linear|smooth|snappy|bouncy|default" }
  if (/withAnimation\(\.(?:$curves)\b/ || /\.animation\(\.(?:$curves)\b/ || /\bAnimation\.(?:$curves)\b/) {
    print "$ARGV:$.: $_"; $found = 1
  }
  close ARGV if eof;
  END { exit($found ? 1 : 0) }
'; then
  echo "Motion guards passed: no hand-tuned animation outside the motion tokens."
else
  echo "Hand-tuned animations are forbidden; add a token to AetherVisual (AetherMotion.swift) and use it." >&2
  exit 1
fi
