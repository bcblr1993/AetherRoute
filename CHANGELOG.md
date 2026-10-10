# Changelog

All notable changes to AetherRoute are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [1.5.1] - 2026-10-11

Switching pages no longer stalls, the app stays around 70 MB instead of growing past 200 MB, per-app traffic statistics stay complete in long sessions, and page content follows the macOS 26 Liquid Glass guidelines.

### Fixed

- Memory: the app grew from about 75 MB to over 200 MB within minutes while its window was open, and kept it after the window closed. Rolling-digit animations on values that change every second (live rates in the menu bar panel, the Connections session bar and Overview, the chart's peak) made Core Graphics cache every animation frame's glyphs. Those values now update in place; the footprint stays at 70–81 MB with live traffic on the heaviest test profile.
- Page switching: switching between pages, Connections and Rules in particular, could block the main thread for up to 0.8 s. Connections rows now have one fixed height, so a ticking duration no longer re-measures every row; page switches no longer play an entrance animation; text in table rows and switches no longer re-reads the whole Chinese string table on each layout; segmented controls measure their labels once.
- Per-app traffic statistics: in long sessions with many apps and outlets, traffic of (app, outlet) pairs beyond the first 256 was dropped or never reported, and a pair evicted and seen again could be under- or double-counted. The engine (core `183c120`) now remembers up to 2,048 pairs, evicts only idle pairs that were already reported, gives each pair an incarnation so one seen again starts from zero, and sends active and recently changed pairs first. The host counts by incarnation, ignores samples from an older one, and only records a baseline for pairs it first sees below the engine's watermark, so nothing is counted twice. Telemetry format ART4 / Flow ABI V7; older system extensions keep working.

### Changed

- Page content no longer sits on Liquid Glass, as Apple's guidelines ask: cards and Settings sections use the system grouped fill, and buttons in pages and sheets use the system bordered styles. The sidebar, the menu bar panel and the command palette keep their glass.
- Search fields are capsules, as in macOS 26.
- The Overview chart redraws only the waveform each frame; its labels update with the data.
- In-app update notes have a new layout: a lead paragraph and a coloured icon per group (new, improved, fixed), matching the app's sidebar tiles.

### Added

- Release gate `scripts/test_ui_performance_gate.sh`: on a real Mac, the Release app switches pages with live, once-a-second traffic on an everyday and a heavy profile, and fails the release if a switch or the memory footprint exceeds its budget, or memory keeps growing.
- Design-token guards now reject literal localized strings (including empty toggle labels and literal ternaries) and raw `.numericText` transitions.

### Verified

- Local regression suites and `./scripts/test.sh` (including the new design-token guards) passed on the merged tree; all five protocol interop gates passed on core `183c120` (48 cases, 26 certificate rejections).
- UI suite on the `macos27` VM: 48 passed, 0 failed (3 opt-in tests skipped), the same as 1.5.0.
- Mac mini remote gate passed. On the Mac mini with the notarized build 2026101003, in both transparent and TUN mode: idle reuse after 50 s and a 2 MiB upload passed; footprint 68 MB and 73 MB.
- Tart VM matrix (tun / transparent × rule / global / direct) passed with the QA build 2026101004 (same sources as 2026101003 plus the QA fixture), including idle reuse, a 2 MiB upload in 3.4–7.5 s and transparent SNI recovery.
- New UI performance and memory gate on the Mac mini (Release, live traffic, 5 minutes per profile): page switch p95 153 ms and slowest 201 ms on both the everyday and the heavy profile (1.5.0: p95 226–414 ms, slowest 805 ms); footprint median 69–70 MB, peak 74–75 MB, +2 MB over the run (1.5.0 grew from 75 MB to 212 MB in 5 minutes).

## [1.5.0] - 2026-10-10

The first run is now a guided three-page setup: privacy commitments, network permissions with each engine's state on its own row, and a final page confirming that everything is ready.

### Added

- First run: three pages (privacy commitments, network permissions, all set), each with an illustration, page dots and the main action pinned at the bottom.
- Network permissions: Transparent Proxy and TUN each have a row. Allow grants it right on the row; a granted engine shows a green check, and opening System Settings, retrying or restarting is offered on the same row when needed.
- All set: once both engines are granted, a last page sums up the privacy commitments and both engines, and Start Using AetherRoute opens the main window. An engine this Mac cannot use is noted there; the other one still works.

### Changed

- In the smallest window the page scrolls beneath the main action instead of pushing it out of the window.
- The sheet asking to grant a permission again after it was withdrawn uses the same design, without the page dots or the last page.
- Update notes in the in-app update window are grouped by kind (new, fixed, improved) and styled.

### Verified

- Local regression suites, `./scripts/test.sh` (including the UI design-token guards) and all five protocol interop gates (48 cases, 26 certificate rejections) passed.
- Tart VM matrix (tun / transparent × rule / global / direct) and the Mac mini remote gate passed.
- On the Mac mini with the notarized build 2026101002, in both TUN and transparent mode: automatic restore on launch, idle reuse, 2 MiB upload, the connection intent kept after a quit while connected, and restore again on the next launch.
- UI suite on macOS 27: 48 passed, 0 failed (3 opt-in tests skipped); new tests cover each first-run page in both languages and appearances, the consent in the smallest window, and finishing on the last page.
- 5,000-node import: 0.366 s and 4.33 MB peak RSS growth (1.4.2: 0.346 s, 4.49 MB).

## [1.4.2] - 2026-10-10

Fixes layouts that overflowed the narrowest window and repairs five UI tests that had failed since 1.3.3.

### Fixed

- Connections: at the narrowest window the six columns no longer run 79 pt past the table (the App column added in 1.3.0 had pushed them out), so nothing needs horizontal scrolling. Duration keeps its column budget.
- Overview: with long translations, Routing mode and Network engine no longer overlap their title with the control or widen the page; when the control does not fit beside the title it moves below it.

### Verified

- Local regression suites, `./scripts/test.sh` (including the UI design-token guards) and all five protocol interop gates (48 cases, 26 certificate rejections) passed.
- Tart VM matrix (tun / transparent × rule / global / direct) and the Mac mini remote gate passed.
- On the Mac mini with the notarized build 2026101001, in both TUN and transparent mode: automatic restore on launch, idle reuse, 2 MiB upload, the connection intent kept after a quit while connected, and restore again on the next launch.
- UI suite on macOS 27: 46 passed, 0 failed (3 opt-in tests skipped); 1.4.1 had 41 passed and 5 failed.
- 5,000-node import: 0.346 s and 4.49 MB peak RSS growth (1.4.1: 0.352 s, 4.67 MB).

## [1.4.1] - 2026-10-09

Fixes a stall of new connections in transparent proxy mode, makes reconnecting after a restart more patient, and keeps traffic statistics safe.

### Fixed

- Transparent proxy: while a latency test ran (Proxies page, automatic test on opening it, connection readiness, automatic groups), every new connection on the Mac waited until it finished, up to the test's timeout. The first connection after updating to 1.4.0 stalled about 21 seconds this way. Latency tests and other control requests no longer hold up new connections; stopping still waits for a running test before the engine shuts down.
- Reconnecting after a restart waits for a usable network and for each attempt's actual result, within two minutes, instead of giving up after about 20 seconds.
- Traffic statistics: a ledger that cannot be read for the moment (for example while the Keychain is still locked after login) is no longer replaced by an empty one; it is read again later and the traffic counted meanwhile is added. A ledger that can never be opened is set aside instead of overwritten, and Clear removes it too.
- Traffic statistics: disconnecting or quitting samples once more first, so the last minute before a disconnect is counted. The window shows Disconnecting at once while it does (at most two seconds), and a connect cannot slip in meanwhile.
- Importing node links that exceed the size or node limit says which limit was hit instead of "No valid node link was found."
- The log viewer filters the log once per update instead of four times.
- Sheets keep their controls' accessibility identifiers, so UI automation can find them.

### Verified

- Local regression suites, `./scripts/test.sh` and all five protocol interop gates (48 cases, 26 certificate rejections) passed; new unit tests cover flow admission during a held latency test, stop ordering, and ledger loading.
- Tart VM matrix (tun / transparent × rule / global / direct) and the Mac mini remote gate passed.
- On the Mac mini with the notarized build 2026100902, in both TUN and transparent mode: automatic restore on launch, idle reuse, 2 MiB upload, the connection intent kept after a quit while connected, and restore again on the next launch.
- UI suite on macOS 27: 41 passed, 5 failed; the same 5 fail on v1.3.3 and v1.4.0 and are listed in `Docs/ReleaseExceptions/1.4.1.md`. No test that passed on 1.4.0 fails.
- 5,000-node import: 0.352 s and 4.67 MB peak RSS growth (1.4.0: 0.347 s, 4.67 MB).

## [1.4.0] - 2026-10-09

AetherRoute can now close connections without disconnecting, shows its own logs, imports nodes from pasted links, QR images or the screen, and keeps encrypted local traffic statistics by app and node.

### Added

- Close connections: Connections › Close All, plus Close Connection and Close Connections of … in the context menus. The tunnel stays up and apps reconnect on their own. Closing an app that runs as several processes (a browser and its helpers) is one batched request.
- Switching a group's node closes the connections that still run through that group, nested groups included, so the new node takes effect at once (Settings › Network › Proxies, on by default).
- Logs: Settings › Privacy & Diagnostics › View Logs… shows what the app and the running network extension recorded, with a recording level (Off / Standard / Verbose), source and error filters, search and copy. A new level applies at once, also to the running extension. Nothing leaves the Mac.
- Optional latency test when the Proxies page opens (Settings › Network, off by default), at most once a minute per group and only while connected.
- Import Node Links…: paste `vless://`, `ss://`, `hy2://` … links (one per line or a Base64 list), or read them from a QR code: choose an image, drop one (also straight from Finder), paste a screenshot, or Scan Screen to read a code shown in another app (asks for Screen Recording permission the first time; nothing is saved). The nodes become one editable native profile; invalid lines are skipped and counted.
- Traffic statistics: Overview › Statistics… shows today, the last 7 or 30 calendar days by app and by exit node. Off until turned on (Settings › Network › Statistics, or Turn On in the sheet). Stored sealed with AES-256-GCM under the profile key, excluded from backups, and can be cleared.

### Changed

- Engine (aetherroute-core `73f29c5`):
  - `clash_flow_close_connections_v1` / `clash_packet_close_connections_v1` take an `ARC1` request; kind 4 closes several apps at once.
  - `clash_flow_telemetry_snapshot_v3` / `clash_packet_telemetry_snapshot_v3` return `ART3`: `ART2` plus lifetime traffic totals per (source app, proxy chain), covering every connection rather than the listed ones. Statistics split traffic exactly from them and sample once a minute when no traffic view is open (instead of every 10 s).
  - Flow ABI table v6 carries both new entry points. Flow ABI symbol count 23 → 25.
- Provider messages gain close-connections (op 10), recent-log (op 11) and set-log-level (op 12) requests.

### Fixed

- Switching pages quickly no longer stutters from background work: the statistics ledger publishes on its own instead of redrawing the whole window with each sample; changing the polling cadence (opening or leaving Connections) no longer writes the ledger or resets its baseline; the Proxies page rereads a group's selection at most every 10 s per connection and publishes it only when it changed. The sidebar connection count now updates live in its own badge. Clicking through pages in quick succession switches at once instead of stacking entrance animations.
- After a restart, shutdown or logout, AetherRoute connects again on its own. macOS delivers several quit callbacks; 1.3 rewrote the saved connection intent on each one, and the last, arriving after the extension had stopped, recorded "not connected". The intent is now saved once, on the first callback, and an explicit disconnect is never undone.
- Statistics saves and clears run in order, pending samples are written before statistics are turned off or the app quits, and a new VPN session is detected from its start time instead of from counters falling.
- Multiline log records stay together in time order, and the log view reads only the requested tail instead of whole rotated files.
- Reading a QR code from an image or a pasted screenshot, and parsing pasted links, no longer block the window; a second import cannot start while one runs.
- The statistics ledger is written only after it was read and only with new samples, so an early save can no longer replace the saved history with an empty one.
- Proxy chains in telemetry now read from the rule's target group to the node that carried the flow ("Proxy → Auto → Tokyo"). The engine recorded them node-first, so the Connections outlet column and the automatic group's current node showed the outermost group instead of the node.

### Verified

- Local regression suites, `./scripts/test.sh` and all five protocol interop gates (48 cases, 26 certificate rejections) passed.
- Tart VM matrix (tun / transparent × rule / global / direct) passed in one run, including idle keep-alive reuse, 2 MiB upload and transparent SNI recovery; the Mac mini remote gate passed.
- On the Mac mini with the notarized build 2026100901, in both TUN and transparent mode: automatic restore on launch, idle reuse, 2 MiB upload, the connection intent kept after a quit while connected, and restore again on the next launch.
- UI suite on macOS 27 compared with v1.3.3 on the same VM: no regressions; the new statistics and node-link import tests pass. Environment-only failures are listed in `Docs/ReleaseExceptions/1.4.0.md`.
- 5,000-node import: 0.347 s and 4.67 MB peak RSS growth (v1.3.3: 0.352 s, 4.67 MB).

### Notes

- uTLS browser fingerprints are not part of 1.4: the engine's TLS stack (rustls) cannot shape a browser ClientHello, so this needs a separate TLS implementation and its own evaluation.

## [1.3.3] - 2026-10-08

AetherRoute now features a unified, refined macOS design system (AetherRouteVisualSystem) with standardized row height tiers, card padding, inline controls, native sheet footers, inline status messaging, and reinforced design token guards.

### Changed & Improved

- Visual Design Token Hierarchy: Established explicit row height tokens (`rowHeight: 52`, `compactRowHeight: 44`, `listRowHeight: 40`, `tableRowHeight: 36`, `twoLineRowHeight: 60`) and card padding tokens (`cardPadding: 16`, `heroCardPadding: 20`, `listCardInset: 8`), removing scattered literal dimensions across all pages.
- Native HIG Dialogs & Sheet Footers: Aligned all modal sheets (manual node editor, profile editor, subscription import, password input) with macOS HIG conventions—Cancel and Primary actions share trailing-edge alignment with prominent glass styling.
- Standardized Controls & Feedback:
  - Introduced `AetherRowIconLabel` (24pt circular icon action button with accessible labels) and `AetherInlineMessage` (compact failure and warning feedback with WCAG-compliant accessible tints).
  - Standardized switches with `AetherRowToggleStyle` for labeled rows and compact switches for table rows.
  - Converted rule criteria copying to `AetherCopyButton` with proper Reduce Motion handling.
- Localization & Dynamic Switching: Replaced legacy `LocalizedStringKey` patterns with `String.LocalizationValue` and `AppLocalization.string(...)` to guarantee instant in-app language switching without UI desynchronization.
- Automated Design Token & Motion Guards: Enhanced `verify_ui_design_tokens.sh` and `test_motion_guards.sh` with rules guarding against raw state colors, arbitrary opacity declarations, unmanaged animations, and literal height definitions.

### Verified

- UI design token guards, motion guards, App compilation, and regression suites passed 100%.

## [1.3.2] - 2026-10-08

AetherRoute now reliably restores proxy connections across Mac reboots and login item startups according to the user's explicit intent before shutdown.

### Fixed

- Boot Connection State Restoration: Resolved an issue where AetherRoute failed to restore connection upon login item cold start when previously connected before shutdown.
- Startup Race Mitigation: Introduced `StartupConnectionRestorePolicy` with progressive backoff delays (1s, 2s, 3s, 5s, 8s) to accommodate underlying Wi-Fi/DHCP network readiness and `sysextd` system extension registration times.
- Lifecycle & Intent Hardening: Enforced strong delegate hosting for `TunnelManager` in accessory tray mode, ensuring lifecycle stability when launching without visible windows. Persisted atomic connection intent upon shutdown, strictly upholding user state ("connected before shutdown reconnects; disconnected before shutdown stays disconnected").

### Verified

- App unit tests, policy verification, and regression gates passed: `StartupConnectionRestorePolicyTests`, `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh`, and `./scripts/test.sh` 100% passed.

## [1.3.1] - 2026-10-06

AetherRoute now supports Rule Providers for subscribing to and managing external rule sets, dynamically compiling active rules into routing chains with safety budgets, and syncing providers across devices via iCloud.

### Added

- Rule Providers: Support subscribing to remote rule sets in domain, ipcidr, and classical formats with customizable targets (Direct, Proxy, Reject) and update intervals.
- Dynamic Rule Compilation: Active rule providers are compiled into routing chains upon connection or profile switch, placed with correct precedence between custom rules and base profile rules.
- Jetsam Safety Guard: Strict rule budgets enforced per provider (up to 2,500 rules) and globally (up to 8,000 rules) to prevent Network Extension 15MB Jetsam termination on iOS/macOS.
- iCloud Roaming: Automatic synchronization of rule provider configurations and enablement states across Mac and iOS devices using iCloud Key-Value Storage.

### Verified

- App unit tests and regression gates passed: `RuleProviderEngineTests` (download, caching, parsing, budget trimming, export/import sync payload), `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh`, and `./scripts/test.sh` 100% passed.
- Physical Apple Silicon Mac mini (LAN 192.168.50.226) in place of Tart VM: remote arm64 gate `test_remote_arm64.sh fast` passed; runtime verification for both TUN and Transparent proxy passed idle keep-alive reuse (6/6) and 2 MiB large upload (6/6). See `Docs/ReleaseExceptions/1.3.1.md`.

## [1.3.0] - 2026-10-06

AetherRoute now knows which app opened each connection, and can route an app as a whole: one app always direct, another always through a given proxy group, a third blocked, ahead of every other rule.

### Added

- Connections: an App column with the app's icon and name; hover for its signing identifier and path. Helper processes count as their app (a Chrome renderer is Chrome), and pages loaded through the system's WebKit process show as "Safari (web)".
- Connections: Group by app shows one row per app with its connection count, outlets and traffic. Double-click an app, or choose Show only … from its context menu, to list just its connections. The connection inspector shows the app as well.
- Rules: Application rules, checked before custom rules and the profile's rules. Add an app from those connected now or pick one in Finder, then choose Direct, a proxy group or Block for each. The same choices are on the Connections page's context menu (Rule for … › Always connect directly / Always use … / Always block).
- Profile rules of type `PROCESS-NAME`, `PROCESS-PATH` and `PROCESS-PATH-REGEX` now work. Until now a profile containing one could not be used with the transparent proxy.
- Help: "How do application rules work?" next to the new section.

### Changed

- Custom rules are now checked after application rules; the section says so.
- Importing a profile that contains `AETHER-APP` (the internal type behind application rules) is refused, and such a rule in an existing profile is dropped, so a profile cannot add application rules of its own.
- The route tester answers for a destination alone and skips application rules.

### Notes

- Transparent Proxy attributes every TCP and UDP connection. TUN attributes TCP connections; UDP and QUIC under TUN show "Unknown app" and follow the other rules, because the engine carries TUN UDP in one shared session.
- The app information comes from macOS (Network Extension flow metadata; under TUN, the kernel's socket table read from the sandboxed extension) and needs no new permission. It stays on this Mac: diagnostics exports never include per-connection details.
- Engine and host talk through new versioned entry points (`clash_flow_*_create_v2`, `*_telemetry_snapshot_v2`); the previous ones remain.

### Fixed (before release)

- Found on a physical Mac during verification: with any application rule saved, neither extension started. The extension ran the profile-import check on the profile the app compiles for it, and both engine entry points still refused process rules. The launch profile now accepts the app's own application rules, the engines start with them, and tests now start a real transparent engine and the TUN engine with application and process rules.

### Verified

- Engine: clash-ffi tests 37 (transparent) and 55 (TUN) passed; new tests cover strict ASA1 / ART2 encoding, the application-rule payload, matching (helpers, look-alike identifiers, sibling paths, executables), process rules on the reported app, an engine routing UDP by app end to end, and engine creation with application rules. The TUN core smoke test starts with application and process rules (the previous core fails it with the error seen on device).
- App unit tests 404 + 84 + 22 passed (20 new: telemetry v1/v2, source-app encoding and identity, application rules, import refusal, launch snapshot); no compiler warnings; screenshots of the Connections page (list, grouped, inspector, narrow window, light and dark) and the Rules page.
- Local regression `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh` and `./scripts/test.sh` passed. Protocol interoperability gate (release build) passed all five gates after every engine change; one run failed a single Trojan UDP echo case and passed on rerun with the identical test binary.
- Physical Apple Silicon Mac mini (LAN 192.168.50.226) in place of the Tart VM, notarized stable candidate 2026100602: tun and transparent × rule, global and direct all passed `test_runtime_acceptance.sh` with no failures; idle keep-alive reuse 6/6, 2 MiB upload 6/6, SNI recovery 3/3. Application rule on device, both engines: with `/usr/bin/curl` set to Block, curl was refused while python3 still reached the site (HTTP 200). Remote arm64 gate `test_remote_arm64.sh fast` passed. See `Docs/ReleaseExceptions/1.3.0.md`.
- Resource figures from `./scripts/test.sh` (1.2.1 → 1.3.0): packet-flow startup peak RSS 12.2 → 12.2 MB, flow startup 9.4 → 9.4 MB; TCP performance gate flow-core peak RSS 55.7 → 59.8 MB, added p95 latency flow 0.041 → 0.034 ms and packet 0.161 → 0.071 ms, throughput ratio flow 47.1% → 46.8% and packet 36.8% → 44.1% of raw loopback.

## [1.2.1] - 2026-10-05

Subscription profiles now show how much traffic is left and when the plan expires, and AetherRoute warns before either runs out. Routing, the network engine and both extensions are unchanged from 1.2.0.

### Added

- Profiles: a subscription row shows used / total traffic with a bar, the traffic left and the expiry date with the days remaining, from the provider's `subscription-userinfo` header. It turns orange when less than 10% is left or the plan ends within three days, and red once the traffic is used up or the plan has expired. The line wraps in narrow windows instead of cutting off the date.
- Menu bar panel: a notice when the subscription in use needs attention, with a button to the Profiles page.
- Settings › Automation › Subscription alerts (off by default): a system notification for the same conditions, at most once a day per subscription and kind. Turning it on is what asks for notification permission. Like connection notifications, it never includes the profile name or traffic figures.
- Automatic updates follow the provider's `profile-update-interval` until you choose an interval yourself; Auto Update › Provider schedule returns to it. A new subscription takes its name from the provider's `content-disposition` file name when there is one.

### Notes

- The header is parsed leniently: keys in any case, `;` or `,` between fields, and a malformed field is ignored on its own without affecting the update. A response without the header keeps the last report. Subscriptions saved by earlier versions load unchanged.
- Days remaining count calendar days, so a minute-aligned clock cannot show one day too many.

### Verified

- App unit tests 387 + 84 + 20 passed (7 new: header parsing, alert thresholds including exactly 10% left, calendar days, provider hints, legacy decoding, provider interval vs. user choice, fetch keeping the last report on 304); no compiler warnings; screenshots of the Profiles page (light, dark, narrow) and the menu bar notice.
- Local regression `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh` and `./scripts/test.sh` passed; protocol interoperability gate (release build) passed all five gates.
- Physical Apple Silicon Mac mini (LAN 192.168.50.226) in place of the Tart VM, notarized stable candidate: tun and transparent × rule, global and direct all passed `test_runtime_acceptance.sh`; idle keep-alive reuse 6/6, 2 MiB upload 6/6, SNI recovery 3/3. Remote arm64 gate `test_remote_arm64.sh fast` passed. See `Docs/ReleaseExceptions/1.2.1.md`.

## [1.2.0] - 2026-10-05

Nodes with a self-signed certificate can now be used without skipping certificate verification: AetherRoute honours a pinned certificate fingerprint on every TLS protocol and a custom CA on Hysteria2 and TUIC, as Mihomo does.

### Added

- Certificate pinning (`fingerprint`, the server certificate's SHA-256) on VMess, VLESS (TLS, WebSocket, gRPC, HTTP/2), Trojan, AnyTLS, HTTP(S), SOCKS5 over TLS, Hysteria2 and TUIC. A matching pin replaces the CA and hostname checks, so a self-signed server connects with verification on. The pin is enforced even when `skip-cert-verify` is on, and the TLS handshake signature is always verified, so a copied certificate is not enough to impersonate the server. Colons and either letter case are accepted.
- Custom CA (`ca` / `ca-str`) on Hysteria2 and TUIC: only the given CA is trusted and the hostname is still checked.
- Importing a profile file turns readable `ca` files into `ca-str`, because the network extensions cannot open your files. When a file cannot be read, the import says which one, and only the nodes that use it refuse to connect.
- Hysteria2 share links keep their `pinSHA256`. Adding a node by hand offers an optional certificate fingerprint field with format checking.
- Settings › Network › Local proxy explains that in TUN mode Terminal traffic is already routed, so copying the shell environment is only needed for troubleshooting or tools that bypass TUN.
- `./scripts/fetch_interop_tools.sh` and `./scripts/test_protocol_interop_all.sh` download the pinned third-party servers and run all five protocol interoperability gates in one step; the release checklist (AGENTS.md) now requires them for every release and engine change.

### Changed

- A malformed fingerprint or an unreadable CA now makes only that node refuse to connect, with the reason ("certificate fingerprint mismatch" or "unusable certificate settings"). Before, these options were ignored, and an AnyTLS node with a fingerprint failed to load, which also stopped every group that listed it.
- **Behaviour change:** a subscription that sets both `fingerprint` and `skip-cert-verify: true` used to connect without checking the pin. The pin is now checked, as in Mihomo; a stale or wrong fingerprint makes that node fail with "certificate fingerprint mismatch".

### Fixed

- Engine test `start_and_stop` read its bundled database through a relative path and tried to download one when run from another directory.
- `scripts/fetch_interop_tools.sh` cleaned its temporary directory in a way the repository's cleanup guard rejects, which broke `./scripts/test.sh`.

### Notes

- The engine's bundled web dashboard (not part of the app) had its npm lockfile refreshed: 22 advisories down to 7, all from the shadcn CLI's `braces` dependency, which has no fixed release.
- uTLS client fingerprints (`client-fingerprint`) on non-REALITY nodes remain unsupported.

### Verified

- Engine unit tests 390 passed (9 new: fingerprint formats, pinning, wrong pin with skip-cert-verify, custom roots, unusable settings, signature policy, AnyTLS pin).
- Protocol interoperability gate (release build, two cycles): all five gates passed. The interop server certificate now comes from a throwaway CA, so pinned certificates connect for all 13 TLS cases (26), Hysteria2 and TUIC connect with `ca-str` (8), wrong pins are refused even with verification skipped (26) and untrusted chains are refused (26).
- App unit tests 380 + 84 + 20 passed (6 new); local regression `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh` and `./scripts/test.sh` passed with no compiler warnings.
- The Tart VM `macos27` was no longer available, so the 6-dimension matrix ran on the physical Apple Silicon Mac mini instead, with the notarized stable candidate and the same `test_runtime_acceptance.sh`: tun and transparent × rule, global and direct all passed; idle keep-alive reuse 6/6, 2 MiB upload 6/6 (3.5–4.5 s through the proxy, 12.4 s on transparent/direct), SNI recovery 3/3. Remote arm64 gate `test_remote_arm64.sh fast` passed. See `Docs/ReleaseExceptions/1.2.0.md`.

## [1.1.7] - 2026-10-04

Shadowsocks nodes no longer send UDP packets twice, and connections through SSH nodes no longer drop after 5 seconds of silence. Both were found by a stronger protocol interoperability suite, which now also covers bulk transfers, idle reuse, bursts of UDP datagrams and certificate verification for all twelve protocols. Other protocols, routing and both extensions behave as in 1.1.6.

### Fixed

- Shadowsocks: the first UDP datagram of a session, and any datagram sent while the socket was briefly busy, reached the server twice. When the first send was not ready, the retry queued the same datagram again. A plain Shadowsocks server forwarded both copies (DNS, QUIC, games and calls saw duplicate packets); a Shadowsocks 2022 server rejected the second with "packet id not unique". Each datagram is now sent once.
- SSH: every connection through an SSH node closed after 5 seconds without traffic, so pooled browser connections, streamed AI responses and long polling broke whenever they paused. The session no longer expires on silence; it ends when the connection closes, and a keepalive every 30 seconds (3 unanswered close it) still detects a server that went away.

### Added

- Protocol interoperability suite (engine `interop_tests.rs`, run against sing-box, Xray, Mihomo, wireguard-go and OpenSSH on loopback): every case now sends 2 MiB in both directions at once, reuses the same connection after an idle wait (`AETHER_INTEROP_IDLE_SECS`, default 5 s) and echoes 8 UDP datagrams, reporting any datagram that arrives twice. New cases: VMess over TLS, VLESS over TLS and TUIC v5 QUIC relay, plus UDP over WebSocket, gRPC and HTTP/2 for VMess, VLESS and Trojan (24 matrix cases, up from 21). Every TLS case is also run with certificate verification on and must refuse the self-signed test server. `AETHER_INTEROP_CASES` runs a subset.

### Notes

- Known compatibility gaps, unchanged: a `fingerprint` (certificate pin) does not let a self-signed node connect without `skip-cert-verify` as it does in Mihomo (VMess, VLESS and Trojan ignore the field; Hysteria2 checks the pin but still requires a public CA), and Hysteria2 ignores `ca` / `ca-str`.
- VMess with an explicit `cipher: aes-128-gcm` runs at about 33 MiB/s on loopback against 115 MiB/s for ChaCha20-Poly1305; `cipher: auto` already picks ChaCha20 on Apple silicon.

### Verified

- Protocol interoperability, debug and release builds: 24 matrix cases × 2 cycles, 26 certificate rejections, VLESS REALITY, WireGuard, ShadowQUIC and OpenSSH (also with a 50 s idle) all passed. Engine loopback throughput is unchanged (VLESS 1.9–2.0 GiB/s, Trojan 1.0 GiB/s, Shadowsocks 2022 0.66 GiB/s). The new Shadowsocks unit test fails on the previous engine and passes now.
- Local regression: `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh` and `./scripts/test.sh` passed with no compiler warnings.
- Tart VM 6-dimension matrix (`macos27`, build 2026100403): all six combinations passed in one run; idle keep-alive reuse 6/6, 2 MiB upload 6/6 (3.6–4.0 s), SNI recovery 3/3.
- Physical Apple Silicon Mac mini, notarized stable candidate with both system extensions at 1.1.7/2026100403: TUN and transparent proxy idle keep-alive reuse, 2 MiB upload and transparent SNI recovery passed; remote arm64 gate `test_remote_arm64.sh fast` passed. An A/B run against 1.1.6 on the same Mac in the same hour gave the same upload times once warmed up (1.1.7: 3.7–4.4 s, 1.1.6: 3.3–3.7 s; the first upload after connecting is slower on both).

## [1.1.6] - 2026-10-04

Rule resources (Country.mmdb and GeoSite.dat) now keep themselves current: AetherRoute checks them weekly while connected, downloads only when the upstream actually changed, and Download & Verify works without disconnecting. Routing, the network engine and both extensions are unchanged from 1.1.5.

### Added

- Rules → Rule resources → Advanced: a "Check for updates automatically" switch (on by default) with the date of the last check. While connected, AetherRoute looks every 6 hours (with up to 15 minutes of random delay) for resources that reached 7 days, so the upstream sees at most one check a week.
- Each check fetches the upstream SHA-256 file (under 100 bytes) first. If it matches the installed database, only the check date is recorded (`lastCheckedAt` in the resource metadata); the multi-megabyte database is downloaded only when it changed. An unchanged, checked database also counts as current for the 30-day limit.
- Download & Verify works while connected. New data is verified and saved, and applies on the next connection; the running tunnel keeps the copy it started with. Importing a file still needs a disconnect.

### Changed

- Automatic updates used to start only after a resource was 30 days old, the same day it expired, once per day after connecting. They now start at 7 days and retry after 1, 6 and 24 hours on failure, leaving about three weeks before the 30-day limit. From 25 days the card asks you to update.
- Resources you imported yourself are still never replaced automatically. Metadata written by earlier versions loads unchanged.

### Verified

- Local regression: `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh` and `./scripts/test.sh` passed with no compiler warnings. Six new unit tests cover the checksum-first refresh, unchanged upstream renewing an expired MaxMind database without a download, a concurrent import winning over a check, metadata from 1.1.5, a check date in the future, and the weekly/backoff policy.
- Tart VM 6-dimension matrix (`macos27`, build 2026100402): all six combinations passed in one run; idle keep-alive reuse 6/6, 2 MiB upload 6/6 (3.5–4.3 s), SNI recovery 3/3.
- Physical Apple Silicon Mac mini, notarized stable candidate with both system extensions at 1.1.6/2026100402: TUN — 2 MiB upload in 3.5 s (1.1.4: 3.5 s), idle keep-alive reuse passed; transparent proxy — 2 MiB in 3.9 s (1.1.4: 3.7 s), idle keep-alive reuse and SNI recovery passed. Remote arm64 gate `test_remote_arm64.sh fast` passed.
- On the Mac mini, connecting replaced a 29-day-old bundled GeoSite.dat and an 11-day-old Country.mmdb with the current upstream releases; both SHA-256 values match the published checksums.

## [1.1.5] - 2026-10-04

This release fixes a potential fatal crash in iCloud profile synchronization during first launch or empty state, eliminates a data race during network recovery in the packet tunnel provider, and adds App Store export compliance exemption metadata.

### Fixed

- iCloud Sync: fixed a critical runtime trap (`SIGTRAP`) when pulling cloud payloads with an empty local catalog or uninitialized sync timestamp (`Date.distantPast` resulting in a negative float overflow when cast to `UInt64`).
- Packet Tunnel: resolved an unprotected direct access to mutable `core` during `performNetworkRecovery`, ensuring calls strictly route through `currentCore()` under `coreLock` protection against race conditions with dynamic configuration reloads.
- Compliance: declared `ITSAppUsesNonExemptEncryption` in `Config/App-Info.plist` to streamline App Store Connect processing without manual prompts.

### Verified

- Local regression: `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh` and `./scripts/test.sh` passed with zero warnings.
- Tart VM 6-dimension matrix (`macos27`, build 2026100401): all six combinations passed; idle keep-alive reuse 6/6, 2 MiB upload 6/6, SNI recovery 3/3.
- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`): notarized stable candidate verified with TUN / transparent proxy double mode, idle keep-alive reuse, large upload, and remote arm64 gate (`test_remote_arm64.sh fast`) 100% passed.

## [1.1.4] - 2026-10-03

Every proxy group can be chosen again, and the menu bar panel's traffic graph now matches Overview. Routing, the network engine and both extensions are unchanged from 1.1.3.

### Fixed

- Proxies: clicking a proxy group (for example an automatic `url-test` group such as "SS-Proxy-AUTO") often did nothing, so only the first group could be opened. On macOS 27 the page's shared Liquid Glass container kept the click areas of glass cards that had moved or been replaced — when the page switched between its narrow and wide layouts, or a different group's card appeared — and those invisible areas swallowed clicks on the groups. The Proxies page no longer uses the shared container, and it picks its layout in the first frame instead of drawing the narrow layout and then switching. It looks the same as before.

### Changed

- Menu bar panel: download and upload are drawn in one graph on a shared scale, over the same 30-second window as Overview's live traffic, with the same coloured legend dots. Before, each had its own tiny line scaled to itself, so a small upload filled its line and looked like a spike, and the curves never matched Overview. The graph animates only while the panel is open.

### Added

- UI test `testEveryProxyGroupCanBeOpened`: in wide and narrow windows, every group opens in any order, including automatic groups (url-test, fallback), which explain why their nodes are chosen automatically instead of letting you pick one.
- Mac App Store channel (from the 1.1.2 submission) is now covered by `./scripts/test.sh`, and website builds refuse the Store compile flag, which would ship without an updater.
- `scripts/test_ui_in_vm.sh` runs the UI suite on the Tart VM or, with `AETHERROUTE_UI_REMOTE`, another Mac such as the physical Mac mini, using products built and signed on this Mac.

### Notes

- Protocol evidence and the license manifest record engine archives rebuilt in the main checkout; the engine source is unchanged (`d9f3952`). The archives' bytes depend on the checkout path, so the 1.1.3 hashes (built in a separate worktree) did not reproduce here.

### Verified

- Local regression: `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh` and `./scripts/test.sh` (now including the Store channel tests) passed with no compiler warnings.
- Proxy groups: `testEveryProxyGroupCanBeOpened` failed on the physical Mac mini before the fix (the click never reached the group) and passed four runs in a row after it, in wide and narrow windows; screenshots show the page unchanged.
- Full UI suite on the physical Mac mini (build 2026100303): 42 of 43 passed in one run; the remaining profile context-menu test passed on two separate reruns. Host network state was unchanged.
- Physical Apple Silicon Mac mini, notarized stable candidate with both system extensions upgraded to 2026100303: TUN — 2 MiB upload in 3.5 s, idle keep-alive reuse passed; transparent proxy — 2 MiB in 3.7 s, idle keep-alive reuse and SNI recovery passed. Remote arm64 gate `test_remote_arm64.sh fast` passed.
- Tart VM 6-dimension matrix (`macos27`, build 2026100303): all six combinations passed, `tun/rule` on a single-combination rerun after one IPv6 probe timeout; idle keep-alive reuse 6/6, 2 MiB upload 6/6, SNI recovery 3/3. See `Docs/ReleaseExceptions/1.1.4.md`.

## [1.1.3] - 2026-10-03

A maintenance release: plain HTTP proxy nodes are now covered by an automated test, clean builds of the network engine work again on macOS 27, and both system extensions can no longer crash on an unexpected control message. Routing behaviour is unchanged from 1.1.2.

### Fixed

- Build: compiling the network engine from a clean checkout failed on macOS 27 (`E0463: can't find crate for time_macros`). The macOS 14 deployment target was applied to the whole build, including the compiler plug-ins (proc macros) that rustc loads back into itself, which rustc 1.96 then could not read. Only a warm build cache had kept releases working. The deployment target now applies to the shipped engine only, through `scripts/rustc_target_deployment.sh`; the engine objects still target macOS 14.
- Extensions: the TUN and transparent proxy extensions stopped the whole process (and the network) if a "reload profile" message ever reached the generic message path. It is answered earlier, so this could not happen today; the path now returns an invalid-request reply instead of crashing.
- Test tooling: the installed-extension performance peer no longer prints a traceback when a client disconnects before its request is handled.

### Added

- `scripts/test_http_node_dial.sh` (part of `./scripts/test.sh`): drives the production engine through its local HTTP and SOCKS ports to a loopback HTTP CONNECT node that requires a username and password, and fails unless the node relays both requests. Fully offline.

### Notes

- Plain `type: http` nodes: in September (1.0.4 and 1.0.5) a profile with an HTTP node was accepted but the engine never connected to the node. This no longer happens: on build 2026100204 in the `macos27` VM, an HTTP node on the host carried all traffic in both TUN and transparent proxy mode (connection checks, google.com, github.com, wikipedia.org), and the new test passes.
- The protocol evidence and third-party license manifest record the rebuilt engine archives; their engine source is unchanged (`d9f3952`).

### Verified

- Local regression: `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh` and `./scripts/test.sh` (including the new HTTP node test) all passed; the new test fails as expected when the node rejects the credentials. The installed-extension collector tests passed 6 runs in a row with no traceback.
- Clean engine build: from an empty `.build/core`, both archives build, and their objects carry the same deployment targets as 1.1.2 (415 at macOS 14, 375 at 11.0 from Rust's bundled compiler-builtins).
- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`), notarized stable candidate with both system extensions upgraded to 2026100301: TUN — 2 MiB upload in 3.8 s, idle keep-alive reuse passed; transparent proxy — 2 MiB in 3.8 s, idle keep-alive reuse and SNI recovery passed; the app quit normally while connected. Remote arm64 gate `test_remote_arm64.sh fast` passed.
- Tart VM 6-dimension matrix (`macos27`, build 2026100301, two VMess fixtures on the host): all six combinations passed, `tun/global` on a single-combination rerun; idle keep-alive reuse 6/6, 2 MiB upload 6/6 (3.5–4.0 s through the proxy), SNI recovery 3/3. See `Docs/ReleaseExceptions/1.1.3.md`.
- Performance: the engine and data path are unchanged from 1.1.2; proxied 2 MiB uploads took 3.5–4.0 s in the VM (1.1.2: 3.7–4.6 s) and 3.8 s on the Mac mini in both modes (1.1.2: 3.9 s TUN, 4.7 s transparent).

## Mac App Store submission - 2026-10-02

- Added a separate Store build graph for 1.1.2/build 2026100203, retaining TUN
  and transparent proxy system extensions with Store-specific provisioning.
- Store builds exclude Sparkle, independent updater metadata, updater menu
  controls and updater sandbox exceptions; website builds retain their updater.
- Added Store graph regression tests and an exact signed-bundle audit. The four
  prescribed local regression suites, Store graph tests, signed-bundle/core/
  license checks, installer signature and physical arm64 fast gate all passed.
- Uploaded the Store candidate and submitted App Store Connect app 6818543727
  at 22:54 CST. Apple showed Waiting for Review; release is automatic after
  approval, free in 174 territories, with France excluded for encryption
  authorization requirements. Review approval and public availability remain pending.
- VM matrix scoring and Store-installed runtime acceptance remain incomplete;
  see `Docs/ReleaseExceptions/1.1.2-app-store.md`. The listing reuses an existing
  public 1.1.0 overview and does not claim it as this build's runtime evidence.
  No networking-core change or measured performance improvement is claimed.

## [1.1.2] - 2026-10-02

Quitting from the menu bar panel works again while connected, and every "copy proxy command" now copies the command that matches your local proxy. The network engine and extension code are unchanged from 1.1.1.

### Fixed

- Quit: choosing Quit in the menu bar panel's "…" menu while connected left AetherRoute waiting to quit forever, and every later quit request (including from scripts) was ignored until it was force-quit. The app asked to disconnect first, but the reply waited behind the very request that started the quit. Quit now disconnects and exits normally. This had been present since 1.0.31.
- Main menu › Proxy › Copy Terminal Export Command (⌃⌘C) copied a fixed `127.0.0.1:7890` command even when the local proxy was off or used other ports, so pasting it broke the terminal's network. It now copies the same command as the menu bar panel and Settings (your ports, `socks5h`, `NO_PROXY`) and is unavailable unless TUN is the engine and the local proxy is on. Copy Terminal Unset Command now also clears `NO_PROXY`.
- Menu bar panel: when "Copy Proxy Command" is unavailable, the menu now says why — turn on the local proxy in Settings › Network, or switch to TUN.

### Verified

- Local regression: `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh` and `./scripts/test.sh` (including the extended application termination guard) all passed.
- Quit fix: a minimal AppKit program that answers `.terminateLater` and replies from a main-actor task hangs when quit is requested the old way (a main-queue block) and exits when requested through the run loop, as the app now does. The termination guard fails on the old code.
- UI tests on the physical Mac mini for the local proxy copy rules and the free distribution Settings: 2 of 2 passed.
- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`), notarized candidate with both system extensions upgraded to 2026100202: TUN — 2 MiB upload in 3.9 s, 6 MiB in 7.7 s, idle keep-alive reuse passed; transparent proxy — 2 MiB in 4.7 s, 6 MiB in 10.9 s, idle keep-alive reuse and SNI recovery passed; the app quit normally while connected each time. Remote arm64 gate `test_remote_arm64.sh fast` passed.
- Tart VM 6-dimension matrix (`macos27`, build 2026100202): five combinations passed every check; all six passed idle keep-alive reuse, the 2 MiB upload (3.7–4.6 s) and, for the transparent engine, SNI recovery. One reachability probe timed out; see `Docs/ReleaseExceptions/1.1.2.md`.

## [1.1.1] - 2026-10-02

Settings and every form sheet now use the same Liquid Glass design as the main window, the privacy page is rewritten, and the menu bar panel's actions are easier to read. The network engine and extension code are unchanged from 1.1.0.

### Changed

- Settings: General, Network, Privacy & Diagnostics and About use the main window's design — a large title, each group a caption over a glass card with inset dividers, switches and controls on the trailing edge, and explanations under the card instead of inside it. The node editor and connection details sheets match.
- Privacy: "Private by default" replaces the long disclosure. Four short facts (on this Mac, nothing reported, no ads, never sold) and, right on the page, where data goes once connected — your proxy and DNS, which can see your IP address, and the update sources. The consent button floats over the content in a Liquid Glass bar. Settings shows one summary row whose "Show…" opens the same page.
- Menu bar panel: "Open AetherRoute" and "Test all" sit side by side at equal width; the version moved into the "…" menu, and an available update gets its own row.
- Secondary text uses fixed colours: Liquid Glass drew the system's secondary style too light on glass cards (about 3:1); it now keeps at least 4.5:1 in both appearances.

### Fixed

- English: the network engine control overflowed its card in the menu bar panel and covered its hint on Overview; both now use the short names "Transparent" and "TUN".
- Connections: at the narrowest window the table scrolled sideways and hid the Duration column; the columns now fit and Destination takes any extra width.
- Accessibility: page and Settings identifiers are no longer replaced by their containers; Settings switches carry their names and the whole row toggles them; the rules quick tests say "Test google.com" rather than a bare domain; the DNS "changed" marks have an image role.
- Contrast: rule kind tags, rule targets, the "Current" marks on Proxies and Profiles, the DNS runtime note and the Overview subtitle are stronger; notes under Settings cards are 11 pt so they stay legible on non-Retina displays.
- Long translations: Overview row titles wrap and the mode controls widen to fit instead of drawing past the window; the Connections filter becomes a menu when a translation outgrows the toolbar.

### Verified

- Local regression: `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh` and `./scripts/test.sh` all passed.
- Full UI test suite on the physical Mac mini (non-Retina, dark appearance): 42 of 42 passed, including the accessibility audits in light and dark appearance and long English text.
- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`), notarized candidate with both system extensions upgraded to 2026100201: TUN — 2 MiB upload in 4.6 s, 6 MiB in 5.5 s, idle keep-alive reuse passed; transparent proxy — 2 MiB in 3.5 s, 6 MiB in 7.3 s, idle keep-alive reuse and SNI recovery passed. Remote arm64 gate `test_remote_arm64.sh fast` passed.
- Tart VM 6-dimension matrix (`macos27`, build 2026100201): every combination passed idle keep-alive reuse, the 2 MiB upload (3.5–4.2 s) and, for the transparent engine, SNI recovery. Reachability probes timed out intermittently across two runs; see `Docs/ReleaseExceptions/1.1.1.md`. VM temporary files were cleaned up.

## [1.1.0] - 2026-10-01

A redesign of the whole interface in macOS 26 Liquid Glass, with simpler Proxies, DNS, Profiles and Rules pages. The network engine and extension code are unchanged from 1.0.38.

### Added

- One motion system: page entrances, number ticks, presses, disclosures, copy confirmations and list changes share the same timing, and every animation stops under Reduce Motion (a new guard script keeps it that way).
- Menu bar: 30-second download and upload trend lines under the rates; a one-line hint beside the routing mode and network engine.
- Overview traffic graph: a time axis and the peak rate in view.
- Profiles: removing a profile asks first; a profile file dropped onto the window imports it.
- Connections: a paused list is tinted so it never passes for a live one; a search or filter with no match says so.
- Help for the routing mode, next to the network engine help.

### Changed

- Liquid Glass throughout: the sidebar is the system's Liquid Glass sidebar; cards, buttons and segmented controls are glass over an opaque content layer, as Apple's guidelines ask, so secondary text keeps its contrast whatever the desktop shows. Every surface is the system's own glass, so the Liquid Glass setting (clear or tinted) in System Settings › Appearance and Reduce Transparency apply to AetherRoute as to Apple's apps. macOS 15 gets the closest material.
- Pages read like System Settings: a large title with the page's actions, grouped rows in glass cards with a colour tile for each item, and a colour tile for every sidebar page and Settings pane.
- Overview: the state at a glance — a shield medallion, one large word and a VPN-style switch — then live traffic with large numbers, then one "Route" group for the exit node (opens Proxies), routing mode, network engine and route check. The "Current route" diagram is gone.
- Menu bar panel: the same medallion and switch, traffic, exit and modes in one glass group, and glass buttons that stay legible while the app is in the background. The selected mode keeps its accent dot there.
- Proxies: only choosing a node and testing latency. Each node row shows selection, region code (SG, JP), name, protocol and a coloured latency; "Manual / Auto" became a "Pick the fastest node automatically" switch; automatic groups (URL test, fallback) are read-only and mark the node in use; strategy names are localised. Search, filters, grid view and latency bars were removed; the node inventory moved to Settings › Privacy & Diagnostics.
- DNS: one "Profile DNS" summary card with details folded away. With Transparent Proxy the TUN adjustments collapse to an explanation and a "Switch to TUN" button; with TUN they are pop-up menus whose "Follow profile" entry names the profile's value, with a dot on changed settings and "Restore defaults" only when something changed.
- Profiles: one "Add" menu (subscription, file, node) and an overflow menu for sync and archives; each profile row shows "Current" or a "Use" button instead of a radio and a badge.
- Rules: "Test a website or IP" leads the page and answers in place; when a GEOSITE/GEOIP rule needs runtime data it names that rule instead of guessing. Profile rules filter by where they send traffic (proxy, direct, reject); custom rules collapse to one line when empty; rule resources moved here from Profiles.
- Connections: the matched rule shows its kind and value separately, so a narrow column cuts the value, never the kind; the outlet has a coloured tile.

### Fixed

- English plural forms for rules, nodes, upstreams, resolvers and similar counts.
- Disabled controls say why (for example while connected) instead of only greying out; DNS options show the value actually in effect.
- Settings no longer opens scrolled down to the bypass field; local proxy ports are typed directly.
- Segmented controls no longer squeeze or overflow narrow windows.
- The selected sidebar item's icon vanished into the accent selection.
- Failure states: the sidebar dot is red and the primary action reads "Retry" with a retry icon.
- Contrast: sidebar status text and the privacy disclosure paragraph now pass the accessibility contrast audit.
- Settings: each sidebar row carried its identifier twice, so UI automation could not select a pane; the pane and page wrappers no longer replace each page's own accessibility identifier.
- The connection switch stays a button for VoiceOver while it shows progress.
- Connections table headers for traffic and duration now align with their right-aligned numbers.

### Removed

- About 20 components and some 70 interface strings that the redesign no longer uses.

### Performance

Page render time from navigation to first frame (Debug build with optimisation, Apple silicon; `Docs/PerformanceBudget.md`):

- Connections with 2,000 flows: 760 ms → about 310 ms (one pass counts outlets; the filter no longer rebuilds per row).
- Connections, standard fixture: 245 ms → 150–180 ms.
- Profiles with 500 nodes and 10,000 rules: 250 ms → 190–220 ms (node counts cached per profile).
- Overview and Rules on later visits: about 60 ms; Proxies and Rules lists load lazily.

### Verified

- Local regression: `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh` and `./scripts/test.sh` all passed.
- Tart VM 6-dimension matrix (`macos27`, build 2026100102): all six combinations passed, including idle keep-alive reuse, transparent SNI recovery and the large-upload gate (2 MiB in 3.6–4.0 s; 27 s under TUN global, still a pass). VM temporary files were cleaned up.
- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`), notarized candidate: TUN — 2 MiB upload in 4.1 s, 6 MiB in 6.1 s, idle keep-alive reuse passed; transparent proxy — 2 MiB in 3.9 s, 6 MiB in 6.1 s, idle keep-alive reuse and SNI recovery passed. Remote arm64 gate `test_remote_arm64.sh fast` passed (it first caught a Swift concurrency error that only Xcode 26.5 reports, fixed in this release).
- Build 2026100101 was superseded: the VM kept that build's system extensions because the rebuilt candidate had the same version and build number, so the release moved to 2026100102 with identical source.
- The full UI test suite was not rerun on the Mac mini after the accessibility fixes; see `Docs/ReleaseExceptions/1.1.0.md`.

## [1.0.38] - 2026-10-01

In-app help for the network engines and DNS settings, clearer menu bar states, and a current-node latency test on Overview. The network engine and extension code are unchanged from 1.0.37.

### Added

- Help for settings people commonly do not understand, opened from a small "?" button next to the setting and shown in a popover:
  - "Transparent Proxy or TUN?" on Overview, in the menu bar and in Settings › Network: what each engine does, its trade-offs (local proxy, DNS overrides, bypass rules, coexisting with Tailscale) and which to choose.
  - DNS page: what TUN runtime overrides are, and each option of resolution mode, IPv6 answers, rule-aware queries and hosts mapping.
  - Each popover links to the AetherRoute website.
- Overview: the exit's latency pill re-tests the current node when clicked; before the first test a "Test Latency" button appears. The pill had no action before and was drawn disabled.
- Menu bar: with no profile, the panel says so and offers "Add Profile"; after a failed connection it shows the reason and "Details" instead of only "Unavailable".
- About: the website's tagline and introduction, and links to the website, this version's release notes, release history, the privacy policy and support.

### Changed

- Routing mode and network engine controls keep the native translucent style and mark the selected segment with an accent-coloured dot. AppKit draws the selection in the accent colour only while the app is frontmost, and the menu bar panel never activates the app, so the selection there was a barely lighter gray.
- Engine descriptions in first-run setup and Settings use plain language.
- About no longer shows the author line.

### Fixed

- Menu bar "Copy Proxy Command" was available even when nothing listened on 127.0.0.1 (Transparent Proxy, or TUN with the local proxy off); it now follows the same rule as Settings.

### Verified

- Local regression suites: `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh`, `./scripts/test.sh`; 472 unit tests.
- Tart VM 6-dimension matrix (`macos27`, build 2026093006): all six combinations passed, including idle keep-alive reuse, transparent SNI recovery and the large-upload gate. In the first run `transparent/direct` timed out on the captive-portal probe alone (every other check in that combination passed); an isolated rerun passed it in 0.25 s. VM temporary files were cleaned up.
- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`), notarized candidate: TUN — 2 MiB upload in 6.6 s, 6 MiB in 8.7 s, idle keep-alive reuse passed; transparent proxy — 2 MiB in 4.0 s, 6 MiB in 6.6 s, idle keep-alive reuse and SNI recovery passed. Remote arm64 gate `test_remote_arm64.sh fast` passed; the Mac mini's proxy, DNS, route and interface state was identical before and after.

## [1.0.37] - 2026-09-30

First-run network setup, and an interface consistency pass based on a review of 1.0.36 with real profiles and traffic. The network engine and protocol code are unchanged from 1.0.36.

### Added

- First-run network setup: after the privacy disclosure, a new "Set Up Network Permissions" step installs both network engines' system extensions at once (switched on in a single visit to System Settings › General › Login Items & Extensions › Network Extensions) and saves both configurations (macOS asks to allow each). The main window opens only when both are ready, so connecting or switching engines later never stops for a system prompt. Each engine shows live status (checking, not set up, installing, waiting for you, ready, restart needed, not finished, unavailable) and what to do next; returning from System Settings re-reads what was granted without prompting.
  - Configurations are saved disabled, so creating the TUN configuration does not switch off another app's VPN; connecting enables it.
  - An engine blocked by organisation policy does not lock the user out; they continue with the other engine.
  - Existing installs are not sent through setup. Quitting halfway resumes setup at the next launch. The menu bar, global shortcuts and URL imports cannot connect before setup finishes.
  - When a permission is later withdrawn, the Overview recovery card offers "Set Up Permissions Again", which opens the same page.
- Profiles: with a single profile, an "Add another profile" card offers subscription, import and manual node shortcuts; the search field appears from three profiles.

### Changed

- Settings: all four tabs share one grouped form (width, margins, section headers); Privacy & Diagnostics and About are form sections instead of standalone cards and headings; the sidebar matches the main window (body text, gray selection) instead of large bold labels on a blue bar.
- One duration format across Overview, the Connections session bar and table: the two largest units, abbreviated ("2h 11m", "49m 2s") in the app's language, replacing "02:11:26" and "49m02s".
- Latency colours: green up to 200 ms and orange up to 500 ms (were 120 / 260 ms). The value is a full URL test through the node, so healthy cross-border nodes no longer all show red.
- Menu bar update pill: solid accent capsule with white text; it was hard to read on dark menus.
- Section headings (Proxy groups, Custom rules) and status pills share one component; the Rules page no longer repeats "Custom routing rules" inside its section.
- The main window keeps a 10-second traffic history on every page, so the Overview graph is drawn immediately when you return to it.

### Fixed

- About showed "Beta" on official releases: the published DMG was repackaged from a notarized candidate built with `AETHERROUTE_RELEASE_CHANNEL = beta` (1.0.34–1.0.36). Release candidates are now built with `AETHERROUTE_CANDIDATE_CHANNEL=stable`, and `package_release_dmg.sh` refuses any other channel.
- DNS: the four-way resolution mode control overflowed its card; segmented controls now keep their natural width and rows stack below the width they need.
- Profiles and DNS were narrower than the other pages (720 vs 960 points).
- In the Connections table only the destination column had a filled background.
- Bypass rule field showed its example as a row label with an empty field.

### Verified

- Local regression suites: `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh`, `./scripts/test.sh`; 472 unit tests.
- First-run setup on a reset Tart VM (`macos27`, both extensions uninstalled, configurations and preferences cleared): both extension requests submitted together, both switched on in one System Settings visit, configurations created, setup finished and the main window started normally.
- Upgrade from 1.0.36 on the physical Mac mini: not gated (`existing=true`), reconnected automatically; release channel `stable`.
- Tart VM 6-dimension matrix (`macos27`, build 2026093005): all six combinations passed, including idle keep-alive reuse, transparent SNI recovery and the large-upload gate. The three TUN combinations were rerun: the first run queried the configuration by name while a stale "AetherRoute" service left by the manual VM reset still held that name (the tunnel itself was up, `utun4` held the default route); after removing the stale service they passed. VM temporary files were cleaned up.
- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`), notarized candidate: TUN — 2 MiB upload in 6.0 s, 6 MiB in 7.0 s, idle keep-alive reuse passed; transparent proxy — 2 MiB in 3.7 s, 6 MiB in 6.4 s, idle keep-alive reuse and SNI recovery passed.
- Remote arm64 gate `test_remote_arm64.sh fast` passed; the Mac mini's proxy, DNS, route and interface state was identical before and after.

## [1.0.36] - 2026-09-30

A redesign of the app's interface. The network engine, protocols and extensions are unchanged from 1.0.35.

### Added

- Menu bar: the current version sits beside the "···" menu. When Sparkle finds a newer release it becomes a "New version x.y.z" pill that opens the update window; it stays after "Remind Me Later" and clears once the version is skipped or installed. The menu bar icon carries a small blue dot while an update is waiting. "Check for Updates…" and the running version head the "···" menu.
- Command palette (⇧⌘P, Navigate menu): connect or disconnect, reconnect, switch routing mode or network engine, test latency, switch nodes in the main group, and jump to any page or Settings from the keyboard.
- Automatic groups (url-test, fallback, load-balance) show the node they are actually using, read from live connection chains — "Singapore Edge · Auto" instead of a bare "Auto" — on Overview and in the menu bar. The group name is shown until traffic flows.

### Changed

- Menu bar panel redesigned in the style of Control Center: status ring, short status and a large switch at the top; exit node and latency test in the middle; routing mode and network engine below; copy-command, update and quit actions in a "···" menu. The node list uses flat rows with a hover highlight and hides search for eight or fewer nodes.
- Settings reorganised from nine tabs into four: General, Network (engine, routing, local proxy and bypass rules), Privacy & Diagnostics, and About (version, build, updates, open-source licenses). Links to the old tab names still land on the right tab.
- Overview: connection status, exit and route quality share one card; traffic appears only while connected; the connected duration ("Connected for 12 minutes") replaces "network extension reported ready". The selected segment of the routing-mode and network-engine controls is filled with the accent colour, so it is clear on dark backgrounds.
- All eight sheets (subscription, subscription link review, rename, archive export/import, iCloud sync, node editor, native profile, custom rule, connection details) share one header, width and button layout. The custom-rule sheet no longer overflows; connection details are grouped into Route and Traffic.
- Matched rules on the Connections page and in connection details use configuration spelling (`DOMAIN-SUFFIX`, `IP-CIDR`) instead of engine type names (`DomainSuffix`), matching the Rules page.
- Unified search field on the Proxies, Connections, Profiles and Rules pages; Proxies no longer shows a fixed-height table.
- Motion revised: page changes fade in the new page instead of morphing the whole window; the connecting indicator rotates an arc; the traffic graph scrolls smoothly; latency values roll between numbers. Reduce Motion is respected throughout.
- Typography and colour narrowed to system styles; decorative indigo/teal accents and glow removed.
- Telemetry refreshes every 3 s while the window is frontmost, every 10 s while it is visible behind other apps, and pauses otherwise; route health stays at 15 s in every state.

### Fixed

- The Connections page was pushed out of a narrow window (780×560, English) by a page subtitle that reported an unbounded height.
- Buttons whose title was a string literal (Save, Download and Save, Download & Verify, Check for Updates) stayed in English in Chinese; several sheet placeholders and options were untranslated.
- The Proxies node list showed one and a half rows at the minimum window size.
- The Overview exit showed a nested strategy group as a node with a placeholder "PROXY" protocol.
- Traffic numbers froze while the window was visible but not frontmost, and the Connections page did not refresh on its own.
- DNS runtime override rows squeezed their description into a narrow column; descriptions were styled heavier than their titles.
- "Automatic checks are on" was shown while automatic update checks were off.
- `scripts/test.sh` killed the host's running tunnel extension: the VM priming test ran its `sudo killall` for real instead of through its test double.

### Removed

- Unused Swift code and 148 unused localization strings (found with Periphery, each cross-checked), 60 unreferenced scripts and three orphaned probe programs.

### Verified

- Local regression suites: `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh`, `./scripts/test.sh`; 466 unit tests.
- Tart VM 6-dimension matrix (`macos27`, build 2026093003): all six combinations passed on the first run, including idle keep-alive reuse, transparent SNI recovery, and the large-upload gate; VM temporary files cleaned up afterwards.
- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`), notarized candidate: TUN — 2 MiB upload in 3.5 s, 6 MiB in 5.6 s, idle keep-alive reuse passed; transparent proxy — 2 MiB in 3.4 s, 6 MiB in 7.2 s, idle keep-alive reuse and SNI recovery passed.
- Remote arm64 gate `test_remote_arm64.sh fast` passed; the Mac mini's proxy, DNS, route and interface state was identical before and after.

## [1.0.35] - 2026-09-29

### Fixed

- Local client connections left half-closed by the proxy server are reclaimed (`Core/Engine` relay):
  1.0.32 removed every relay timeout for TUN, transparent-proxy and local HTTP/SOCKS flows so idle keep-alive connections survive, which also removed the half-close bound. When the client closed, the engine shut down its side toward the node and waited for the node's FIN; a node that acknowledged but never answered held the relay and its socket in `FIN_WAIT_2` until the extension restarted. On a Mac mini using a VLESS node, all 249 such sockets outlived the kernel's 60 s orphan timeout and the count grew by about 15 a minute. Once either direction has finished, the flow now ends after 60 s without traffic on the other; the timer resets on every byte, so a response still streaming after the client's FIN is not cut, and fully open idle connections still have no timeout.

### Verified

- Engine `cargo test -p clash-lib --lib`: 345 passed, 0 failed, including two new relay tests (an unanswered half-close is reclaimed after 60 s, which failed before the fix; a download still flowing 150 s after the client's FIN is not cut).
- Local regression suites: `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh`, `./scripts/test.sh`.
- Tart VM 6-dimension matrix (`macos27`, build 2026092903): all six combinations passed on the first run, including idle keep-alive reuse, transparent SNI recovery, and large-upload gate.
- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`): TUN and transparent proxy on-device verification passed (idle keep-alive reuse, large upload gate); remote arm64 gate passed.

