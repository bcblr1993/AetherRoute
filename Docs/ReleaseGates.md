# Production release gates

Current product boundary: one independently distributed arm64 `AetherRoute`
app embedding both Transparent Proxy and Packet Tunnel. Local and remote
loopback/in-memory tests are regression evidence; they are not proof of a
signed real Network Extension or a notarized production release.

Evidence review date: 2026-09-05. Results below identify their scope;
a successful earlier revision does not approve a later candidate. Retained
local records are under `outputs/product-completion-20260905/evidence/`.
The corresponding source revisions and artifact hashes belong with every
published acceptance report.

| Gate | Required evidence | Reviewed state |
| --- | --- | --- |
| Product build | Clean arm64 host and both embedded extensions; warnings as errors; repeat on a second M-series Mac | Current native builds and Developer ID QA archive 2026090502 pass, including both extensions, packaged notices and source/network invariance. Final frozen-source and second-machine validation remain required. |
| Native regression | Import, configuration, security, routing, provider and bridge tests; TSan and ASan/UBSan | Normal native suites and all three sanitizer bundles passed earlier in this repair. Resource validation, concurrent reads and rollback under injected disk/write failures now pass 36 focused tests. Final normal-core/source and sanitizer reruns remain required. |
| Import and first connection | User-authorized subscription fetch and local import; no separate core or routing database setup | Core and validated DB-IP/GeoSite data ship inside the app. QA 2026090502 connected in Tart after the previous routing cache was moved aside; both installed database hashes match the bundle and their recorded origin is `bundled`. DNS returned to its baseline after disconnect. This proves local-profile first connection, not a newly fetched live subscription. |
| Protocols and lifecycle | Independent handshake, TCP/UDP, reconnect evidence for every catalog claim; bounded create/start/stop/destroy | Core `988decce` passed two rounds of 21 transport cases plus REALITY, WireGuard, ShadowQUIC and SSH on September 5. `Config/ProtocolCoreEvidence.json` binds the normal core archives and test binary. Both 500-cycle core checks pass. These isolated tests do not replace signed-provider acceptance. |
| TUN and local proxy | Exact running candidate; IPv4/IPv6, DNS, bypass, leak and fail-closed observations; loopback-only HTTP/SOCKS payloads | QA 2026090502 completed all three routing modes in Tart with candidate-bound IPv4 and HTTP/SOCKS probes. Each mode disconnected and restored routes and proxy settings; the final DNS snapshot also matches the baseline. Rule/global IPv6-target TLS probes fail; direct mode cannot establish native IPv6 coverage. Native IPv6 and leak behavior remain unverified. A listening port alone is never evidence of this candidate. |
| Transparent Proxy | Exact candidate; recursion prevention, TCP/UDP, DNS/routing and fail-closed observations | QA 2026090502 completed all three routing modes with exact-provider IPv4 probes and verified teardown. Rule/global IPv6-target TLS probes fail; direct mode cannot establish native IPv6 coverage. The six-mode matrix records four failed checks and is not a release pass. UDP, attribution, leak and recovery acceptance remain separate gates. |
| Diagnostics and privacy | Bounded AR1/ART1 schemas, secret redaction and real signed-provider retrieval | Schema/AR1 tests pass. The unusable debug-text export UI was removed because the app and TUN did not produce the files it advertised. Fixed lifecycle events remain available through OSLog. Real signed retrieval must still be verified. |
| UI and responsiveness | English/Chinese, light/dark, keyboard, minimum size, expanded text, Reduce Motion, Increased Contrast, accessibility and screenshots; 30-minute responsiveness record | Offscreen-window recovery, bilingual routing-rule expansion/collapse, live language changes, About accessibility and free-edition settings pass targeted checks. An Instruments positive control detects an injected 710 ms main-thread hang. The complete current UI suite and real 30-minute measurement remain pending. Earlier screenshots are historical references. |
| Stability | Continuous 24-hour exact-source soak plus signed sleep/wake, path changes and crash recovery | Current short core checks pass. No complete current-source 24-hour result exists. Interrupted or earlier-source runs cannot be combined or reused as current release evidence. |
| Performance | Measured CPU/RSS, throughput/latency and UI budgets for the installed candidate | Current isolated lifecycle memory checks pass. Previously recorded loopback throughput and disconnected-idle measurements are revision-bound references; signed-provider and frozen UI performance remain open. |
| Notices and metadata | Complete packaged notices bound to the actual cores and resource files; stable release metadata | The combined 438-component notice includes DB-IP CC-BY-4.0 and V2Fly MIT data. Source and QA built-bundle checks pass. Regenerate after every core variant change and verify the final release bundle. |
| Developer ID and installation | Exact signed app/DMG, hardened runtime, timestamps, notarization, staple, Gatekeeper; clean install, upgrade and rollback preserving profiles | Signing identities, provisioning and notary authentication were verified. QA 2026090502 is signed and is not notarized or production-approved. Earlier candidate 2026081466 was Apple-accepted; that does not approve the current build. The clean Tart VM still needs local login unlock before its security and install checks can run. |

The production scripts continue to require exact-source evidence: at least
three signed canary-transition cycles for each engine, plus a schema-2
24-hour soak with at least 800 complete Flow/Packet pairs, 1,000 Packet cycles
per pair, the production RSS/FD limits and no more than 1 MiB/hour post-warm-up
RSS growth. Canary availability must change from unavailable, to the exact
expected response through the proxy, and back to unavailable after disconnect.
A public connectivity probe cannot substitute for this attribution check.

`release.sh` produces a notarized candidate only after those prerequisites and
its normal/sanitizer checks. `promote_candidate.sh` separately requires the
exact installed DMG's runtime, leak, recovery, performance, UI and clean-machine
evidence. QA automation and diagnostic core builds cannot be promoted as the
production artifact. Test scripts must report missing evidence or environment
limitations explicitly, never convert them into successful product checks.

## Free first-edition release

The first public edition explicitly uses `free` distribution. Users supply
proxy profiles; no account, paid activation service, or update signing key is
required. The signed metadata and candidate manifest record the distribution
mode, and free builds reject mixed licensing/update configuration. Manual
signed-DMG updates preserve existing profiles. This changes only the service
requirement: signed runtime, exact-source soak, UI, installation, notarization,
and production-promotion evidence remain required. The table is a dated
progress record, not approval of the current candidate.

## External inputs that must never be committed

- Apple Developer Team ID, final bundle identifiers, App Group, and Keychain
  access group
- Developer ID Application certificate installed in the signing Keychain
- matching host, Transparent Proxy, and Packet Tunnel provisioning profiles
- a locally stored `notarytool` Keychain profile
- final version/build/release time, copyright holder, support/privacy URLs
- for optional licensed builds: licensing and update service base URL, API
  contract, product identifier, and public verification key

Do not send private keys, certificate export passwords, Apple ID passwords,
two-factor codes, or notary credentials through chat. Configure them directly
on the designated signing machine.
