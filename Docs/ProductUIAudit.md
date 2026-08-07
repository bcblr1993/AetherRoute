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
- Standard panels use native semantic fills, a 14-16 point continuous radius,
  and a 0.5-point semantic separator. Large shadows and stacked glass effects
  are reserved for no ordinary settings or list surface.
- Brand cyan/indigo identifies AetherRoute. The user's system accent owns
  selection and keyboard focus; green, orange, and red remain state colors.
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
and signed Network Extension states remain release requirements. Developer
Tools Security is enabled on the current UI-test Mac, but the complete suite
still requires an exclusive foreground session and an exact frozen-source run
before it can be promoted as passed.

## User-journey failure and recovery matrix

The release candidate must be tested from the user's starting point, not only
from a preconfigured happy path. A passing parser, enabled toggle, or attractive
screenshot is not sufficient evidence that the user can recover.

| Journey | Expected user outcome | Automated evidence | Remaining release evidence |
| --- | --- | --- | --- |
| First launch | Read the privacy disclosure, decline without side effects, or accept and reach a truthful disconnected state | Privacy consent storage and UI gate tests | Frozen-candidate keyboard and VoiceOver pass |
| First Network Extension approval | Understand why macOS asks, open the closest Settings page, distinguish Extensions from Open at Login, copy the steps, return, and recheck without relaunching | Dedicated English/Chinese approval-state UI test; application-active recheck; approval card remains visible until macOS returns a result | Installed Developer ID candidate on a clean Mac, including approve, deny, retry, and reboot-required outcomes |
| Empty profile | Connection remains disabled and the next action opens Profiles | Empty-state and recovery UI tests | Installed-candidate smoke |
| Manual node | Protocol-specific fields validate before save; secrets are never echoed in errors | UI editor coverage plus all 12 typed-protocol validation/compilation tests | One installed handshake per supported catalog protocol |
| Subscription import | Confirm external links without exposing tokens; keep valid nodes when some entries are malformed; never replace the active profile when every entry is invalid | External-link, subscription client, normalization, partial-invalid, all-invalid, redirect, size, and encryption tests | Authorized HTTPS fetch and installed connection on a clean Mac |
| Existing local proxy | AetherRoute uses only explicit loopback ports, rejects duplicates/out-of-range values, and never edits the macOS system proxy | Local-proxy settings and random-high-port loopback black-box tests | Signed Packet Tunnel runtime while the user's other proxy remains active |
| Connection failure | Explain the failure near the initiating control and provide Retry or Profiles without displaying a false connected state | Failed-state recovery UI and provider watchdog tests | Signed invalid-profile, provider-timeout, and service-restart drills |
| Permission or signature failure | Show the actual approval, signature, missing-extension, or reboot action instead of a generic “Unavailable” loop | Approval state and error mapping build coverage | Clean-machine signed matrix on each supported macOS release |
| Network loss, sleep, and wake | State becomes truthful within ten seconds; reconnect stays cancellable and the UI remains responsive | Bounded state machines and path-event unit tests | Signed Wi-Fi/path-change and sleep/wake matrix |
| Language, appearance, and window changes | English/Chinese, light/dark, minimum window, expanded text, Reduce Motion, and Increased Contrast remain usable without window jumps | Page-size, localization, expanded-text, selection, and accessibility UI tests | Exact frozen-source run with exclusive foreground plus manual hover/pressed/VoiceOver review |
| Quit, restart, upgrade, and rollback | Preserve encrypted profiles and never leave an orphan test or provider process | Temporary-root upgrade/rollback and profile-store tests | Installed signed upgrade/rollback on a clean Mac |

On 2026-08-07, the current isolated non-UI user-journey regression completed
303 tests with zero failures or skips. The targeted approval journey reached
both localized cards and every action; its English accessibility audit
completed. The Chinese foreground run was interrupted by another application
taking focus and is not recorded as a product pass or failure. The UI runner
now builds and verifies its temporary app before launch, then terminates,
unregisters, and deletes only its exact temporary products. A final full UI run
still requires an exclusive foreground session.
