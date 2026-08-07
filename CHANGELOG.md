# Changelog

All notable changes to AetherRoute are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Production signing, notarization, installed Network Extension validation,
  and the final 24-hour stability gate remain release-blocking.
- The support site now gives the exact macOS 15 Network Extension approval
  path and explicitly states that Reduced Security and disabling SIP are not
  required.

### Fixed

- Isolated UI cleanup probes no longer register empty test-only `.app`
  fixtures with LaunchServices. Real signed UI products keep their exact paths
  during a compact bounded quiet period, preventing misleading
  `AetherRouteUITests-Runner.app` damaged-application alerts without retaining
  full DerivedData.

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