## [1.0.34] - 2026-09-29

### Fixed

- Large uploads through VLESS `xtls-rprx-vision` nodes no longer break the connection (`Core/Engine` VLESS Vision):
  the Vision frame header stores the content length in a u16, but the relay hands the outbound 64 KiB buffers (65536 bytes, one past `u16::MAX`) whenever the client writes faster than the node's uplink drains. The length was truncated to 0 while the full payload followed, so the server parsed payload bytes as the next frame header and closed the connection about two seconds in. Uploads over about 1 MB failed (HTTP/2 framing error, empty reply) while rate-limited uploads and the same node through mihomo worked. This is why long Claude Desktop / Claude Code sessions, whose requests carry the whole conversation, failed on every retry with `ECONNRESET` under AetherRoute and worked under Clash Verge. Vision now frames at most 8 KiB per write, the Xray client buffer size, and reports the accepted count so the caller writes the rest.
- Hysteria2 is not affected: its TCP payload is written straight into a QUIC stream. Measured on the unfixed 1.0.33 through the same server: 2 MiB and 6 MiB uploads delivered in 3.6–6.3 s.

### Added

- Release gate `scripts/test_large_upload.sh`: a 2 MiB random upload to `httpbin.org/post` through the proxy must arrive intact with HTTP 200. It runs in every VM matrix combination and on the physical Mac for both engines; it failed on 1.0.33 (cut off after 1.9 s) and passed through Clash Verge on the same node.

