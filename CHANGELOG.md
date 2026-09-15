# Changelog

All notable changes to AetherRoute are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### v1.0.6 preparation

- Foreground overview polls at approximately 1 second; switching to another
  application, hiding/minimizing the window or leaving the overview releases
  realtime demand so polling drops to 10 seconds when no other live panel needs it.
- Plot the last 30 seconds using sample timestamps rather than a fixed count
  of 30 samples. Coalesce same-second refreshes, discard expired samples and
  reset history on clock rollback. Show the refresh interval separately.
- Include the menu panel redesign below. Publication remains pending candidate
  validation, signing/notarization and release acceptance.


### Menu bar redesign (next release)

- Use filled/outlined paper-plane menu bar symbols for connected/disconnected
  states and a wider 380pt native frosted-material panel, respecting Reduce
  Transparency and light/dark appearance. Remove the duplicate header power
  button while retaining the main connect/disconnect action and all other controls.
- Show the current node in a full-width row; open a second-level node panel
  without search, ordered by measured latency with stable ties, then untested
  and unavailable entries. Include runtime provider members beyond the old
  16-item limit. Preserve selection errors and return only after selection succeeds.
- Observe menu traffic values independently so live rates update without
  redrawing the entire control panel.

### Changed

- The first public edition uses free distribution with user-provided profiles,
  without an activation service or account requirement.
- Validated country and domain routing databases now ship with the app and are
  prepared automatically when connecting. Manual database controls live under
  Advanced Options; failed background updates preserve usable rules.
- Subscription and configuration import are primary actions. Routing details,
  bilingual settings, free-edition labels and About-page text have clearer
  hierarchy and accessibility.
- Production signing, notarization, installed Network Extension validation,
  and the final 24-hour stability gate remain release-blocking.

### Fixed

- Move routing-resource preparation and runtime configuration snapshots off
  the main actor, reject stale results, and prevent conflicting write actions.
- Restore the previous routing files and metadata when an update encounters a
  disk or write failure, while preserving concurrent user imports.
- Reuse the exact enabled system extension, recover windows saved off screen,
  and verify actual provider shutdown and network restoration between tests.
- Bind protocol, signing and resource notices to the actual normal or
  diagnostic core artifacts. Installed-extension performance now requires real
  paired measurements rather than isolated-core throughput numbers.

## [1.0.5]

### Fixed

- Recover TUN traffic after Ethernet and Wi-Fi handoffs by selecting the live
  physical uplink explicitly, while keeping the tunnel routes installed.
- Recreate DNS, Hysteria2, TUIC, WireGuard and ShadowQUIC transports when the
  uplink changes instead of reusing sockets bound to the previous interface.
- Keep pending DNS replies and latency probes from blocking network recovery.
  Bound reset work and let genuine link changes interrupt recovery backoff.
- Ignore duplicate network notifications and changes to unused secondary
  interfaces so a recovered connection remains stable.

## [1.0.4] - 2026-09-14

### Changed

- Add System, Light and Dark appearance choices in General settings. Changes
  apply immediately across app windows and persist across launches.
- Replace the dark dot-matrix icon with the user-selected Silver Flight design:
  a graphite paper plane with a blue accent on a porcelain-white tile.
- Use the same approved artwork for Dock, Finder, in-app branding and website
  icons, with reproducible 16–1024 px assets and the legacy ICNS resource.
- In-app icons follow the selected theme: charcoal in dark mode and porcelain
  in light mode, with the decorative blue glow and ring removed.
- Networking behavior is unchanged from 1.0.3.

## [1.0.3] - 2026-09-14

### Fixed

- Bound network-state reset waits to three seconds and keep blocked resets
  separate from provider telemetry and control requests. Only one reset may
  remain in flight while recovery continues with network settings restoration.
- Distinguish unexpected provider termination from a user-requested stop and
  retry an interrupted connection with a finite backoff schedule. An explicit
  disconnect cancels pending automatic reconnects.

## [1.0.2] - 2026-09-14

### Fixed

- Disconnecting now restores the system network immediately. macOS keeps a
  tunnel's interface, routes and DNS installed until the provider reports the
  stop complete, and the provider waited up to ten seconds there for the
  protocol engine to unwind. A disconnect issued against a node that had
  stopped responding therefore left the machine offline for that entire wait.
  The engine is now signalled and joined in the background.
- Restarting the tunnel can no longer leave two protocol engines running at
  once. The engine is process-wide, but its owner is rebuilt for every
  connection, so a restart that began while the previous engine was still
  stopping started a second one — doubling memory and thread use, and leaving
  either instance able to cancel the other's transport. Engine lifecycle now
  runs through a process-wide gate; a restart waits for a clean handoff and
  restarts the network extension if it cannot get one.
- A latency probe against an unresponsive node no longer delays the shutdown
  that would cancel it, nor the proxy selection and telemetry requests queued
  behind it.

## [0.1.0-alpha.1] - 2026-08-03

### Added

- Initial native Swift 6 and SwiftUI macOS application source baseline.
- Transparent Proxy and Packet Tunnel/TUN Network Extension architecture.
- Typed support and isolated interoperability coverage for twelve protocol
  families.
- Encrypted profiles, subscriptions, routing, DNS, diagnostics, licensing,
  update verification, and cross-machine profile transfer.
- Pinned AetherRoute embedded-core submodule with reproducible arm64 build
  scripts and third-party notices.

### Security

- System proxy, DNS, routes, and TUN are never changed by ordinary repository
  tests; real provider tests require an explicit isolated, signed gate.

[Unreleased]: https://github.com/bcblr1993/AetherRoute/compare/v0.1.0-alpha.1...HEAD
[0.1.0-alpha.1]: https://github.com/bcblr1993/AetherRoute/releases/tag/v0.1.0-alpha.1
