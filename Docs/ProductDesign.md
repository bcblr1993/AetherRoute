# AetherRoute product design contract

This document is the release contract for the native macOS experience. Visual
polish is not a substitute for truthful state: the interface may show
`Connected` only after the Network Extension reports ready, and it must leave
that state before shutdown begins.

## Native interaction model

- SwiftUI owns the window, menu-bar surface, settings, navigation, and
  accessibility tree. AppKit is used only where macOS lifecycle or window
  behavior requires it.
- The menu bar is the fastest path for connect/disconnect and routing mode. The
  main window is the inspection and configuration surface; neither duplicates
  destructive actions without confirmation.
- Standard macOS type, controls, focus rings, keyboard navigation, materials,
  semantic colors, and SF Symbols take precedence over custom drawing.
- The primary window uses `NavigationSplitView`, including the system sidebar
  toggle and user-resizable column. The sidebar owns navigation only; content
  panels never imitate navigation material.
- The minimum window is 780 x 560 points. Content must remain usable at the
  minimum size and expand without fixed-width clipping.
- Window size is stable within each task class. All six primary destinations
  share one main-window frame, and all seven Settings destinations share one
  Settings-window frame; navigation must never resize or reposition either
  window. Focused editors, confirmations, and import/export sheets use a
  smaller task-appropriate size instead of inheriting the main window.

## Brand and visual system

- The brand mark is Aether Lens: a nearly complete portal with a deliberate
  north-east opening, paired with a route that rises through the opening and
  terminates at a verified destination. The two-stroke silhouette and generous
  negative space communicate passage and direction without borrowing a shield,
  globe, lock, generic letterform, Apple mark, or Clash mark. The portal and
  destination remain distinct at 16 px and 32 px rather than collapsing into a
  decorative glow.
- `Sources/AetherRouteApp/AppIcon.icon` is the canonical system rendition. It
  keeps the background, portal, and route as separate opaque layers so current
  macOS can apply its own enclosure, depth, highlights, and material behavior.
  Default, Dark, Mono, Tinted Light/Dark, and Clear Light/Dark renditions must
  all export successfully through Apple's Icon Composer renderer.
- `scripts/generate_icon_composer_assets.swift` deterministically generates
  the two transparent 1024 px layer masks. `scripts/generate_app_icon.swift`
  generates the 16-1024 px asset-catalog fallback from the same geometry for
  previous macOS releases and non-system brand surfaces. The release gate
  compares decoded pixels and renders all seven system appearances at 16, 32,
  and 1024 px so Finder, Dock, menu, About, and DMG artwork may not silently
  diverge even when PNG encoder bytes differ between macOS versions.
- Cyan-to-indigo is identity, not decoration. It appears in the brand mark and
  a small number of active-route accents. Navigation selection, the toolbar,
  and focus keep the user's system accent and familiar platform behavior.

- Accent: the system accent for selection and focus. Cyan-to-indigo is reserved
  for AetherRoute identity; green is reserved for a verified active route.
- Status colors are semantic: teal for active, orange for transition or
  attention, red for failure, and secondary text for inactive state. Color is
  always paired with text and/or a symbol.
- Spacing follows a 4-point base rhythm. Primary gaps are 8, 12, 16, 20, 24,
  and 28 points. Cards use continuous 16-18 point corners; compact controls use
  9-10 points.
- Typography uses Dynamic Type-compatible system styles. Titles are not
  manually scaled; metadata never falls below `caption`.
- Light, dark, Increased Contrast, and Reduce Transparency appearances must
  remain legible. No status is encoded only by blur, opacity, or animation.
- System material is limited to navigation and control layers. Content panels
  use a quiet semantic fill and hairline separation; they do not stack custom
  glass effects.
- On newer macOS releases, native sidebar, toolbar, picker, and button controls
  inherit Liquid Glass automatically. AetherRoute does not add Liquid Glass to
  content cards or simulate it on older systems.

## Motion and responsiveness

