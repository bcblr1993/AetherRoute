# Product-wide UI and interaction audit

This checklist is a release gate. AetherRoute is not visually approved when a
single attractive page exists; every reachable surface and every control state
must use the same native macOS grammar.

## Surface inventory

| Area | Required surfaces |
| --- | --- |
| Main window | Overview, Proxies, Connections, Profiles, Rules, DNS |
| Settings | General, Privacy, Bypass, Diagnostics, Account, Open-Source Licenses, About |
| Profile workflow | Manual node editor, native profile editor, YAML import, subscription editor, external-link confirmation, rename, portable encrypted import/export |
| Runtime states | Privacy required, empty, loading, disconnected, connecting, connected, disconnecting, failed, recovery |
| Compact surfaces | Menu-bar window, menus, alerts, popovers, confirmation sheets, file import/export |

## Shared layout contract

- Use a compact unified title region. Blank toolbar height is rejected.
- Sidebar and detail content share one top baseline and one continuous window
  background. Double padding beside the split divider is rejected.
- Standard page content uses 24-point horizontal margins, 20-point top space,
  28-point bottom space, and a 16-point section rhythm. Dense data rows may use
  12 points; hero regions may use 20 points.
- Scroll content reserves a visible 12-point trailing gutter before the system
  scroll indicator. Content never touches or hides beneath the indicator.
- Standard panels use native semantic fills, a 12-point continuous radius, and
  a 0.5-point semantic separator. Large shadows and stacked glass effects are
  reserved for no ordinary settings or list surface.
- The blue brand gradient identifies AetherRoute and appears only in the app
  icon and empty-state illustration. The user's system accent owns selection
  and keyboard focus; green, orange, and red remain state colors.
- Every page remains usable at 780 x 560 points and with 30 percent text
  expansion. A wider screenshot cannot hide clipping at the minimum size.
- Main-page navigation preserves one outer window size, and Settings-page
  navigation preserves one separate outer window size. Task-specific sheets
  may be compact, but content changes may not make a parent window jump.

## Control-state contract

Every reachable button, menu item, picker, toggle, text field, row action, and
navigation item must be captured or asserted in every applicable state:

| State | Required behavior |
| --- | --- |
| Default | Native label, symbol, hit target, and role; no custom color needed to understand the action |
| Hover | System hover treatment appears without moving or resizing content |
| Pressed | Immediate native pressed feedback; the action cannot fire twice |
| Keyboard focus | Visible system focus ring and logical Tab/Shift-Tab order |
| Selected | System accent plus a non-color semantic value or trait |
| Disabled | Visibly unavailable, inaccessible to activation, and accompanied by nearby reason text when the reason is not obvious |
| Loading | Stable button width, inline `ProgressView`, descriptive accessibility label, and cancellation where the operation is long-running |
| Success/failure | Bounded status message near the initiating control; no color-only feedback |
| Destructive | Destructive role, explicit object name, confirmation when loss is material, and focus defaults to Cancel |

Custom plain/borderless buttons are allowed only for navigation rows, disclosure
controls, and standard icon menus. Primary actions use `borderedProminent`;
secondary actions use `bordered`; destructive actions use a destructive role.

## Evidence matrix

For every release candidate, capture English and Simplified Chinese in light
and dark appearance, then repeat the minimum-window and expanded-text cases.
Automated checks cover focusability, enabled state, selected state, stable
loading labels, accessibility audit, and page landmarks. Manual review covers
hover/pressed motion, visual hierarchy, truncation, and VoiceOver reading order.

Current status: product/UI source revision `5fed9829…` has a reviewed 30-image
matrix in `outputs/aetherroute-ui-review-v40-final`. Subsequent changes are
limited to release-test configuration and documentation, but the matrix remains
revision-bound and must be recaptured after the final source freeze. It covers all six primary pages,
all seven Settings pages, privacy onboarding, both traffic engines, the
minimum window with expanded text, English/Simplified Chinese, and light/dark
appearance. Each screenshot, its corresponding application runtime log, and
the complete source manifest are SHA-256 bound; the runner also rejects source
changes during capture. The capture gate rejects crash/assert/precondition messages and
the AppKit table-reentrancy warning that exposed the former Licenses-page
implementation; that page now uses a bounded SwiftUI scroll stack, retains
search and explicit selection semantics, and renders without that warning.

This visual pass does not replace the remaining interaction gates. The current
XCUITest source asserts primary runtime actions, disabled/enabled states,
navigation selection, Settings selection, local-proxy controls, privacy
consent, licensing/update failure states, and Licenses search/filter/selection.
Its final execution plus keyboard focus/hover/pressed review, live VoiceOver,
and signed Network Extension states remain release requirements. They cannot
be promoted as passed until Developer Tools Security is enabled on the UI-test
Mac and the exact frozen release source is rerun.