### Verified

- Engine: `cargo test -p clash-lib --lib` 343 passed, 0 failed, including two new Vision tests that failed before the fix (a 64 KiB write reports at most one 8 KiB frame; a 65 KiB payload round-trips through well-formed frames). Runtime acceptance regressions: 43 cases.
- Local regression suites: `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh`, `./scripts/test.sh`.
- Tart VM 6-dimension matrix (`macos27`, build 2026092902): all six combinations passed on the first run, including the large-upload gate (7–11 s through the VLESS node; the two `direct` combinations bypass nodes and took 92–118 s over the VM's direct path), idle keep-alive reuse and transparent SNI recovery.
- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`), notarized candidate through the VLESS Vision node: TUN — 2 MiB in 4.0 s, 6 MiB in 6.2 s, idle reuse passed; transparent proxy — 2 MiB in 3.6 s, 6 MiB in 6.1 s, idle reuse and SNI recovery passed.
- Release exception: `test_remote_arm64.sh fast` ran every suite to completion but ended on its network-state check, because the TUN ↔ transparent switch for the on-device checks happened while it ran. Its rerun was skipped at the maintainer's request; the physical evidence for this release is the on-device checks above.

### Performance

- Frames above 8 KiB are split, adding a 5-byte header per 8 KiB (0.06 %) until Vision switches to direct copy after the inner TLS handshake.

## [1.0.33] - 2026-09-29

### Fixed

- Transparent-proxy mode routes HTTPS by the ClientHello hostname when the app supplied only an IP (`Core/Engine` dispatcher):
  apps that resolve names with their own DNS client (Chrome's built-in resolver) or dial a literal address hand the provider a bare IP and no hostname. Under poisoned DNS that IP belongs to an unrelated server (`www.google.com` → a Facebook address), so the engine sent the connection to the wrong host and it hung; Chrome could not open Google while curl and Safari, which resolve through macOS, worked. Port-443 transparent flows with an IP destination now read the TLS SNI, as Fake-IP flows already did, and fall back to the IP after the existing 500 ms wait when there is no readable ClientHello. TUN mode is unchanged.

### Added

- Release gate `scripts/test_transparent_sni_recovery.sh`: `curl --connect-to` dials `www.apple.com` at an unrelated IP (`1.1.1.1`) and must pass certificate verification for `www.apple.com`. It runs in the three transparent-engine VM matrix combinations and is recorded as skipped for TUN, which answers every lookup with a Fake-IP.

### Changed

- Release SOP: the Tart VM matrix and the physical Mac gate run in parallel.

### Verified

- Local regression suites: `test_network_switch_gate.py` (3/3), `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh`, `./scripts/test.sh`; engine `cargo test -p clash-lib --lib` 341 passed, 0 failed; runtime acceptance regressions 37 cases.
- Tart VM 6-dimension matrix (`macos27`, build 2026092901): all six combinations pass, including idle keep-alive reuse in all six and SNI recovery in the three transparent ones. The first `tun/direct` run timed out once on the captive-portal probe (the VM's direct path to Cloudflare took 1.4 s even with AetherRoute off); an isolated rerun of `tun/direct` passed.
- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`), notarized candidate: `test_remote_arm64.sh fast` passed. Transparent proxy: SNI recovery passed (failed on 1.0.32), headless Chrome loaded Google and YouTube (0 bytes on 1.0.32), idle keep-alive reuse passed. TUN: idle keep-alive reuse passed, Chrome loaded Google.
- `verify_protocol_matrix.sh` and `verify_licenses.sh source` pass; normal-core hashes match `Config/ProtocolCoreEvidence.json`.

