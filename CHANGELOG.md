# Changelog

All notable changes to AetherRoute are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [1.0.13] - 2026-09-17

### Added

- Physical Uplink Detector (`PhysicalUplinkDetector` in `AetherRouteKit`):
  introduced low-level Darwin network interface enumeration (`if_nameindex()`)
  combined with macOS `ServiceOrder` priority matching to immediately detect
  hot-plugged network hardware adapters (e.g. USB Ethernet dongles) even when
  the sandboxed `NWPathMonitor` remains quiet while reasserting.
- Strict virtual and container interface prefix filtering: excluded `feth`
  (Docker/OrbStack), `bridge`, `utun`, `vmenet`, `anpi`, `ap`, `awdl`, `llw`,
  `gif`, `stf`, and `lo` from uplink selection, preventing virtual interfaces
  from causing core network reset failure and recovery exhaustion.
- Host-level recovery watchdog (`hostRecoveryWatchdogTimeout` in `TunnelManager`):
  armed a 45-second fallback watchdog whenever entering the `.recovering` state,
  automatically triggering a graceful restart to self-heal if the system extension
  ever encounters an unrecoverable driver deadlock.

### Changed

- Streamlined connection transition animations in Overview (`ContentView`):
  completely removed the 3-stage progress step bar ("System Auth -> Extension -> Handshake")
  to permanently lock the Hero connection card height with absolute zero layout shift,
  retaining the fluid luminous energy bar and breathing beacon lens.
- Redesigned configuration profiles list (`ProfilesSettingsView`): transformed the
  profile management interface into an Apple-native grouped list, eliminating
  repetitive metadata badges, visual fragmentation, and card clutter.
- Fixed proxy node ordering in the main application (`ProxiesSettingsView`):
  anchored node card layout to strictly follow the original configuration declaration
  order, eliminating card jumping and layout re-ordering during latency testing.

### Fixed

- Resolved network recovery deadlock where disconnecting mobile hotspot/Wi-Fi,
  sleeping, and subsequently plugging in an Ethernet cable left the app indefinitely
  frozen in "Waiting for network recovery", requiring a manual reconnect.
- Fixed node speedtest timeouts and cascading parent strategy group latency
  refresh issues (`measureCurrentNodeSelection` in `TunnelManager`).

## [1.0.12] - 2026-09-17

### Added

- Seamless Network Engine Handover (`performSeamlessNetworkEngineHandover` in
  `TunnelManager`): switching between TUN and Transparent Proxy modes is now
  executed via active pre-activation of the destination engine, verification of
  readiness, and graceful teardown of the prior engine, completely preventing
  connection dropouts.
- Visual continuity during engine handover: the main interface and status bar
  preserve the connected state without resetting connection timers or flashing
  disconnected UI states.
- Interactive Route Simulation Tester on the Rules page (`RulesSettingsView`),
  allowing users to input domains or IP addresses to preview matched rules, rule
  types, and target outbound groups in real time.
- Action-based filter chips (All, Proxy, Direct, Reject) on the Rules page for
  quick classification and rule inspection.

### Changed

- Overhauled the Rules page visual design with modern card styling, type capsule
  tags, and refined layout hierarchy.
- Redesigned overview connection transitions with zero height jitter, beacon
  status pulse animations, and progressive diagnostics disclosure.
- Stabilized menu bar proxy node sorting: fixed node order to respect the
  original configuration declaration order, preventing list reorganization during
  selection or latency sweeps.
- Clarified terminal proxy action button labels: distinctly differentiated
  between "Copy Proxy Command" and "Copy Clear Command".

### Fixed

- Resolved long-idle network degradation where the browser or background update
  stalled after 10+ hours of sleep/wake cycles. Scheduled an active core
  connection reset and socket pool refresh within the macOS wake recovery path.
- Added re-entrancy switching lock (`isSwitchingEngine`) and automatic rollback
  safeguard (`attemptRollbackToEngine`) to handle unexpected engine handover
  failures gracefully.
- Added complete localization for the `Reject` routing action across supported
  languages.

## [1.0.11] - 2026-09-16

### Changed

- Rework user-initiated latency measurement into two explicit layers. A
  bounded TCP reachability sweep streams a number for every member as it
  arrives; the selected member is then verified through its real protocol
  handler. Rows state which of the two they report, so a node that answers TCP
  but cannot actually carry traffic is no longer shown the same way as a
  working one. Full-group measurement through the core is not used here: that
  request is capped at 64 members and holds an engine lock for the whole sweep,
  which is what made selector actions unresponsive during a measurement.
