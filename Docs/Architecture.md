# AetherRoute architecture

## Product and release boundary

AetherRoute is one Apple-silicon-only macOS application distributed outside
the Mac App Store. The host, menu bar, windows, configuration/security layer,
and both Network Extension providers are written in Swift 6 with SwiftUI,
AppKit, and public Apple frameworks. The arm64 Rust cores are statically linked
protocol data planes behind narrow C ABIs; they do not own UI, app lifecycle,
NetworkExtension privileges, system routes, executable downloads, or a
separately shipped daemon.

The single host embeds both capture engines:

- `NETransparentProxyProvider` adapts Apple TCP/UDP flows directly into the
  bounded FlowOnly dispatcher.
- `NEPacketTunnelProvider` applies IPv4/IPv6 settings with public
  NetworkExtension APIs and copies bounded packets between
  `NEPacketTunnelFlow` and the userspace PacketFlow core.

The user chooses the engine before connecting. The selector is locked during a
session, and visible state comes from the provider rather than the toggle's
intent. There is no private `utun` lookup, KVC access, root helper, route
subprocess, local listener inserted between Transparent Proxy and the core, or
automatic activation after importing a profile.

## Transparent Proxy path

The FlowOnly engine starts only the resolver, router, outbound manager,
dispatcher, and statistics components. It starts no TUN, DNS/API/proxy
listener, and performs no implicit provider download or bootstrap network I/O.
Remote profiles and rule providers are fetched and validated by the host before
startup, then supplied as immutable local data.

TCP and UDP adapters enforce weighted admission, bounded single-read and
single-write backpressure, per-flow serialization, copied borrowed buffers,
stable tokens, explicit half-close behavior, and destroy barriers. Provider
egress bypass requires validated source audit-token and signing identity; a
bundle-ID string or proxy-node address is not sufficient.

## Packet Tunnel/TUN path

The host stores a validated profile and asks `NETunnelProviderManager` to start
the embedded Packet Tunnel. The extension applies
`NEPacketTunnelNetworkSettings`, reads bounded IP packets, dispatches TCP/UDP
through the selected outbound, and writes return packets through the same
`NEPacketTunnelFlow` bridge. Its queue is capped at 4,096 packets and rejects
invalid or oversized input.

Profile-bound DNS runtime overrides support Normal, Fake-IP, and Redir-host
modes, IPv6 answers, and rule-aware upstream selection without rewriting the
imported YAML or exposing resolver endpoints in app telemetry. TUN bypass
applies CIDRs as excluded routes; domain bypass remains a Transparent Proxy
capability unless signed DNS-aware runtime evidence proves otherwise.

An optional local proxy is a host-controlled TUN feature, disabled by default.
The Packet Tunnel receives only a versioned fixed-width enabled/HTTP-port/
SOCKS-port value. After parsing a profile, the Rust boundary discards all
profile-supplied listeners, `allow-lan`, and bind addresses, then creates
exactly two listeners on `127.0.0.1` with `allow-lan=false`. Transparent Proxy
never starts a local listener. The UI can copy terminal-scoped environment and
clear commands, but does not read or change the macOS system proxy.

## Trust boundaries

- All upstream sources and Git dependencies are pinned to immutable revisions.
- Imported profiles are data only; commands, scripts, executable plugins, and
  post-install behavior are rejected.
- Profile storage, subscriptions, and cross-machine archives use bounded,
  authenticated encryption paths with no plaintext fallback.
- GPL test servers are independent loopback-only processes and are never linked
  into or shipped with AetherRoute. The release artifact rejects forbidden
  copyleft runtime license expressions.
- Process-name and process-path rules fail closed where NetworkExtension cannot
  provide trustworthy process identity. Domain, address, port, network,
  GeoIP/GeoSite, rule-set, and match rules remain supported.
- Telemetry and diagnostic messages are versioned and bounded; they exclude
  credentials, endpoints, source/destination addresses, profile text, and
  free-form provider errors.

## Verification topology

- Local gates compile arm64 with warnings as errors, run Swift/Rust tests,
  validate metadata/licenses, and exercise only loopback or in-memory data
  paths. They do not start a VPN or change routes, DNS, or system proxies.
- The local-proxy black-box gate uses random high loopback ports, verifies that
  imported HTTP/SOCKS/mixed listeners remain closed, and performs real HTTP
  CONNECT and SOCKS5 echo round trips through the host-controlled listeners.
- Lifecycle gates perform 500 PacketFlow cycles under a 32 MiB RSS budget and
  500 FlowOnly engine/flow cycles with callback and destruction checks. Both
  harnesses sample open file descriptors after warm-up and fail when retained
  descriptors exceed the bounded allowance.
- External subscription fixtures pass through the same safe-YAML or
  plain/Base64 share-link normalizer as the app, emit only aggregate protocol
  counts, and then start both cores inside a network-denied sandbox. Endpoint
  names, addresses, URLs, and credentials are never written to gate output.
- `scripts/test_isolated_soak.sh` compiles both embedded-core harnesses once,
  repeats those bounded lifecycle batches for up to 26 hours, watches every
  child with a hard timeout, enforces per-engine RSS budgets, prevents idle
  sleep only for the test lifetime, keeps constant-size latest logs, and writes
  a hashed round summary. `scripts/verify_isolated_soak_result.sh` separately
  rejects hash mismatches, missing/duplicate engine rows, inconsistent totals
  or peaks, and per-round RSS/wall-time regressions. Schema 2 also records and
  verifies per-round file-descriptor growth while retaining schema-1 support
  for an already-running evidence set. A separate trend verifier first repeats
  the complete evidence verification, requires 24 hours by default, discards
  the first five percent as warm-up, and rejects a positive least-squares RSS
  slope above 1 MiB/hour for either engine. Schema-2 release evidence also
  compares exact-process diagnostic-report basenames before and after the run
  and rejects any remaining process matching either temporary harness path.
  The runner uses only
  loopback/in-memory traffic and never loads NetworkExtension or changes system
  networking. This is an isolated durability gate, not evidence for a signed
  provider or real-network soak.
- Debug-only UI review renders the real SwiftUI hierarchy while bypassing
  NetworkExtension preferences; Release contains no simulated-state branch.
- The designated LAN M-series Mac repeats clean builds, test suites, lifecycle
  checks, and source-manifest comparison without installing a provider.
- Real TUN/Transparent Proxy, sleep/wake, physical network changes, leak tests,
  crash recovery, and long soak run only after organization signing inputs are
  present and only on the designated test Mac.
- Release requires one arm64 Developer ID archive and DMG, hardened runtime,
  secure timestamps, Apple notarization, stapling, Gatekeeper assessment, exact
  packaged license/metadata verification, and a SHA-256 release manifest.