### Performance

- No hot-path cost outside transparent port-443 flows that arrive without a hostname. Those wait for the first ClientHello bytes (already sent by the client immediately after connect), bounded by 500 ms per read and 16 KiB.

## [1.0.32] - 2026-09-28

### Fixed

- Idle keep-alive connections no longer die after 60 seconds (`Core/Engine` dispatcher):
  TUN and local HTTP/SOCKS flows used the upstream relay policy, which closed any connection that was silent for 60 seconds. Clients that pool connections reused one the relay had already closed and got `ECONNRESET`; Claude Desktop / Claude Code sessions stalled or failed between tool calls while Clash Verge worked. Every local client inbound now keeps idle connections open like the transparent proxy already did; the packet stack's TCP keep-alive still reclaims dead peers.
- Tracked connections no longer poll a completed close notification (`Core/Engine` tracked stream), which could panic once the manager had closed a connection.
- A live profile or custom-rule reload in TUN mode no longer leaves the tunnel connected with a stopped engine: the reload snapshot now carries the Fake-IP cache key from the launch snapshot instead of failing the key-length check.
- The diagnostic log level now reaches both Network System Extensions. They run as root and cannot read the level file in the user's App Group container, so the app passes the level in the launch snapshot.

### Added

- Packet Tunnel data-plane sampling: with diagnostics at standard level the extension records a line every 30 seconds with connection count, traffic, TCP connect errors, Fake-IP mapping and reverse-lookup failures, network resets, memory footprint and open descriptors; verbose level also lists the live connections with their proxy chain.
- Release gate `scripts/test_idle_keepalive_reuse.sh`: one TLS connection must answer a second request after 50 seconds idle. It runs in every VM matrix combination for both the TUN and transparent-proxy engines, and on the physical Mac for both engines.