- Direct manipulation feedback completes within 120 ms. Navigation uses a
  280 ms snappy transition and must be disabled when Reduce Motion is enabled.
- Connection animation represents only `.connecting`; it stops immediately on
  `.connected`, `.failed`, or `.disconnecting`.
- UI work stays on the main actor. Profile parsing, secure storage, provider
  preparation, and telemetry aggregation must not block a frame.
- Lists remain virtualized and bounded. Live counters update no faster than the
  user can perceive and must not cause the whole window to re-layout.

## State language

| Runtime state | Primary label | Allowed primary action |
| --- | --- | --- |
| Privacy not accepted | Privacy review required | Review privacy |
| Loading | Preparing | None |
| Disconnected | Not connected | Connect, when a valid profile exists |
| Connecting | Connecting | Cancel/disconnect |
| Connected | Traffic routing active | Disconnect |
| Disconnecting | Disconnecting | None |
| Failure | Unavailable | Retry after showing a privacy-safe reason |

Preview fixtures and screenshots must be explicitly isolated from production
state and must never call Network Extension APIs.

## Accessibility and localization gates

- Every release runs the macOS accessibility audit in both light and dark
  appearances, keyboard-only navigation, VoiceOver labels/hints, Reduce Motion,
  and Increased Contrast checks.
- Controls keep a minimum 28 x 28 point hit target; the primary connection
  action uses at least the large control size in compact surfaces.
- Text must tolerate at least 30 percent expansion before localization ships.
  Endpoint names truncate only after the user can reveal or copy the full value.
- Secret values are never exposed as accessibility labels, logs, screenshots,
  notification text, or pasteboard content without an explicit user action.
- English is the source language and Simplified Chinese (`zh-Hans`) is a
  first-class supported locale. Product copy is localized; profile names,
  endpoint names, domains, and protocol identifiers remain source data and are
  not translated.
- General settings expose an explicit application-language picker with Follow
  System, Simplified Chinese, and English. The visible interface changes
  immediately without a relaunch. About shows `陈艳男` in Chinese and
  `ChenYanNan` in English.
- Before localization is declared complete, migrate the existing localization
  keys to `Localizable.xcstrings` without renaming them. The release gate rejects
  stale or untranslated keys, then exercises Xcode pseudolocalization and 30%
  text expansion at 780 x 560 points in every primary view.
- Visual and accessibility evidence is language-specific. Capture all primary
  views and runtime states in English and Simplified Chinese, and run the
  accessibility audit under each language rather than inferring one locale from
  the other.

## Visual release evidence

For each candidate build, capture the onboarding, overview, proxies,
connections, profiles, rules, menu-bar, settings, empty, loading, connected,
disconnecting, and failure states in light and dark appearances. Compare them
at the same window size, run the accessibility audit, and reject unexplained
pixel or hierarchy changes. A polished preview is design evidence only; signed
Network Extension readiness is separate runtime evidence.

System material must be captured through the macOS compositor. An offscreen
`bitmapImageRep` that omits vibrancy is rejected as visual evidence rather than
treated as a product regression.

AetherRoute must show the selected traffic-capture engine beside the primary
connection state. TUN is never hidden in an advanced menu: the user can
distinguish Transparent Proxy from Packet Tunnel before connecting, and the
selector is locked while a session is active.

The General settings surface keeps the optional local proxy adjacent to the
traffic-capture selector. It names HTTP and SOCKS5 separately, always renders
the literal `127.0.0.1` endpoints, explains that macOS system proxy settings
are untouched, and enables port editing only while disconnected in TUN mode.
Shell environment and clear actions are explicit copy operations with visible
feedback; no copied command executes automatically.

Settings use a persistent native sidebar for General, Privacy, Bypass,
Diagnostics, Account, Open Source Licenses, and About. A crowded toolbar-style
tab strip is rejected because localized labels must remain readable without
truncation at the settings window's supported size.

## Apple design references

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
