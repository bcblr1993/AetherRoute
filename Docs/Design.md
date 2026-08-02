# Interface design system

AetherRoute is a native macOS utility, not a web dashboard in an App shell.
SwiftUI, semantic system colors, SF Symbols, standard controls, and platform
typography are the default. The interface supports dark/light appearance,
keyboard focus, VoiceOver semantics, and Reduce Motion.

## Visual hierarchy

- A native resizable sidebar keeps the five primary destinations stable and
  inherits the user's system accent, row size, focus, and Liquid Glass behavior.
- The primary connection action lives in the system toolbar. The content layer
  begins with task content instead of imitating a second toolbar.
- Teal communicates an active, healthy data path. Orange is transitional, red
  is a failure, and secondary color is inactive or unavailable.
- Connection state comes only from the active Network Extension lifecycle and
  readiness signal. The interface never paints a successful state from a
  requested toggle value.
- The overview prioritizes connection state, routing mode, active profile, and
  current route. Telemetry remains blank rather than showing invented values.
- Content uses quiet semantic fills, 14-18 point continuous corners, hairline
  separation, and restrained elevation only around the connection focus.

## Motion and interaction

- Navigation uses a 280 ms snappy transition.
- Press feedback is 120 ms and disabled when Reduce Motion is enabled.
- The only repeating symbol effect is the connecting indicator, and it also
  respects Reduce Motion.
- Navigation is a native sidebar list with real buttons, keyboard shortcuts,
  focus behavior, and selected-state accessibility traits.

## Review boundary

The Debug-only `AETHERROUTE_UI_REVIEW` mode supplies deterministic sample state
without loading or saving NetworkExtension preferences.
`AETHERROUTE_UI_REVIEW_APPEARANCE` can force `light` or `dark` for deterministic
appearance review. `AETHERROUTE_UI_REVIEW_WINDOW` sets a deterministic point
size, `AETHERROUTE_UI_REVIEW_REDUCE_MOTION=1` removes review animation, and
`AETHERROUTE_UI_REVIEW_TEXT_SIZE=expanded` provides an expansion fixture. The
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
Its 30-image matrix covers every primary page plus all seven Settings pages,
English and Simplified Chinese, light and dark appearance, both network-engine
selectors, expanded text at the minimum window, and privacy onboarding. The
Settings capture waits for the separate Settings scene and rejects a main-window
substitute by requiring the expected window geometry. It refuses an existing output
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
verbatim user or engine data. The current `Localizable.strings` file is an
incremental translation resource; before declaring localization complete it
must be migrated key-for-key to a String Catalog and pass untranslated/stale-key
validation, pseudolocalization, and 30% text-expansion review at the 780 x 560
minimum window in light and dark appearances.