### Verified

- Local Full Regression Test Suites:
  passed `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh`, and `./scripts/test.sh`.
- Tart Virtual Machine 6-Dimensional Matrix Acceptance (`macos27`):
  verified 100% pass across all 6 configurations (`tun/rule`, `tun/global`, `tun/direct`, `transparent/rule`, `transparent/global`, `transparent/direct`), including idle keep-alive reuse verification, followed by complete VM storage and log cleanup.
- Remote Physical Apple Silicon Hardware Validation (`chenxu@100.64.0.3`):
  verified all remote suites via `test_remote_arm64.sh fast` and idle keep-alive reuse 50s verification with 100% pass rate.
- Protocol Matrix & Licensing Verification:
  passed `verify_protocol_matrix.sh` and `verify_licenses.sh source` with strict core hash integrity.

## [1.0.31] - 2026-09-27

### Fixed

- Eliminated SwiftUI View Lifecycle State Update Faults (`ContentView.swift`):
  resolved runtime warnings regarding publishing changes from within view updates by dispatching `setRealtimeTelemetryPreferred` and related telemetry state synchronization via `DispatchQueue.main.async`.
- Decoupled Combine Pipeline Initial Subscriptions (`AppAutomationController.swift`):
  routed license and privacy observation subscriptions via `.receive(on: DispatchQueue.main)` to avoid re-entrant state modifications during app initialization.
