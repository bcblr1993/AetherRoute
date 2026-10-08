# Interface review checklist

Every change to the interface passes this list before it is committed. The
screenshot matrix (`scripts/capture_ui_review.sh`) produces the images; this
list says what to look for in them. `Docs/Design.md` holds the rules the list
checks against.

## Run the matrix

```sh
# Before the change, on the parent commit: a baseline.
./scripts/capture_ui_review.sh outputs/ui-baseline-<date>
# After the change: a capture compared against it.
AETHERROUTE_UI_REVIEW_BASELINE="$PWD/outputs/ui-baseline-<date>" \
  ./scripts/capture_ui_review.sh outputs/ui-review-<date>
open outputs/ui-review-<date>/report.html
```

The report lists every screen as identical, changed (with the share of
changed pixels and a diff image), resized, new or removed. Every changed
screen must be one the change meant to touch. The matrix covers all main
pages and Settings pages, English and Simplified Chinese, light and dark,
the 780 x 560 minimum with doubled text length, 800-point narrow windows,
connection states, privacy onboarding and the menu bar panel.

## Layout

- [ ] Content edges line up: a card's text starts where the card above starts
      its text; icons share one column; trailing controls share one edge.
- [ ] Spacing comes from the 4-point scale (`AetherVisual.s1`...`s6`); no
      one-off numbers. Radii use the radius tokens, never a spacing token.
      `scripts/verify_ui_design_tokens.sh` (run by `scripts/test.sh`) lists
      every violation at once.
- [ ] One card style per surface; a disclosure, list or table sits on the same
      inset as the cards around it.
- [ ] Nothing clips or truncates at 800 points or at the minimum window with
      doubled text. Truncation that remains is deliberate, keeps the
      distinguishing part (head truncation for host names) and has a tooltip.
- [ ] Equal-width segmented controls keep their width when the selection moves.

## Typography and copy

- [ ] Type uses the defined styles; numbers that change use monospaced digits.
- [ ] English counts use plural rules from the string catalog, never "1 nodes".
- [ ] Counts, footers and hints share punctuation (no stray trailing period).
- [ ] No internal terms (core names, library names, struct names) in copy.
- [ ] Every new string has a reviewed Simplified Chinese translation.

## Color and state

- [ ] Green, orange and red mean healthy, transitional or slow, and failed;
      blue is the accent only. Download and upload keep their two hues.
- [ ] Every screen reads in light and dark; text meets 4.5:1 (3:1 at 18 pt+).
- [ ] A disabled control says why, inline or in its tooltip.
- [ ] Inactive-window rendering is acceptable: native controls lose their
      accent when the window is not key, and the menu bar panel never is key.

## Motion and interaction

- [ ] Animations use the motion tokens in `AetherVisual`; nothing hand-tuned.
- [ ] With Reduce Motion on, every animation becomes an instant change or a
      cross-fade; nothing repeats except the connecting indicator.
- [ ] Opening a window or page never moves focus into a text field, and never
      scrolls by itself.
- [ ] Every action has keyboard access and a visible focus ring; destructive
      actions can be undone or ask once.

## Accessibility

- [ ] Every control has a label; icon-only buttons have one too.
- [ ] Status changes (connected, failed, latency results) are announced.
- [ ] Accessibility identifiers used by UI tests are unchanged, or the tests
      change in the same commit.
