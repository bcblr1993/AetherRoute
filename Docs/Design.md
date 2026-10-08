# Interface design system

AetherRoute is a native macOS utility, not a web dashboard in an App shell.
SwiftUI, semantic system colors, SF Symbols, standard controls, and platform
typography are the default. The interface supports dark/light appearance,
keyboard focus, VoiceOver semantics, and Reduce Motion.

## Visual hierarchy

- The window follows macOS 26 Liquid Glass. The content layer stays
  opaque, as Apple's guidelines ask (a translucent window let a bright
  wallpaper wash out secondary text and failed the contrast audit); the
  sidebar is a floating glass pane inset
  8 pt from the window edges with the window controls inside it; cards,
  buttons and segmented controls are glass. Every glass surface is the
  system's own (`glassEffect`, glass button styles, native segmented
  controls), so the person's Liquid Glass setting (clear or tinted) and
  Reduce Transparency apply to AetherRoute exactly as to Apple's apps. On
  macOS 15 the same surfaces fall back to the closest material.
- Pages read like System Settings: a large title and the page's actions on
  one line, no subtitle (the section's description stays with VoiceOver);
  groups of rows inside glass cards, each row a colour tile, a title, then
  the value or control on the trailing edge; a quiet section heading above a
  group and a short footnote below it.
- Colour tiles name things, never state: one colour per sidebar page,
  Settings pane, profile kind and proxy-group strategy.
- The connection switch is drawn, not a native toggle, on the overview and in
  the menu bar panel: the panel never activates the app, and AppKit draws a
  native switch grey there even when it is on. It stays a button named after
  its action ("Connect", "Disconnect", "Retry", "Cancel").
- Green communicates an active, healthy data path. Orange is transitional, red
  is a failure, and secondary color is inactive or unavailable. The blue brand
  gradient stays out of this vocabulary entirely; it carries identity, not
  state.
- Connection state comes only from the active Network Extension lifecycle and
  readiness signal. The interface never paints a successful state from a
  requested toggle value.
- The overview leads with the state (medallion, one large word, the switch),
  then live traffic, then the route group (exit node, routing mode, network
  engine, route check). Telemetry remains blank rather than showing invented
  values.
- Regions are named by text codes (SG, JP), not flags.

## Shared components

Each kind of element has one component and one set of tokens in
`AetherVisual`; `scripts/verify_ui_design_tokens.sh` rejects the usual ways
around them.

- **Icons.** `AetherIconTile` (a white symbol on a colour tile) names a thing;
  `AetherMonogramTile` does the same with a letter. `AetherStatusSymbol` (a
  coloured symbol, no tile) reports a state such as ready, stale or failed.
  A tinted translucent square is neither and is not used. Tiles take one of
  five sizes: `iconTileSize` 22 (sidebar, table cells), `rowTileSize` 26
  (System Settings rows; dividers start at `rowDividerInset`),
  `cardTileSize` 34 (cards, two-line rows), `sheetIconSize` 44 (sheet
  headers, onboarding) and `heroTileSize` 56 (one centred welcome).
- **Tile colours.** One per page (`AppSection.tileColor`), Settings pane,
  profile kind (`subscriptionTint`, `manualNodesTint`, `localProfileTint`)
  and setting. A sheet header takes the colour of what it is about.
- **Section headings.** The quiet System Settings heading: subheadline
  semibold in secondary text, inset `sectionHeaderInset` from the card, an
  optional count and trailing actions (`AetherSectionHeader`,
  `FeatureSection`). Card titles inside a card use `.headline`.
- **Empty states.** A page or section with nothing to show uses
  `FeatureEmptyState` (a card). A search that matches nothing, a list
  placeholder inside a sheet and an unselected detail pane use the native
  `ContentUnavailableView` on the surface they replace.
- **Pills and badges.** `StatePill` for state; other capsules use
  `pillHorizontalPadding`/`pillVerticalPadding`. Fills come from
  `neutralFill`, `tintFill(_:)`, `subtleFill`, `hoverFill` and
  `selectionFill`; inline messages use `aetherCallout(tint:)`.
- **Radii.** `panelRadius` for every card, `compactPanelRadius` for glass
  groups on compact surfaces (menu bar panel, Connections session bar),
  `cardRadius` or smaller for anything inside a card.
- **Sheets.** Small single-purpose sheets use `aetherSheetFrame()`; sheets
  holding a list, long form or document use `aetherLargeSheetFrame()`
  (a split sheet passes `splitSheetMinWidth`). Sheet content is inset
  `dialogPadding`.
- **Copy.** Interface strings go through `AppLocalization.string`, so the
  language chosen in Settings applies everywhere; names that are never
  translated use `Text(verbatim:)`.

## Motion and interaction

Motion explains what changed; it never makes the user wait. Every timing
comes from the tokens in `AetherVisual` (`AetherRouteVisualSystem.swift` and
`AetherMotion.swift`), and every piece of motion respects Reduce Motion: the
state still changes, only the travel is dropped.

| Token | Use |
|---|---|
| `pressFeedback` (120 ms ease-out) | Press dip and hover fades |
| `quickFade` (180 ms) | Status text, badges, icon swaps |
| `pageEntrance` (220 ms) | A page arriving after sidebar navigation |
| `valueChange` (spring 0.36 s) | Numbers rolling to a new value |
| `disclosure` (spring 0.3 s) | Disclosure chevrons and the content they reveal |
| `gentleSpring` (spring 0.32 s) | Layout and list changes, inline messages |
| `panelSpring` (spring 0.42 s) | Larger surfaces and the connection lens |
| `switchToggle` (spring 0.3 s) | The connection switch's knob |
| `attentionPulse` (1.2 s, repeating) | The menu bar's "new version" badge |

Shared pieces apply them the same way everywhere:

- `.aetherNumericValue(_:)` rolls the digits of traffic rates, counts and
  connection numbers instead of swapping the text.
- `.buttonStyle(.aetherPressable)` gives card-like and icon buttons a slight
  press dip; native bordered buttons keep their own feedback.
- `AetherDisclosureChevron` turns rather than swapping symbols, and the
  revealed content arrives with `AetherVisual.insertion`.
- `AetherVisual.insertion` brings rows and inline messages in from above and
  fades them out.
- `AetherCopyButton` confirms a copy by turning its symbol into a check mark
  for a moment.
- Latency results pop their status dot in as each measurement lands; progress
  spinners and icons cross-scale when work starts or ends.
- Only two things repeat: the connecting indicator (the orbiting arc of the
  connection lens and the luminous bar) and the menu bar's "new version"
  badge pulse. Both stop under Reduce Motion.
- Every animation goes through `AetherVisual.animation(_:)` (or reads
  `accessibilityReduceMotion`); a bare token such as
  `.animation(AetherVisual.quickFade, …)` ignores Reduce Motion.
- No curve is written outside `AetherMotion.swift` and
  `AetherRouteVisualSystem.swift`; `scripts/test_motion_guards.sh` rejects a
  hand-tuned `withAnimation(.easeInOut(…))` anywhere else.
- Navigation is a native sidebar list with real buttons, keyboard shortcuts,
  focus behavior, and selected-state accessibility traits.

## Review boundary

The Debug-only `AETHERROUTE_UI_REVIEW` mode supplies deterministic sample state
without loading or saving NetworkExtension preferences.
`AETHERROUTE_UI_REVIEW_APPEARANCE` can force `light` or `dark` for deterministic
appearance review. `AETHERROUTE_UI_REVIEW_WINDOW` sets a deterministic point
size and `AETHERROUTE_UI_REVIEW_REDUCE_MOTION=1` removes review animation.
Expanded-text tests and captures additionally launch the isolated app with
`-NSDoubleLocalizedStrings YES`: Apple's native Double-Length pseudolanguage
duplicates localized copy (100 percent text-length expansion). The older
`AETHERROUTE_UI_REVIEW_TEXT_SIZE=expanded` Dynamic Type environment alone does
not enlarge text on macOS and is not expansion evidence. The
`AetherRouteUIReview` scheme contains only the app and its UI tests as explicit
scheme entries. Xcode may compile the embedded provider as an app dependency,
but review mode never loads or launches it. All review branches are excluded
from Release builds.

`scripts/capture_ui_review.sh` launches that isolated fixture directly and
captures the owning process's window without XCUITest or macOS Automation Mode.
macOS Screen Recording permission is required by the launching terminal; the
script checks it before creating an output directory or starting a build and
fails with actionable guidance when the permission is absent.
Both this capture path and `scripts/test_ui.sh` copy the required source into a
new system temporary workspace, place DerivedData and the synthetic HOME there,
and share one UI-session lock. The reviewed app therefore never launches from
the repository in Documents, concurrent review processes cannot contaminate
one another, and every raw build/result directory is deleted on exit. The UI
test runner also applies that synthetic HOME, `CFFIXED_USER_HOME`, and `TMPDIR`
to `xcodebuild` itself, and refuses to start if the resolved temporary root is
inside Documents. Direct UI-test builds from a Documents checkout fail their
pre-build storage guard instead of presenting a protected-folder prompt.
Disconnected-idle profiling uses a separate
`AETHERROUTE_PERFORMANCE_MEASUREMENT` compilation condition on an optimized
Release build. It is never present in the standard product build. The fixture
forces an accepted, disconnected state and suppresses Network Extension,
subscription, license-refresh, notification, shortcut, and path-monitor work.
Its runner shares the UI-session lock, uses a distinct temporary bundle
identifier, rejects any app network socket, compares system-proxy snapshots,
and binds evidence to the complete source manifest. A standard product build
test also rejects the measurement environment string if it ever escapes the
compile-time boundary.
Its 55-image matrix covers every primary page plus every Settings page,
English and Simplified Chinese, light and dark appearance, both network-engine
selectors, expanded text at the minimum window, 800-point narrow windows,
the menu bar panel in its connected, disconnected and failed states, the
multi-group Proxies layout (`AETHERROUTE_UI_REVIEW_PROFILE=groups`), and
privacy onboarding. Each run writes `report.html`, a gallery of the images;
with `AETHERROUTE_UI_REVIEW_BASELINE` naming an earlier capture it compares
every image pixel by pixel and writes a diff image for each one that changed
(`scripts/ui_review_report.swift`). `Docs/DesignQA.md` is the checklist those
images are reviewed against and `Docs/PerformanceBudget.md` the performance
targets the interface keeps. The
Settings capture waits for the separate Settings scene and rejects a main-window
substitute by requiring the expected window geometry; Settings titles itself
after the open pane, so any titled window other than "AetherRoute" is a
candidate. It refuses an existing output
directory, terminates only the exact child process it launched, verifies every
PNG has credible dimensions and content size, and writes deterministic hashes
for every PNG, corresponding runtime log, and the complete source manifest.
An incomplete capture also removes its partial output directory; successful
output retains only the review images, bounded runtime logs, source manifest,
and their hashes, not the build log.
This is a visual-regression and manual-review artifact; it does not replace the
semantic accessibility audit or the signed Network Extension lifecycle gate.
XCUITest additionally requires macOS Automation Mode. The script checks
Developer Tools Security before copying source or starting a runner, exits 77
immediately when it is disabled, and retries one service-initialization timeout
only when it is enabled. It deliberately does not approve or dismiss system
authorization UI; Developer Tools Security remains a one-time host
administration decision.

## Localization boundary

English is the development language and `zh-Hans` is supported for the core
experience. Interface copy uses localization resources, while imported profile
names, hostnames, proxy names, rule tokens, and protocol identifiers remain
verbatim user or engine data. Product copy uses `Localizable.xcstrings` with
English source keys and Simplified Chinese translations. Before declaring
localization complete it must pass untranslated/stale-key validation,
pseudolocalization, and at least 30% text-expansion review at the
780 x 560 minimum window in light and dark appearances. The isolated runner
uses the stricter native Double-Length mode and asserts visibly duplicated
page landmarks. It does not change the product's default font sizes.