- Graceful MenuBarExtra Quit & Fixed XPC Termination Assertions (`AetherRouteApp.swift`):
  isolated the Quit action from the AppKit menu event tracking loop via asynchronous dispatch, eliminating `0x7d` assertions, and added proper `applicationWillTerminate(_:)` cleanup hooks for tunnel resources and dispatch sources.
- Resilient Tunnel Reconnection & State Recovery (`TunnelManager+ConnectionLifecycle.swift`):
  introduced transient `.recovering` state indicator during automatic reconnect attempts following unexpected network extension termination (e.g. system route conflict NEVPNConnectionErrorDomain Code 12), preventing premature false-alarm error notifications.
- High-Sensitivity Active Route Probe Timeout (`TunnelStartupTimingPolicy.swift`, `TunnelManager+Telemetry.swift`):
  reduced active route probe timeout to 3.5s (`activeRouteProbeTimeoutMilliseconds = 3_500`), expediting node failure perception and failover.

### Verified

- 6-Hour Production Runtime Benchmark & Telemetry Profiling:
  verified 720 continuous 30-second telemetry cycles (5.99 hours), maintaining an average CPU usage of 0.28%, resident memory rock-solid between 66.8 MB and 68.2 MB (+1.4 MB drift, zero memory leaks), and stable 31 file descriptors with zero crashes.
- Local Full Regression Test Suites:
  passed `test_network_switch_gate.py`, `Tests/EngineReconnect/run.sh`, `Tests/RuntimeEnvironment/run.sh`, and `./scripts/test.sh`.
- Tart Virtual Machine 6-Dimensional Matrix Acceptance (`aether-diag-1434`):
  verified 100% pass across all 6 configurations (`tun/rule`, `tun/global`, `tun/direct`, `transparent/rule`, `transparent/global`, `transparent/direct`), followed by clean VM storage and log cleanup.
- Remote Physical Apple Silicon Hardware Validation (`chenxu@100.64.0.3`):
  verified all remote suites via `test_remote_arm64.sh fast` with high throughput and zero packet loss.

## [1.0.30] - 2026-09-27

### Added

- Comprehensive Connectivity Diagnostic Engine (`SupportDiagnosticsView.swift`):
  introduced a 5-stage automated connectivity testing pipeline (Engine Initialization, Node Selection & Protocol Verification, Local Proxy Listeners, Data-Plane Path Probing, and External Reachability), featuring millisecond latency metrics, stage status badges, and intelligent verdict cards (Healthy, Degraded, Blocked, Offline) with actionable troubleshooting recommendations.
- Full Bilingual UI Localization (`Localizable.xcstrings`):
  expanded complete English and Simplified Chinese localizations across all newly introduced diagnostic cards, tooltips, status badges, and edge-case error states.

### Changed

- Modernized UI Visual System & High-Contrast Navigation (`AetherRouteVisualSystem.swift`, `ContentView.swift`, `DNSPageView.swift`):
  enhanced sidebar selection highlight, border radii, and visual contrast across light and dark system appearances; refined DNS status pill layout, server cards, and latency display tags.
- Responsive Footer & Single-Line Accessibility Layout (`ContentView.swift`, `AetherRouteApp.swift`):
  re-architected the main window bottom status bar layout constraints to strictly prevent text wrapping and truncation across minimum window dimensions (<= 960px width) and large accessibility font scales (Expanded Text / Large Content Size), ensuring the version indicator (`v1.0.30`) and settings button remain cleanly aligned on a single row.

### Verified

- Remote Physical Apple Silicon Mac mini 6-Dimensional Matrix Acceptance (`100.64.0.3` / `192.168.50.226`):
  executed `physical-network-transaction.sh` on macOS 27.0 arm64 across all 6 proxy engines and routing modes (`tun/rule`, `tun/global`, `tun/direct`, `transparent/rule`, `transparent/global`, `transparent/direct`), achieving 100% pass across all data path, DNS, local proxy (:7890 HTTP, :7891 SOCKS5, mixed), captive portal, and Anthropic API penetration checks, followed by clean network baseline restoration.
- Automated UI Visual Regression Matrix:
  passed all 44 test cases (`capture_ui_review.sh`) across combinations of English/Chinese, Light/Dark appearance, and minimum window widths with Expanded Text without a single layout defect or overflow regression.
- Zero-Bundle & Release Packaging Gate Compliance:
  verified strict absence of private credentials or test configurations from distribution artifacts; Developer ID signed and Apple notarized with double ticket stapling.

## [1.0.29] - 2026-09-26

### Fixed

- Preserved Packet Tunnel Fake-IP mappings across provider and VM restarts in an authenticated encrypted cache. The desktop app supplies the cache key through the ephemeral provider launch snapshot because the Developer ID system extension cannot read the user's Keychain (`CoreBridge.swift`, `TunnelManager.swift`, Rust Core commit `4bf21dc`).
- Recovered HTTPS destinations from TLS ClientHello SNI when a client keeps a Fake-IP assigned by a version before the encrypted cache existed. Replayed the ClientHello unchanged and stopped unmapped Fake-IP addresses from being treated as public destinations.
- Exposed Fake-IP mapping and reverse-lookup failures alongside TCP connection and network-reset counters in provider diagnostics.
- Updated the local DMG cleanup guard and established the zero-test-note release packaging standard (`scripts/package_release_dmg.sh`), enforcing that production DMGs carry volume name `AetherRoute <VERSION>` and strictly prohibit `测试版本说明.txt` or `README.txt`.
- Enhanced Apple codesign timestamp retry and robustness in build scripts (`scripts/build_notarized_test_candidate.sh`, `scripts/thin_sparkle_framework.sh`).

### Verified

- Tart Virtual Machine 6-Dimensional Matrix Acceptance (`aether-diag-1434`):
  verified 100% pass across all 6 configurations (`tun/rule`, `tun/global`, `tun/direct`, `transparent/rule`, `transparent/global`, `transparent/direct`) on build 2026092601, followed by clean VM storage and log cleanup.
- Remote Physical Apple Silicon Hardware Validation (`chenxu@100.64.0.3` / `192.168.50.226`):
  executed `test_remote_arm64.sh fast` on macOS 27.0 arm64, verifying 100% pass across all 50+ test suites:
  - Multi-threaded TCP throughput reached **10.0+ Gbps** (Direct 10,047 Mbps, Engine 6,500 Mbps, 64.7% raw ratio, +0.040ms P95 latency);
  - UDP integrity test successfully transmitted and received 10,000 datagrams with **0 missing and 0 duplicates**;
  - Go distribution service race tests, DMG upgrade rollback, and UI isolation verified.
- Production Developer ID & Apple Notarization:
  - App notarization submission `15b22049-eed1-4cc8-badd-e3d4a7e79940`: Accepted & Stapled.
  - Final Release DMG notarization: Accepted & Stapled (`spctl --assess` passed).
  - Sparkle Appcast signed with official Ed25519 signature.

## [1.0.28] - 2026-09-25

### Fixed

- TUN Kernel Buffer Exhaustion (`ENOSPC` / `ENOBUFS`) Lossless Re-queue & Backoff Retry (`CoreBridge.swift`):
  resolved an issue where high-throughput downloads or bursty network traffic caused Darwin's `packetFlow.writePackets` to saturate the internal kernel TUN socket buffer and return `false` (`ENOSPC`). Previously, failed packet batches were silently dropped by the bridge, triggering severe TCP retransmissions, connection stalls, and stream dropouts ("断流"). Implemented bounded packet batch dispatch (`maximumPacketBatchSize = 32`), inspected write status, and on failure, non-destructively re-queued unwritten packets back to the head of the outgoing packet queue with a 2ms asynchronous backoff before re-flushing, guaranteeing ordered, zero-loss delivery and allowing kernel buffers to drain gracefully.
- Data Plane Probe Session Invalidation & Stale Route Auto-Healing (`TunnelManager+ConnectionLifecycle.swift`):
  resolved an issue where route candidate health checks (`currentRouteDataPlaneStatus`) used a static singleton `URLSession` whose internal connection pool cached stale sockets across interface changes, Wi-Fi reconnection, or route modifications. When path updates occurred, stale probes threw `networkConnectionLost` or `cannotConnectToHost`, triggering false-positive candidate failures and unnecessary fallback rollbacks. Refactored probe session management into dynamic thread-safe recreation (`resolveProbeSession`, `refreshProbeSession`), detecting transient connection drops and performing seamless single-attempt session refreshes before declaring route failure.
- Path Update Logging De-noising in Multi-Interface / Virtual Environments (`PacketTunnelProvider.swift`, `TransparentProxyProvider.swift`):
  reduced `NWPathMonitor` `stage=pathUpdate` status notifications from `.info` to `.debug`. In complex network setups with concurrent virtual interfaces (Tailscale, VM bridges, VPNs), frequent interface link events triggered continuous logging every few seconds, generating log noise and unnecessary idle thread wakeups.
- Version & Build Progression (`project.yml`):
  incremented marketing version to `1.0.28` and build version to `2026092501` to enable clean Darwin `sysextd` system extension upgrades across production installations.

### Verified

- Tart Virtual Machine 6-Dimensional Matrix Acceptance (`aether-diag-1434`):
  verified 100% pass rate across all 6 permutations (`tun/rule`, `tun/global`, `tun/direct`, `transparent/rule`, `transparent/global`, `transparent/direct`) on build 2026092501 running under macOS 27.0 with real-world proxy configurations and zero-bundle security compliance, followed by mandatory post-test VM disk, temporary artifacts, and log cleanup.
- Remote Physical Apple Silicon Hardware Validation (`chenxu@100.64.0.3`):
  executed `test_remote_arm64.sh fast` on macOS 27.0 arm64, verifying 100% pass across all 50+ test suites:
  - Multi-threaded TCP throughput achieved **10.4 Gbps** (10,488 Mbps) with 0 packet drops;
  - UDP integrity test successfully transmitted and received 10,000 datagrams with **0.0% loss**;
  - Authorizer service race conditions, DMG rollback, and UI isolation verified.
- Signed Local QA Candidate Packaging:
  built and verified Developer ID signed local QA candidate `outputs/qa-candidate-1.0.28-2026092501` with strict codesign designated requirements, hardened runtime, and license notices verified.

## [1.0.27] - 2026-09-24

### Fixed

- Virtual Overlay Network (Tailscale CGNAT) Kernel Route Hijack Prevention (`PacketTunnelNetworkSettingsPlan.swift`, `PacketTunnelProvider.swift`, `TunnelManager.swift`):
  resolved a critical Darwin routing conflict where user-defined bypass CIDRs or custom rules containing `100.64.0.0/10` or IPv6 overlay subnets (`fd00::/8`, `fc00::/7`) were passed to `NEIPv4Settings.excludedRoutes` / `NEIPv6Settings.excludedRoutes`. In macOS Darwin, `excludedRoutes` instructs `nesessionmanager` to install an unscoped physical gateway route on `en0`, which causes Darwin kernel to create cloned `/32` host routes (e.g. `100.64.0.1 -> 192.168.50.1 on en0`), hijacking traffic away from Tailscale's `utun*` interface and freezing active SSH/TUN sessions. Added `isVirtualOverlayRoute` guard to strictly prevent virtual overlay routes from ever entering kernel `excludedRoutes`, added defense-in-depth filtering in `PacketTunnelProvider`, and added automatic sanitization in `TunnelManager`.
- System Extension Upgrade & Version Bumping (`project.yml`):
  incremented build number to `2026092402` to ensure Darwin `sysextd` cleanly detects and upgrades existing resident system extensions without binary hash discrepancies.

### Verified

- Tart Virtual Machine 6-Dimensional Matrix Acceptance (`aether-diag-1434`):
  verified 100% pass rate across all 6 configurations (`tun/rule`, `tun/global`, `tun/direct`, `transparent/rule`, `transparent/global`, `transparent/direct`) on build 2026092402, with automatic post-test VM disk, temporary artifacts, and log cleanup.
- Physical Apple Silicon Mac mini Remote Gate (`chenxu@100.64.0.3`):
  executed `test_remote_arm64.sh fast` on macOS 27.0 arm64, verifying 100% pass across all 50+ test suites (TCP flow throughput > 7500 Mbps, UDP 10,000 datagrams 0 drops).
- Live Physical Mac mini Verification:
  installed and ran official notarized build on `chenxu@100.64.0.3`. Verified AetherRoute connected (`流量路由已启用`), verified `route -n get 100.64.0.1` stably routes through `utun2` (Tailscale), and verified ping to `100.64.0.1` achieves 0.0% packet loss with ~25ms latency with zero SSH disconnection.

## [1.0.26] - 2026-09-24

### Fixed

- Core Engine Physical Interface Socket Binding Bypass for Overlay Networks (`socket_helpers.rs`, `proxy/direct/mod.rs`):
  resolved an issue where outgoing DIRECT TCP and UDP sockets created by the core proxy engine were forcibly bound to the physical outbound network interface (e.g. `en0` via `IP_BOUND_IF`), preventing the Darwin kernel from routing packets to virtual network interfaces like Tailscale's `utun*`. Implemented `is_overlay_network_address` filtering in Core Engine socket binding to bypass interface binding for Tailscale CGNAT subnet (`100.64.0.0/10`) and IPv6 overlay network (`fd7a:115c:a1e0::/48`), restoring direct peer-to-peer and virtual overlay routing.
