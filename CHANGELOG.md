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
