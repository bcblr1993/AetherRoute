# Release-readiness audit — 2026-08-02

## Frozen candidate source

- Source manifest SHA-256: `98c3a371ff31a80b6120fe3004c5a18469d57fe5e7e28a67b90c9a4ca1601bd5`
- Unsigned preview: `outputs/AetherRoute-UI-Preview-v5-20260802`
- Distribution boundary: independent Developer ID DMG, not Mac App Store
- Architecture: Apple Silicon arm64 only

## Proven for the frozen source

- Complete normal regression, temporary-root install/upgrade/rollback, and
  source/network isolation guards pass.
- Twelve protocol families pass both FlowOnly and Packet/TUN startup surfaces;
  48 input variants pass 96 core surfaces with external networking denied.
- Pinned interoperability and independent REALITY, WireGuard, ShadowQUIC, and
  OpenSSH gates pass on loopback-only peers.
- 5,000-node import, cancellation, UDP integrity, TCP throughput/latency, core
  lifecycle, file-descriptor, and RSS budgets pass.
- The complete 38-test remote UI suite passes with zero failures; independent
  v5 manual review reports no P0, P1, or P2 finding across all primary and
  Settings pages, both languages, author/date metadata, window sizes, and the
  twelve-protocol node editor.
- Final 300-second warm-up plus 600-second Instruments `xctrace` sampling in
  window-open and menu-bar-only states passes CPU/RSS limits, observes no app
  network socket, and preserves proxy/DNS/default-route/interface state.
- The v5 DMG is arm64, ad-hoc signed, checksum-bound, mounts read-only, and
  deliberately contains no usable Network Extension entitlement.

## Running gate

- A schema-2 24-hour isolated dual-core soak started on the designated M-series
  test Mac at `2026-08-02T10:05:42Z`.
- It uses the exact current runner, harnesses, and both embedded-core hashes;
  PacketFlow runs 1,000 lifecycle cycles per round and FlowOnly uses the
  three-datagram UDP probe.
- Completion requires at least 86,400 seconds, at least 800 paired rounds,
  bounded RSS slope and FD growth, no exact-core diagnostic report, no orphan
  process, unchanged network-control state, and both repository verifiers.

## External-input gates not yet proven

- Production bundle identifiers, Team ID, App Group, and Keychain access group
  still use placeholders.
- The signing host currently has zero valid code-signing identities and zero
  matching provisioning profiles.
- A Developer ID Application identity, host/Packet Tunnel/Transparent Proxy
  Developer ID profiles, and a local `notarytool` Keychain profile are absent.
- Exact signed TUN and Transparent Proxy canary cycles, IPv4/IPv6/DNS leak
  checks, recursion prevention, sleep/wake, path-change, crash recovery,
  connected performance, and clean-machine installed-DMG validation therefore
  remain open.
- Notarization, stapling, Gatekeeper assessment, notarized-candidate manifest,
  and production promotion cannot be claimed until those inputs and runtime
  results exist.

The goal remains active. An unsigned preview or passing loopback test is not a
production release substitute.