- Domestic Routing & Tailscale DERP/Headscale Bypass (`DomesticRoutingOptimizer.swift`):
  added automated bypass rules and Fake-IP exclusion for Tailscale coordination and relay infrastructure, including `tailscale.com`, `ts.net`, `headscale.net`, `controlplane.tailscale.com`, and private Headscale DERP server relays.
- Custom Rule Subnet Validation (`CustomRule.swift`):
  prevented `/0` mask input in custom CIDR rules to ensure user rules cannot inadvertently degrade into global `0.0.0.0/0` catch-all filters.
- Core Protocol Evidence & License Manifest Synchronization (`ProtocolCoreEvidence.json`, `ThirdPartyLicenses.json`):
  updated git submodule commit `c23370da96b70e6282f04254b4a93761e2a54fee` and binary hashes for `libclashrs.a` and `libclashrs-direct.a`, ensuring 100% compliance with protocol release verification standards.

### Verified

- Tart Virtual Machine 6-Dimensional Matrix Acceptance (`aether-diag-1434`):
  verified 100% pass rate across all 6 configurations (`tun/rule`, `tun/global`, `tun/direct`, `transparent/rule`, `transparent/global`, `transparent/direct`) on build 2026092401 with automated post-test disk and log cleanup.
- Physical Apple Silicon Mac mini Remote Validation (`chenxu@100.64.0.3`):
  executed `test_remote_arm64.sh fast` on macOS 27.0 arm64, verifying 100% pass across all 50+ test suites (TCP flow throughput 7579 Mbps, packet engine 4484 Mbps, UDP integrity 10,000 datagrams with 0 drops). Tailscale SSH connectivity and peer ping latency verified fast and stable with AetherRoute running.

## [1.0.25] - 2026-09-23

### Fixed

- Tailscale Virtual Overlay Network Routing Collision (`PacketTunnelNetworkSettingsPlan.swift`, `PacketTunnelProvider.swift`):
  resolved an architectural flaw where Tailscale CGNAT subnet `100.64.0.0/10` and custom direct CIDRs were previously placed into Apple NetworkExtension's `NEIPv4Settings.excludedRoutes`. In macOS Darwin, `excludedRoutes` forcibly installs a global static gateway route pointing to the physical LAN interface gateway (e.g. `10.8.7.254` on `en11`), which superseded Tailscale's scoped interface route on `utun4` and dropped all Tailscale peer and SSH traffic to `100.64.0.x`. Removed `100.64.0.0/10` and custom CIDRs from kernel `excludedRoutes` while maintaining native direct routing and Fake-IP filtering at the Clash engine layer (`DomesticRoutingOptimizer.swift`), allowing Tailscale and other overlay mesh networks to function natively with zero interference.
- Core Engine Monotonic Clock Skew & Sleep/Wake Resilience (`Core/Engine`):
  updated clash core submodule (`7bb5f30`) to avoid potential panics from monotonic clock skew during system sleep/wake cycles across UDP and session timers (`saturating_duration_since`), synchronized `ProtocolCoreEvidence.json` commit and binary hashes, and updated `ThirdPartyLicenses.json`.

### Verified

- Tart Virtual Machine 6-Dimensional Matrix Acceptance (`aether-diag-1434`):
  verified 100% pass rate across all 6 configurations (`tun/rule`, `tun/global`, `tun/direct`, `transparent/rule`, `transparent/global`, `transparent/direct`) on build 2026092303 with complete post-test VM disk and log cleanup.
- Physical Apple Silicon Mac mini Remote Validation (`chenxu@100.64.0.3`):
  executed `test_remote_arm64.sh fast` on macOS 27.0 arm64, verifying 100% pass across all 50+ test suites (TCP flow throughput 7579 Mbps, packet engine 4484 Mbps, UDP integrity 10,000 datagrams with 0 drops). Tailscale connections and direct routing verified functional and stable.

## [1.0.24] - 2026-09-23

### Added

- User Custom Routing Rules & Syntax Validation (`CustomRule.swift`, `CustomRuleStore.swift`, `RulesPageView.swift`):
  introduced full user custom routing rules capability supporting `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `IP-CIDR`, `IP-CIDR6`, and `GEOIP` rules with custom targets (`DIRECT`, `REJECT`, `PROXY`, or custom proxy groups). Features dual-mode editing (visual form or standard Clash text line syntax), real-time syntax checking via `CustomRuleValidator`, and atomic persistence in App Group (`custom-rules.v1.json`).
- Live Custom Rule Simulation & Real-time Verification (`RulesPageView.swift`, `ProfileConfigurationSummary.swift`):
  added one-click rule verification and dry-run simulation in the rule editor and main rules page, displaying custom rule matches with distinctive green `CUSTOM` badges and detailed rule trigger rationale.
- Seamless Live Reload for Custom Rules (`TunnelManager+CustomRules.swift`):
  rule addition, updating, deletion, or toggle operations dynamically reconfigure the running engine via lightweight IPC payloads (`reloadProfile`) without restarting network extensions or dropping active connections.

### Fixed

- Tailscale CGNAT Routing & Private Headscale Timeout (`PacketTunnelNetworkSettingsPlan.swift`, `DomesticRoutingOptimizer.swift`):
  added Tailscale CGNAT IPv4 address block `100.64.0.0/10` (`255.192.0.0`) to the kernel default excluded routes, preventing the TUN network extension from capturing Tailscale subnet and DERP traffic. Added pre-configured bypass and Fake-IP avoidance for Tailscale domains (`tailscale.com`, `ts.net`), resolving connection and SSH timeouts permanently.
- Application Termination Synchronization & Shutdown Lag (`AetherRouteApp.swift`, `TunnelManager.swift`):
  added synchronous `prepareForApplicationTermination()` cleanup during application quit events, immediately cancelling active connection readiness tasks, periodic route telemetry, and URLSession probes. Completely eliminated MainActor task queue starvation, reducing graceful disconnect and quit latency from 60s to < 0.5s.
- Protocol Evidence Hash Synchronization (`Config/ProtocolCoreEvidence.json`):
  aligned `flowCoreSHA256` and `packetFlowCoreSHA256` in ProtocolCoreEvidence.json with the production core artifacts (`libclashrs.a` and `libclashrs-direct.a`), passing protocol release matrix verification.

### Verified

- Tart Virtual Machine 6-Dimensional Matrix Acceptance (`aether-diag-1434`):
  verified 100% pass rate across all 6 permutations (`tun/rule`, `tun/global`, `tun/direct`, `transparent/rule`, `transparent/global`, `transparent/direct`) with automated cleanup and Tart VM shutdown.
- Physical Apple Silicon Mac mini Validation (`chenxu@100.64.0.3`):
  executed `test_remote_arm64.sh fast` on macOS 27.0 arm64, verifying all 50+ test suites with 100% pass (TCP throughput 8032–9670 Mbps, UDP integrity 10,000 datagrams with 0 drops). Tailscale SSH connection verified fast and persistent without timeout.

## [1.0.23] - 2026-09-22

### Added

- Engineering & Verification Standards Codification (`AGENTS.md`):
  established a mandatory 5-step Standard Operating Procedure (SOP) covering local regressions, unattended Tart VM 6-dimensional network matrix acceptance with guaranteed post-run VM cleanup, remote Apple Silicon physical hardware validation on `chenxu@100.64.0.3`, semantic versioning with changelog tracking, and notarized release deployment with Cloudflare Pages sync.

### Changed

- Core Engine Memory-Mapping & Jetsam Budget Optimization (`Core/Engine`):
  migrated MaxMind GeoIP MMDB resolution to zero-copy memory-mapped I/O via `memmap2`, eliminating heap duplication and bringing resident memory well within the strict 15MB iOS Network Extension Jetsam threshold while substantially reducing macOS provider heap footprint.
- Bounded Tokio Asynchronous Runtime (`Core/Engine`):
  clamped Tokio worker thread pools to conservative boundaries to minimize multi-threaded context switching overhead and memory thrashing in background network extensions.

### Fixed

- Network Configuration Notification Flooding (`PacketTunnelProvider.swift` & `TransparentProxyProvider.swift`):
  resolved high-frequency Darwin CoreFoundation notification churn (>220 events/sec) during tunnel establishment and network interface transitions (`installNetworkSettings`) by introducing a 150ms debounce window and reusing persistent `SCDynamicStore` sessions, eliminating CF network framework throttling warnings.

### Verified

- Tart Virtual Machine 6-Dimensional Matrix Acceptance (`aether-diag-1434`):
  verified 100% pass rate across all 6 engine and routing configurations (`tun/rule`, `tun/global`, `tun/direct`, `transparent/rule`, `transparent/global`, `transparent/direct`) with automated teardown and clean VM state restoration.
- Physical Apple Silicon Mac mini Validation (`chenxu@100.64.0.3`):
  executed `test_remote_arm64.sh fast` on macOS 27.0 arm64, verifying all 50+ test suites including TCP throughput (7490–8264 Mbps), UDP integrity (10,000 datagrams with 0 drops), Go distribution service race tests, and seamless DMG upgrade/rollback.

## [1.0.22] - 2026-09-20

### Added

- Cross-Platform iCloud Profile Catalog Sync (`ProfileCloudSyncManager.swift`, `ProfileCloudSyncSheet.swift`, `ProfilesPageView.swift`):
  introduced end-to-end encrypted profile catalog synchronization between macOS and iOS devices through iCloud Private Database and synchronizable Keychain, supporting conflict resolution, manual sync triggers, and real-time status reporting.

### Changed

- Live Profile Reload via Direct IPC Payload (`ProxySelectionProviderMessage.swift`, `ProviderMessageRouting.swift`, `ProxySelectionProviderClient.swift`, `TunnelManager+Profiles.swift`):
  replaced disk-based snapshot sharing (`pending-reload-snapshot.bin`) with lightweight binary PropertyList transmission directly over `ProxySelectionProviderRequest.reloadProfile(Data)`, complying strictly with Zero-Bundle security and iOS/macOS Jetsam IPC guidelines (< 128 KB, actual payload ~5–35 KB).

### Fixed

- Cross-UID Sandbox Container Isolation on macOS:
  resolved live profile reload failure where root-owned Network Extensions (`com.aetherroute.desktop.tunnel` / `transparent-proxy`) running in `/private/var/root/Library/Group Containers` could not access user-owned profile archives or Keychain keys in `~/Library/Group Containers`. Completely eliminated tunnel teardown, process restart, or dropped TCP connections during live profile switching.

### Verified

- Live Profile Reload in Tart Virtual Machine (`aether-diag-1434`):
  verified 100% seamless profile reload during active tunnel connection with 10/10 HTTP 200 requests, 0 dropped connections, identical tunnel process PID, and continuous `utun` interface persistence.
- Tart Virtual Machine Matrix Acceptance (`test_vm_acceptance_matrix.sh`):
  verified 100% pass rate across all 6 engine and routing permutations (`tun/rule`, `tun/global`, `tun/direct`, `transparent/rule`, `transparent/global`, `transparent/direct`).
- Network Disconnect & Reconnect Recovery (`test_vm_network_recovery.sh`):
  verified automatic uplink recovery and core reset when physical network link `en0` is interrupted for 8 seconds, confirming zero process restarts and immediate resumption of traffic.
- Physical Apple Silicon Host Validation (`chenxu@100.64.0.3`):
  verified 100% pass across all 50+ test suites (TCP throughput > 8500 Mbps, UDP integrity 10,000 datagrams with 0 drops, Go distribution race tests, DMG upgrade/rollback).

## [1.0.21] - 2026-09-20

### Added

- Proactive Background Memory Trimming (`AppWindowManager.swift`):
  integrated Darwin `malloc_zone_pressure_relief` upon window closure and miniaturization, actively releasing unreferenced heap pages to the system and trimming background resident memory footprint from ~123MB down to 60–90MB while running in the menu bar.

### Changed

- Packet Tunnel Buffer Pre-Allocation (`CoreBridge.swift`):
  pre-allocated capacity (`reserveCapacity(64)`) on outgoing packet queues during burst I/O writes, eliminating dynamic array reallocation overhead and reducing memory thrashing under high packet throughput.

### Verified

- 10-Hour Soak & Telemetry Long-Run:
  completed a continuous 10.0-hour monitoring run (600 samples at 1-minute intervals) with zero crashes, 100% canary HTTP probe success (600/600), 0 interface errors, and an average App CPU load of 0.04% (P95 0.00%).
- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`):
  executed `test_remote_arm64.sh fast` over SSH, successfully validating all Network Extensions, core bridges, and proxy protocols with 100% pass rate.
- Tart Virtual Machine Matrix Acceptance (`aether-diag-1434`):
  verified 100% pass across all 6 engine and routing permutations (`tun/rule`, `tun/global`, `tun/direct`, `transparent/rule`, `transparent/global`, `transparent/direct`).

## [1.0.20] - 2026-09-19

### Added

- Menu Bar Popover Fast Node Search (`AetherRouteApp.swift`):
  integrated instant keyword search and real-time node filtering (`searchText`, `isFiltering`) into `MenuNodeListInline`, enabling swift proxy node lookup by keyword or protocol without navigating submenus.
- Profile Subscription Auto-Update Interval (`TunnelManager+Profiles.swift` & `ProfilesPageView.swift`):
  added configurable subscription refresh schedules (1h, 6h, 12h, 24h, or manual) with persistent storage and scheduled background timer synchronization.
- Rule Simulator Quick Domain Presets (`RulesPageView.swift`):
  added quick preset chips (`google.com`, `apple.com`, `github.com`, `bilibili.com`) inside the Rule Simulator test panel for one-click route diagnostics.

### Changed

- Connections Page Outlet Column Expansion (`ConnectionsPageView.swift`):
  expanded Outlet column width (`min: 100, ideal: 160, max: 320`) and added `.truncationMode(.middle)` with `.help(outlet.localizedTitle)` tooltips, completely resolving proxy outlet name truncation.
- Proxies Page Responsive Grid Adaptation (`ProxiesPageView.swift`):
  fine-tuned adaptive card column widths (`min: 250, max: 380`) to provide an optimal multi-column layout on wide screens while maintaining compact density on 13" laptop displays.
- Profile Row Activation Simplification (`ProfilesPageView.swift`):
  eliminated the redundant "使用" (Use) button on inactive profile rows, allowing whole-row click activation while retaining radio-button status indicators and full accessibility identifiers.
