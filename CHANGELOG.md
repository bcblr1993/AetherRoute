# Changelog

All notable changes to AetherRoute are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

## [1.0.8] - 2026-09-16

### Added

- Support editing, renaming, and removing inactive profiles while connected:
  - Protect the currently active configuration from accidental modification or deletion during active VPN/tunnel sessions.
  - Allow full rename, edit, and deletion actions on all non-active profiles in the profile list context menu without having to disconnect the VPN.
- Support per-node latency testing with distinct state machine representation (`Testing`, `Responded`, `TimedOut`, and `Untested`), eliminating UI state flickering or reset on neighboring proxy items.

### Changed

- Refactor network traffic waveform from rapid jittery 1-second polling to smooth 3-second sampling and synchronized 3-second `TimelineView` rendering, eliminating animation stutters.
- Implement monotonic cubic Hermite spline interpolation for traffic curves to completely prevent curve looping, knotting, and overshoot, with a flat baseline lead-in.
- Switch proxy latency measurement target to a lightweight HTTP 204 no-content probe (`http://cp.cloudflare.com/generate_204`), eliminating redundant TLS handshake overhead and aligning test latency to ~50ms comparable to mainstream proxy clients.
- Fix DIRECT connection node latency test timeout (5000ms+), achieving ~20ms near-instant response.

### Fixed

- Fix an application crash during proxy latency testing caused by Swift 6 Actor isolation violations in asynchronous task callbacks:
  - Enforce strict main actor isolation when updating proxy latency state and publishing notifications.
  - Introduce a bounded 16-worker sliding window concurrency pool to prevent socket descriptor exhaustion and system extension packet stream overload.

## [1.0.7] - 2026-09-16

### Fixed

- Fix a critical Network Extension lifecycle deadlock in TUN mode after physical uplink recovery exhaustion:
  - When the physical uplink was severed and consecutive network reset attempts were exhausted, `PacketTunnelProvider` cancelled the tunnel with an error without stopping the underlying Rust core engine.
  - The process-wide `EngineLifecycleGate` remained stuck in the `running` phase with a stale engine generation, permanently rejecting all subsequent reconnection requests with `lifecycleBusy` and preventing TUN connections until the entire Mac was rebooted.
  - `PacketTunnelProvider` now guarantees `core.stop` is cleanly invoked prior to `cancelTunnelWithError`, along with an additional defensive cleanup barrier in its deinitializer.
  - `EngineLifecycleGate` now actively detects residual running engines upon a new start request, immediately signals `clash_shutdown()`, transitions state to `stopping`, and awaits clean wind-down before admitting the new engine generation.
  - Added automatic process relaunch fallback (`scheduleProcessRelaunch`) if an extension cannot safely recover from a busy lifecycle gate, ensuring automatic self-healing without requiring a Mac reboot.
  - Added unexpected worker termination retirement to return the gate to `idle` if the background engine thread exits unexpectedly.
- Verified physical network link disconnection recovery (8s link down) and dynamic network adapter handoff (IP alias addition/removal) on macOS virtual machines with zero process restarts and seamless data path recovery.

## [1.0.6] - 2026-09-15

### Changed

- Redesign the menu bar panel with a wider 380pt native frosted-glass layout,
  light/dark appearance and Reduce Transparency support. Use paper-plane menu
  bar symbols and retain one main connect/disconnect button.
- Show the current node in a full-width row and open a second-level node list
  without search. Sort measured nodes by latency with stable ties, followed by
  untested and unavailable nodes; include all runtime provider members.
- Poll the foreground overview approximately every second. Release realtime
  demand when switching apps, hiding/minimizing the window or leaving the
  overview; use 10-second polling when no other live panel needs realtime data.
- Label the traffic graph as the last 30 seconds and show the refresh interval
  separately. Position samples by their timestamps instead of keeping 30 points.

### Fixed

- Preserve healthy pooled transports when refreshing or reapplying the same
  outbound interface. Only an actual interface-index change invalidates those
  transports, avoiding unnecessary Hysteria2, TUIC, ShadowQUIC and WireGuard
  reconnections and the extra handshake delay on subsequent requests.
- Resolve the outbound interface once asynchronously for direct UDP sessions
  and reuse it for both IPv4 and IPv6 sockets. This avoids repeating full
  interface enumeration and candidate connect probes on the Tokio worker when
  a TUN session has no pinned interface, reducing stalls in other tasks sharing
  that worker. Both networking fixes are included from core commit `743cb63`.
- Fix missing node names in the menu panel and independently observe live
  traffic values. Keep selection errors visible and return from the node list
  only after selection succeeds.
- Expire traffic samples outside the 30-second window, coalesce same-second
  samples and reset history after clock rollback.
- Cancel telemetry polling, route health checks and readiness verification
  immediately upon application termination. Skip remote proxy health checks
  in direct routing mode.
- Add cooperative cancellation to provider message IPC to release waiting
  continuations immediately when tasks cancel, preventing 90-second shutdown
  hangs.
- Add an explicit terminate action selector to the AppKit delegate and provide
  a safe application fallback to avoid responder chain validation aborts.

### Diagnostics

- Add scripts to collect intermittent proxy data-plane failures and inspect
  transport rebuilds, plus automated network-loss recovery and interface-handoff
  scenarios. These are developer troubleshooting and validation tools.

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
