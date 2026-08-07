# AetherRoute

Created and maintained by **陈艳男 (ChenYanNan)**.

[Official website](https://aetherroute.baizhiedu.xin/) ·
[Releases and changelog](https://aetherroute.baizhiedu.xin/releases/) ·
[Support](https://aetherroute.baizhiedu.xin/support/)

> [!IMPORTANT]
> AetherRoute is pre-release software. The current source and unsigned UI
> previews are for development and validation; no build is a production
> release until the exact arm64 DMG passes Developer ID signing, Apple
> notarization, stapling, installed dual-engine tests, and the release gates
> documented in [`Docs/ReleaseGates.md`](Docs/ReleaseGates.md).

AetherRoute is a native Apple-silicon-only macOS proxy client. Its app,
menu-bar interface, configuration and security layers, and
Network Extension providers are written in Swift 6 with SwiftUI, AppKit, and
Apple's public APIs. It is a clean, native implementation of the user
experience expected from ClashX.

The project deliberately does not copy code from the archived AGPL ClashX
repository. Complex proxy protocols are implemented in a pinned, audited
Apache-2.0 ClashRS fork that is statically linked into the extension. Rust is
only the protocol data plane: it provides no UI, app lifecycle, settings,
privileged helper, separately shipped daemon, or downloaded executable code.

## Current milestone

- Native Swift 6 + SwiftUI menu-bar app shell
- One independently distributed native app embedding both the Transparent
  Proxy and Packet Tunnel/TUN Network Extensions
- Statically linked arm64 FlowOnly Rust protocol engine and bounded TCP/UDP
  flow bridge
- Shared configuration, routing-mode, and protocol-capability model
- AES-GCM encrypted App Group profile storage backed by the Data Protection
  Keychain, with safe YAML import validation and no plaintext fallback
- Cancellable, off-main-actor local profile import with an atomic encrypted
  commit. The Release gate imports and activates a 5,000-node fixture in about
  0.12 seconds with under 6 MiB peak RSS growth on the current M-series test Mac
- Numbered loopback UDP integrity gates for both FlowOnly and PacketFlow/TUN;
- Five-repetition TCP throughput and p95 latency gates for both current arm64
  core artifacts, with raw kernel-direct ratios retained as diagnostics;
  each current arm64 core transports 10,000 payloads after bounded warm-up with
  zero missing or duplicated payloads and without installing a Network Extension
- A native, typed node model and manual editor for all 12 release protocols.
  AetherRoute compiles these nodes into deterministic core profiles; Clash-style
  YAML and provider subscriptions remain bounded import adapters rather than the
  product's configuration contract
- AES-GCM encrypted multi-profile catalog with migration from the previous
  single-profile store, atomic active-profile mirroring, fast switching,
  rename/delete management, and automatic stale-mirror repair
- Password-protected cross-machine profile archives using PBKDF2-HMAC-SHA256
  and AES-256-GCM, with explicit import/export, deduplication, identifier
  conflict repair, and preservation of the active local profile
- HTTPS-only profile subscriptions with downgrade-resistant redirects,
  conditional ETag/Last-Modified refresh, bounded downloads, encrypted URL
  storage, atomic validation, and six-hour opt-in automatic checks. Provider
  bodies may be safe YAML or plain/Base64 share-link lists for the same 12
  typed protocols; all links must parse or the update is rejected atomically
- Native Proxies, Connections, Rules, privacy, settings, and searchable
  third-party license pages, with an original layered macOS Icon Composer mark
  and deterministic fallback assets for macOS 15+
- User-initiated batch node latency testing through the selected proxy group's
  real protocol handlers, with bounded requests/results and no background probe
- Privacy-scoped, versioned live telemetry shared by both providers, with
  upload/download speed, bounded active connections, rule hits, proxy chains,
  and a native dynamic menu-bar label
- User-initiated `AR1` diagnostic export capped at 64 KiB, backed by fixed
  lifecycle event codes, aggregate core state, and eight fixed provider error
  counters while excluding profile contents, URLs, credentials, traffic
  addresses, rules, proxy chains, and free-form provider errors
- Confirmed `aetherroute://subscribe?url=…` imports: bounded parsing accepts
  only one HTTPS target, hides query tokens, and performs no network request or
  activation before the user approves the native confirmation sheet
- Owner-operated independent licensing and update boundary with Ed25519-signed
  device-bound receipts and arm64 update manifests, non-synchronizing Data
  Protection Keychain storage, no persisted activation key, redirect/size
  rejection, a host-level connection gate for configured release builds, and
  an external private-key tool that signs the exact DMG SHA-256. User-chosen
  DMG downloads are SHA-256 verified before atomic save and are never executed
  automatically
- Deployable standard-library Go licensing/update service with HMAC-digested
  activation keys, atomic private state, a separate Unix-socket Ed25519 signer,
  loopback-only Web listener, administrative issue/revoke commands, static
  Linux arm64 output, Go race tests, and native Swift client interoperability
- AES-GCM encrypted bypass policy with at most 128 validated domain, IPv4
  CIDR, or IPv6 CIDR rules. Transparent Proxy applies domains and CIDRs through
  excluded network rules; Direct TUN applies only CIDRs through excluded
  routes, and the native UI states that domain rules remain inactive in TUN
- Explicitly opt-in native global shortcuts for connect/disconnect and
  Rule/Global/Direct selection, with conflict-safe assignments and no
  Accessibility permission requirement
- Explicitly opt-in, privacy-safe connection notifications plus an actionable
  recovery assistant for retrying or reviewing profiles after a failure
- Profile-bound Direct/TUN DNS runtime overrides for Normal, Fake-IP, or
  Redir-host resolution, IPv6 answers, and rule-aware upstream queries. The
  bounded C ABI changes only parsed core fields and never rewrites imported
  YAML or exposes resolver endpoints to the app UI
- Default-off TUN-only local HTTP and SOCKS5 proxy settings. Imported listener
  ports and LAN bindings are discarded; the core binds only `127.0.0.1` with
  `allow-lan=false`. The app offers copy-only terminal environment/clear
  commands and never changes the macOS system proxy
- Readiness-gated Transparent Proxy startup and synchronized fail-closed
  callback shutdown
- Native Swift Transparent Proxy support layer with bounded TCP/UDP adapters,
  weighted admission, self-egress identity policy, explicit half-close and
  callback-drain barriers
- Strong-linked native Swift FlowOnly bridge with per-flow serialized C calls,
  full token mapping, copied borrowed buffers, and flow/engine destroy barriers;
  the AetherRoute host embeds this provider while signed lifecycle gates remain
  pending
- 303 native Swift unit tests, warnings-as-errors arm64 builds, deterministic
  combined license notices, and isolated cross-machine gates

## Build

Clone the application and its pinned embedded core, then build both arm64 core
surfaces before generating the Xcode project:

```sh
git clone --recurse-submodules https://github.com/bcblr1993/AetherRoute.git
cd AetherRoute
git submodule update --init --recursive
./scripts/build_core.sh
./scripts/build_direct_core.sh
./scripts/bootstrap.sh
./scripts/test.sh
./scripts/test_sanitizers.sh
# Rebuild and test the exact staged snapshot on a different M-series Mac.
# fast = normal 303-test/product gate; full = fast plus TSan and ASan+UBSan.
AETHERROUTE_ALLOW_REMOTE_GATE=YES \
  ./scripts/test_remote_arm64.sh user@lan-mac fast
./scripts/test_core_lifecycle.sh
# Random-high-port, loopback-only HTTP CONNECT and SOCKS5 black-box gate.
./scripts/test_local_proxy.sh
# Explicit opt-in isolated durability run; 24 hours by default.
AETHERROUTE_ALLOW_ISOLATED_SOAK=YES \
  ./scripts/test_isolated_soak.sh /absolute/new/soak-output
# Fail closed on hashes, round completeness, totals, RSS, and wall-time budgets.
./scripts/verify_isolated_soak_result.sh /absolute/completed/soak-output
# Require a verified 24-hour result and <=1 MiB/hour post-warm-up RSS slope.
./scripts/verify_isolated_soak_trends.sh /absolute/completed/soak-output
# Final release additionally requires schema 2, production budgets, and exact
# current runner, harness, FlowOnly-core, and PacketFlow-core hashes.
./scripts/verify_release_soak_evidence.sh /absolute/completed/soak-output
./scripts/test_release_pipeline.sh
# Final disconnected-idle CPU/RSS gate. It fails closed until Developer Tools
# automation can finalize xctrace evidence and never starts Network Extension.
./scripts/test_disconnected_idle_performance.sh /absolute/new/idle-output
# Permission-limited diagnostic only; the verifier marks this provisional and
# never accepts it as the final xctrace release gate.
AETHERROUTE_IDLE_USE_SAMPLE=YES \
  ./scripts/test_disconnected_idle_performance.sh /absolute/new/idle-output
./scripts/test_update_envelope.sh
# Build and black-box-test the owner service without touching host networking.
./scripts/test_distribution_service.sh
# Capture the 30-case visual matrix from a disposable source/build/HOME copy;
# it binds every PNG, runtime log and the complete source manifest, and never
# launches AetherRoute from Documents or loads NetworkExtension.
./scripts/capture_ui_review.sh
# Semantic/button-state XCUITest isolates source, build, runner HOME and TMPDIR,
# preflights Automation Mode before starting a runner, and retries one transient
# startup timeout only when enabled. Never run these UI tests directly from the
# Documents checkout. The host must authorize Apple developer tools once; the
# script never clicks or approves system dialogs.
./scripts/test_ui.sh
# Compile every native node type and start both cores with all networking denied.
./scripts/test_manual_nodes.sh
# Validate user-supplied Clash profiles without changing system networking.
./scripts/test_external_profiles.sh /absolute/profile-a.yaml /absolute/profile-b.yaml
# Normalize a provider body, then start both cores with all networking denied.
./scripts/test_external_subscription_payload.sh /absolute/subscription-body
# Authorized live URL gate reads the credential from stdin, never argv.
printf '%s\n' "$SUBSCRIPTION_URL" | \
  AETHERROUTE_ALLOW_EXTERNAL_SUBSCRIPTION=YES \
  ./scripts/test_external_subscription_url.sh
./scripts/signing_preflight.sh
# Generate an external, mode-600 Xcode identity override after filling Signing.json.
./scripts/generate_signing_overrides.sh \
  /absolute/path/to/Signing.json \
  /absolute/path/to/AetherRouteSigning.xcconfig
# Real signed provider test; see Docs/SigningAndDistribution.md first.
# The gate requires an owner HTTPS canary that differs on direct vs proxied access.
AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY=/absolute/new/signed-ne-evidence \
./scripts/test_signed_network_extension.sh /absolute/path/to/Signing.json
# Verify both engines, privacy-safe evidence hashes, and the exact source tree.
./scripts/verify_signed_network_extension_evidence.sh \
  /absolute/signed-ne-evidence
```

Signing identity is centralized in parameterized Xcode settings. Development
builds retain an explicit `com.example` default, while a validated external
`Signing.json` produces a private `xcconfig` that injects the organization Team
ID, host and extension bundle IDs, App Group, Keychain suffix, profile archive
type, and URL registration without editing Swift or entitlements. The generator
refuses inconsistent extension IDs and never copies identity fingerprints or
profile paths into its output. `Docs/SigningAndDistribution.md` documents the
strict, read-only preflight used before any archive or signed Network Extension
test.

The About page reads its version, build number, release channel, and release
timestamp from the generated host `Info.plist`; UI text does not duplicate
those values. `AetherRouteReleaseChannel` accepts `development`, `beta`, or
`stable`, and a non-empty `AetherRouteReleaseTimestamp` must be UTC RFC 3339.
Stable builds are rejected when the timestamp is missing. Until a public date
is approved, the product intentionally displays Development / Not released.
The author credit is localized: Chinese shows 陈艳男 and other localizations
show ChenYanNan, while both canonical forms remain in build metadata.

## Supported-protocol target

The release gate covers HTTP, SOCKS5, Shadowsocks, VMess, VLESS + REALITY,
Trojan, Hysteria2, TUIC, AnyTLS, WireGuard, SSH, and ShadowQUIC. Independent
black-box interoperability now covers 21 protocol/transport cases through
pinned sing-box 1.13.15, including ShadowTLS v3 chained through the official
v0.2.25 server, plus Xray VLESS + REALITY + XTLS Vision, WireGuard through
pinned wireguard-go/gVisor, ShadowQUIC through pinned Mihomo, and OpenSSH
authentication using an encrypted inline Ed25519 private key and passphrase,
with strict host-key verification across an sshd restart. The
machine-checked `Config/ProtocolReleaseMatrix.json` has no uncovered catalog
claim. Protocol support remains at integration readiness until the signed
provider, sleep/wake, network-change, leak, and soak gates pass.

AetherRoute is distributed outside the Mac App Store as one notarized DMG. Its
host embeds both `NETransparentProxyProvider` and `NEPacketTunnelProvider`, so
the visible capture-mode selector can choose Transparent Proxy or TUN before a
session starts. The release pipeline requires exact current dual-engine Apple
Development runtime evidence, exact current schema-2 24-hour soak evidence, an
arm64 archive, Developer ID Application signatures, hardened runtime, secure
timestamps, notarization, stapling, Gatekeeper assessment, and a SHA-256
candidate manifest. This output is marked `notarized-candidate`; it is not a
production update manifest. Organization-signed
real TUN, DNS/routing, sleep/wake, leak, and soak evidence remains
release-blocking.
Only `scripts/promote_candidate.sh` can create the separate
`production-approved` manifest, after the exact DMG passes installed
Developer ID dual-engine, leak/recovery, performance, UI responsiveness, and
clean-machine evidence verification. Promotion does not upload the DMG or
change the owner's update service.

The reproducible loopback-listener interoperability runners are in
`Tests/Interop`, with the source-build matrix entry point at
`scripts/test_protocol_interop.sh`. Both matrix runners require the pinned
official ShadowTLS 0.2.25 server and verify that it only listens on loopback.
The ShadowTLS certificate camouflage handshake uses its configured public TLS
cover host, while all protocol payload peers remain on loopback. The runners
do not install a VPN or change system routes, DNS, or proxies and should run on
the designated test Mac.

The remote arm64 controller copies only the source, fixed core artifacts, and
checksum-pinned XcodeGen needed by the gate. It refuses localhost and the
current Mac, verifies the staged and remote manifests byte-for-byte, requires
8 GiB free for `fast` or 20 GiB for `full`, and deletes its exact remote
temporary directory by default. Both modes snapshot the macOS system-proxy,
DNS, default-route, and interface control state before and after testing and
fail if it changes.
No profile, subscription URL, signing identity, provisioning profile, or
Keychain material is transferred.

The native interaction, motion, accessibility, truthful-state, and visual QA
requirements are maintained in [`Docs/ProductDesign.md`](Docs/ProductDesign.md).
The owner-operated license and signed update wire contract is defined in
[`Docs/IndependentDistributionServices.md`](Docs/IndependentDistributionServices.md).
The production service topology and operations are documented in
[`Docs/DistributionServiceDeployment.md`](Docs/DistributionServiceDeployment.md).
Versioning, tagging, release notes, and artifact promotion are defined in
[`Docs/ReleaseProcess.md`](Docs/ReleaseProcess.md).

## Repository licensing

No project-wide open-source license has been selected for the AetherRoute app.
The embedded core is maintained separately under Apache-2.0, and every bundled
third-party component retains its own license and notice. See
`Config/Licenses/ThirdPartyLicenses.json` for the deterministic product notice.