- Accidental Tunnel Teardown Guard (`ConnectionsPageView.swift`):
  added a modal confirmation dialog (`confirmationDialog`) to "全部断开" (Disconnect All) to prevent accidental VPN disconnection.

### Fixed

- AppKit Termination Responder Validation & Re-Entrant Termination (`AetherRouteApp.swift`):
  conformed `AetherRouteApplicationDelegate` to `NSMenuItemValidation` and `NSUserInterfaceValidations`, installed an explicit AppleEvent handler for `kCoreEventClass` / `kAEQuitApplication`, and guarded termination entry points against re-entrant calls (`terminationReplyPending`, `signalTerminationPending`), guaranteeing clean Network Extension route restoration before exit.
- Core Artifact Hashes Synchronization (`ProtocolCoreEvidence.json` & `ThirdPartyLicenses.json`):
  synchronized flow core and packet tunnel static library SHA-256 evidence hashes with rebuilt release binaries, passing strict protocol matrix verification.

### Verified

- Tart Virtual Machine Matrix Acceptance (`aether-diag-1434`):
  verified 100% pass rate across all 6 engine and routing permutations (`tun/rule`, `tun/global`, `tun/direct`, `transparent/rule`, `transparent/global`, `transparent/direct`), confirming zero leaks, immediate route tear-down, and baseline route restoration.
- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`):
  executed `test_remote_arm64.sh fast` over SSH, successfully validating all Network Extensions, core bridges, and proxy protocols with 100% pass rate.
- Product Test Suite (`scripts/test.sh`):
  passed all 280+ unit, integration, memory budget, and design token guard tests with 0 failures.

## [1.0.19] - 2026-09-19

### Added

- UI Toggle for Domestic & Apple Routing Optimization (`TunnelManager` & Settings Views):
  integrated a user-facing toggle (`isDomesticRoutingOptimizationEnabled`) in Profiles and General settings,
  enabling users to dynamically enable or disable lossless in-memory domestic routing optimization with immediate reload.
- Dual-Engine Symmetrical Physical Network Recovery (`TransparentProxyProvider`):
  introduced system-level `NWPathMonitor` and `SCDynamicStore` physical interface monitors to `TransparentProxyProvider`,
  matching `PacketTunnelProvider`'s interface signature change detection and triggering seamless core resets on Wi-Fi/cellular transitions.
- Robust YAML List and Token Sanitization (`DomesticRoutingOptimizer`):
  enhanced fault tolerance for empty inputs, inline comments, blank lines, and malformed empty rule items (`- -`, `- ''`, `- ""`).

### Changed

- Core Architecture Refactoring & Large Object Modularization (`TunnelManager`):
  decoupled the 6,408-line monolithic `TunnelManager` into 7 high-cohesion, single-responsibility domain extensions
  while preserving 100% backward API compatibility:
  - `TunnelManager+ConnectionLifecycle.swift`: connection establishment, teardown, and abnormal termination handling;
  - `TunnelManager+ProviderManagement.swift`: Network Extension registration, state synchronization, and IPC communication;
  - `TunnelManager+Profiles.swift`: profile import, activation, and hot-reload workflows;
  - `TunnelManager+RoutingResources.swift`: GeoSite, GeoIP, and domestic rule asset management;
  - `TunnelManager+ProxySelection.swift`: proxy node selection and policy group switching;
  - `TunnelManager+Telemetry.swift`: real-time throughput metrics and connection statistics;
  - `TunnelManager+Latency.swift`: concurrent latency benchmarking and health probes.
- UI Page Extraction & Component Modularization:
  - `ContentView.swift`: extracted 1,360 lines of profile management logic into dedicated `ProfilesPageView.swift`;
  - `FeatureViews.swift`: decoupled into specialized `RulesPageView.swift` (794 lines) and `DNSPageView.swift` (860 lines).
- UI Design System Token Enforcement:
  eliminated hardcoded system colors and fonts across Views, standardizing on `DesignSystem` semantic tokens and
  reinforcing weak reference captures to prevent retain cycles.

### Fixed

- Single Test Sandbox File Flush Race Condition (`CancellationTests.swift`):
  ensured python test subprocess flushes and fsyncs PID files before returning, eliminating intermittent JSON decoding errors in unattended CI/CD test gates.
- Dock Icon Visibility & Window Reopen Lifecycle:
  resolved an issue where dock icon concealment policy was lost upon application restart or window recreation.
- Automatic Update Check Debounce & Cooldown Protection:
  prevented rapid duplicate update checks when enabling automatic updates in settings.

### Verified

- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`):
  executed `test_remote_arm64.sh fast` over SSH, successfully validating all Network Extensions, core bridges,
  and proxy protocols with 100% pass rate.
- Tart Virtual Machine 6-Dimensional Matrix (`aether-diag-1434`):
  unattended end-to-end matrix across TUN and Transparent engines under Rule, Global, and Direct modes passed cleanly (0 failures, 0 crashes).
- Product Test Suite (`scripts/test.sh`):
  full product test suite containing 280+ unit, integration, and performance boundary tests passed cleanly with 0 failures.

## [1.0.18] - 2026-09-18

### Added

- Lossless In-Memory Domestic & Apple Acceleration Engine (`DomesticRoutingOptimizer` in `AetherRouteKit`):
  introduced a zero-configuration, lossless in-memory profile optimization engine. Leaves on-disk user
  profiles completely untouched while dynamically injecting high-priority domestic direct rules, CDN domain
  bypass policies, and domestic upstream DNS mappings at runtime.
- Apple CDN Line-Rate Bypass & Fake-IP Protection:
  ensured Apple critical system update and media domains (`swcdn.apple.com`, `updates.cdn-apple.com`,
  `appldnld.apple.com`, etc.) bypass Fake-IP resolution and map directly to domestic Anycast IPs,
  achieving saturated physical line-rate throughput without manual configuration.
- Domestic Fast DNS Integration:
  automatically maps mainland Chinese domains and Apple infrastructure to domestic low-latency DNS
  (`223.5.5.5`), eliminating overseas DNS contamination and latency penalties.

### Fixed

- Network Transition Oscillation & Feedback Loop (`TunnelManager`):
  resolved an oscillation defect where app-layer triggers on `.networkPathChanged` called `resetNetwork()`,
  re-triggering provider reassertion and generating an endless loop. Reverted app-level trigger to
  `.systemDidWake`, delegating physical interface transitions to `PacketTunnelProvider`'s native
  `NWPathMonitor` and `SCDynamicStore` path-signature observers.
- Clash-RS Compatible Profile & List Parsing:
  added support for non-indented YAML list items (`- name: ...`), robust key normalization (case/plural
  variations of `rules`, `proxy-groups`, `proxies`), and cleaned up unquoted wildcard domain policies
  for strict trie compatibility.

### Verified

- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`):
  deployed notarized release candidate build 2026091816. Verified domestic CDN throughput at 34.9 MB/s,
  confirmed genuine China Mobile CDN IP resolution for `swcdn.apple.com` (no Fake-IP contamination),
  verified HTTP/2 proxying for overseas endpoints, and confirmed zero tunnel oscillation.
- Tart Virtual Machine Matrix (`aether-diag-1434`):
  executed full acceptance matrix across TUN and Transparent Proxy modes in Rule, Global, and Direct
  configurations with 100% pass rate (`TOTAL_FAIL=0`, 0 crashes).
- Product Test Suite:
  all 104+ unit tests, regression suites, and integration tests passed cleanly.

## [1.0.17] - 2026-09-18

### Fixed

- Startup Auto-Reconnect Gate Decoupling (`TunnelManager`):
  resolved a critical race/gate defect where the `isPreparing` flag remained set during
  `restorePreviousConnectionIfRequested()`, causing `canConnect` to evaluate to false and
  unconditionally skip auto-reconnection on system boot and cold launch. Introduced a decoupled
  `canRestorePreviousConnection` security gate and reset `isPreparing` immediately upon
  extension registration.

### Changed

- Menu Bar Resource Optimization (`AetherRouteApp`):
  introduced `MenuBarVisibilitySynchronizer` to dynamically activate real-time telemetry
  only when the menu bar popover is visibly occluded/expanded, eliminating background CPU
  and timer overhead when hidden.
- TCP Half-Close Timeout Watchdog (`TCPFlowStateMachine`):
  implemented a 15-second watchdog timer to safely cancel lingering half-closed transparent proxy
  streams, preventing socket descriptor leaks.
- Outbound Packet Batching (`CoreBridge` in `AetherRoutePacketTunnel`):
  introduced thread-safe queue buffering with `outgoingPacketLock` to batch multiple packets
  into single `NEPacketTunnelFlow.writePackets` system calls, significantly boosting network throughput.
- Session Lifecycle Log Level Adjustment (`TransparentProxyFlowSession`):
  downgraded normal flow closure and cancellation log entries to verbose, eliminating log spam.

### Verified

- Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`):
  verified cold start auto-reconnection on real hardware (1s disconnected -> 2s connecting -> 3s connected)
  and intentional disconnect retention with 100% pass rate.
- Product Test Suite (`test_product_build.sh`):
  all 104+ unit, integration, and performance boundary tests passed cleanly with zero regressions.

## [1.0.16] - 2026-09-18

### Added

- Launch at Login Management (`AppStartupController`):
  integrated native macOS `ServiceManagement.SMAppService.mainApp` to provide seamless,
  sandboxed launch-at-login capability with dynamic status observation and granular
  system permission guidance in Settings -> General.
- Persistent Connection Intent Store (`ConnectionIntentStore` in `AetherRouteKit`):
  introduced a dedicated thread-safe persistence layer capturing the user's explicit
  connection intent, cleanly decoupled from UI review mode and transient lifecycle states.
- Settings Interface & Localization:
  added "Launch at login" toggle, informational guidance, and permission requirement
  callouts in the General settings view with complete English and Simplified Chinese localizations.

### Changed

- Intelligent Connection State Memory & Auto-Recovery (`TunnelManager`):
  - Application Termination Protection: when the application terminates or the system
    shuts down, `disconnectForApplicationTermination()` safely disengages the Network Extension
    to prevent OS-level routing paralysis while preserving the user's intended connection
    state without falsely recording a manual disconnect.
  - Startup Auto-Reconnect: during the startup sequence, if the tunnel was actively connected
    prior to termination and network distribution permissions permit, AetherRoute automatically
    restores the proxy connection seamlessly; if disconnected prior to termination, it remains disconnected.
  - User Intent Tracking: accurately distinguishes between manual user disconnects and
    lifecycle cleanup disconnections, ensuring state memory strictly reflects user intent.

### Verified

- Multi-Environment Full Lifecycle Verification:
  - Tart Virtual Machine (`aether-diag-1434` / macOS 15.0 arm64): completed all 4 lifecycle
    scenarios (connect -> terminate-with-protection -> cold-start auto-connect -> manual disconnect
    -> cold-start remain-off) with 100% pass rate.
  - Physical Apple Silicon Mac mini (`chenxu@100.64.0.3`): verified end-to-end against production
    Network Extension profiles and system extension approval with 100% pass rate.

## [1.0.15] - 2026-09-17

### Added

- Single Main Window Lifecycle & Global Singleton Management (`AppWindowManager`):
  resolved duplicate main window instances between Dock icon clicks and status bar clicks;
  closing the main window now safely hides it (`orderOut`), while reopening from Dock,
  Launchpad, Spotlight, or Menu Bar smoothly summons the single existing window.
- Hide Dock Icon / Menu Bar Only Mode (`AppDockVisibilityController`):
  added user preference in Settings -> General allowing users to hide the Dock icon completely
  and run AetherRoute resident exclusively in the macOS Menu Bar, with instant single-window
  summoning on menu bar click or app icon launch.

### Changed

- Streamlined DNS & Fake-IP Architecture (`DNSView`):
  eliminated duplicate "Resolution behavior" and "TUN runtime overrides" cards into a single
  unified TUN policy card featuring integrated SF Symbols, profile default explanations, and
  profile-governed Hosts mapping display.
- Symmetric Dual-Column Layout for DNS Privacy & Safeguards:
  re-architected "Upstream privacy" and "Fake-IP safeguards" into a responsive side-by-side
  two-column layout, reducing vertical page height by over 30% and eliminating scrolling on standard displays.
- Refined Status Tag Appearance (`StatePill`):
  replaced push-button style border and control background with clean, lightweight semantic
  colored badges, completely avoiding user misinterpretation of read-only status tags as buttons.
- Proxy Group Speed Test Deduplication (`ProxiesPageView`):
  removed redundant top-level global test button in favor of group-scoped latency testing,
  making latency measurement intent and scope completely clear.

## [1.0.14] - 2026-09-17

### Added

- Native Segmented Proxy Group Bar (`ProxiesPageView`):
  redesigned the top strategy group picker into an Apple HIG-compliant segmented capsule
  switcher with smooth spring animation and clear active item highlight.
- Active Strategy Group Hero Banner (`ProxiesPageView`):
  added a dedicated identity card above the node grid explicitly detailing the active
  strategy group's name, semantic SF Symbol, routing mode badge (Select, URL-Test, Fallback),
  and manual switching status.
- Node Resolution & Diagnostic Registry:
  rebranded the raw providers and underlying node section into "节点解析与协议诊断（底库清单）",
  adding contextual guidance clarifying that this section is dedicated to inspecting
  underlying parser results, health status, and protocol parameters.
- Localized strings for all new proxy view components across English and Chinese
  (`Localizable.xcstrings`).

### Changed

- Sparkle Update Dialog Layout & Design System (`AppUpdateWindow`):
  completely redesigned update window styling following modern Apple HIG principles,
  featuring responsive light and dark mode cards, subtle translucent borders, and
  structured categorized release notes (New Features, Improvements, Bug Fixes).
- Decoupled Speedtest Scopes:
  separated top-level "全部测速" (Test All Groups) with explicit scope description from the
  per-group "测试延迟" (Test Group Latency) action, eliminating user ambiguity regarding
  button functionality and test boundaries.
- Automated Appcast Styling (`generate_sparkle_appcast.sh`):
  enhanced update release pipeline to automatically wrap release notes in modern responsive
  Apple-styled HTML templates before embedding into `appcast.xml`.

### Fixed

- Resolved layout shifting and unstyled raw markdown formatting in the Sparkle updater feed.
- Fixed syntax closure discrepancy in `ProxiesPageView`.

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