- Massive performance acceleration for full-profile latency sweeps: increased
  probe concurrency to 32 parallel workers, optimized timeout to 1500 ms, moved
  socket scheduling to a dedicated concurrent queue (`probeQueue`), and added
  throttled flush debouncing (`latencyFlushTask`). Profiles with hundreds of nodes
  now complete sweeps in seconds without UI jitter or thread starvation.
- Retain fixed source configuration order in proxy lists during latency tests,
  preventing rows from rearranging under the mouse pointer.
- Replace the per-result merge with an indexed staging area. Recording one
  result is now O(1) and the published state is rebuilt once per ~100 ms flush
  window instead of once per node. The previous path rescanned every group's
  member array and reassigned the full published dictionary for each arriving
  result, so a large group cost quadratic main-actor work.
- Share provider message classification between both Network Extensions
  instead of duplicating it, and keep latency probes off the queue that serves
  selector and telemetry traffic.

### Fixed

- Eliminate macOS `nehelper` deadlocks and system freezes during Transparent Proxy
  and TUN engine switching. Replaced destructive preference modification of opposing
  managers with clean connection teardown, added re-entrancy switching guards, and
  reduced connection settling watchdog timeouts.
- Fix macOS NetworkExtension rejecting TUN routing configuration with `IPv6 routes
  are invalid: ("IPv6Route Destination address in loopback")`. Removed `::1/128`
  from excluded IPv6 routes.
- Cache active system extension identity state in `SystemExtensionActivationCoordinator`,
  eliminating repeated sysextd IPC lookups and latency during mode changes.
- Dynamically link menu-bar shell proxy commands to the user's configured local
  proxy ports, avoiding hardcoded 7890 port mismatches, and standardize on
  safe unset environment commands.
- Cascade latency aggregation bottom-up to parent strategy groups immediately
  upon completing single-node tests, ensuring parent groups reflect updated child
  group measurements.
- Stop measuring TUN-mode reachability through the tunnel itself. Probes now
  refuse virtual interfaces while a TUN session is active, so a measurement no
  longer reports `host -> current node -> target node` latency or times out by
  looping back through the node carrying the session.
- Resolve nested strategy groups regardless of declaration order. Aggregation
  repeats bottom-up until it settles, where a single declaration-order pass
  previously left a group nested two or more levels deep reporting whatever
  that one pass produced.
- Stop probing strategy-group names as if they were nodes, which reported a
  timeout and showed the row as failed until aggregation overwrote it.
- Retry a group's measurement after a failed run. A failure previously left an
  empty measured state behind, so the menu's first-open probe treated the group
  as already measured and never tried again.
- Keep a single-node measurement from being discarded by a concurrent
  group-level run, and stop a single-result provider reply from shrinking a
  whole group's published results down to one row.
- Discard latency results that arrive after a profile switch instead of
  writing them into a same-named group in the newly active profile.
- Auto-detect built framework products in standalone test runners, preventing
  hardcoded DerivedData machine-specific path failures.

## [1.0.10] - 2026-09-16

### Fixed

- Preserve active tunnels when recovery probe endpoints are unavailable; use
  fallback endpoints and received traffic as recovery evidence, and avoid
  repeatedly resetting transparent-proxy flows during the same recovery run.
- Show network recovery separately from initial connection setup, preserving
  the session duration and keeping Disconnect available in the window and menu.
- Verify screen-lock continuity on one persistent TCP connection without
  automatic reconnection; separate simulated QA power events from screen lock.

## [1.0.9] - 2026-09-16

### Fixed

- Prevent unwanted tunnel disconnection and reconnection during screen lock and display sleep:
  - Remove over-broad observers for `com.apple.screenIsLocked`, `com.apple.screenIsUnlocked`, `screensDidSleepNotification`, and `screensDidWakeNotification` that falsely forwarded to `.systemWillSleep` and `.systemDidWake`.
  - Maintain continuous, uninterrupted tunnel and TCP connections across lock screen and display idle, preserving active downloads and SSH sessions.
  - Retain full recovery handling on real system sleep and wake via `NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification`.
  - Add `Tests/RuntimeEnvironment/` test suite to enforce display continuity and system sleep/wake recovery regression coverage.

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
