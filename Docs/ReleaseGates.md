# Production release gates

Current product boundary: one independently distributed arm64 `AetherRoute`
app embedding both Transparent Proxy and Packet Tunnel. Local and remote
loopback/in-memory tests are regression evidence; they are not proof of a
signed real Network Extension or a notarized production release.

Evidence review date: 2026-09-05. The table is a dated development record;
measurements and earlier documentation observations span 2026-08-03 through
2026-09-05. A successful earlier revision does not approve a later candidate.
Retained local records are under `outputs/product-completion-20260905/evidence/`
and `outputs/soak-continuity-review/`. Final acceptance is determined by reports
bound to the final candidate's source manifest and artifact hashes. Later
results belong in those acceptance reports, without changing frozen source
merely to update this progress table.

| Gate | Required evidence | Reviewed state |
| --- | --- | --- |
| Product build | Clean arm64 host and both embedded extensions; warnings as errors; repeat on a second M-series Mac | September 5 native builds and Developer ID QA archive 2026090502 passed, including both extensions, packaged notices and source/network invariance. These predate later product changes. Final frozen-source and second-machine validation remain required. |
| Native regression | Import, configuration, security, routing, provider and bridge tests; TSan and ASan/UBSan | The September 5 full normal `test.sh` run at `8357019` passed in 809.942 seconds (13 minutes 30 seconds), with source unchanged and log SHA verified ([result][normal-result], [log][normal-log]). Earlier sanitizer and 36 focused resource/rollback checks are development evidence. Final frozen-source normal and sanitizer checks remain required. |
| Import and first connection | User-authorized subscription fetch and local import; no separate core or routing database setup | Core and validated DB-IP/GeoSite data ship inside the app. QA 2026090502 connected in Tart after the previous routing cache was moved aside; both installed database hashes match the bundle and their recorded origin is `bundled`. DNS returned to its baseline after disconnect. This proves local-profile first connection, not a newly fetched live subscription. |
| Protocols and lifecycle | Independent handshake, TCP/UDP, reconnect evidence for every catalog claim; bounded create/start/stop/destroy | Core `988decce` passed two rounds of 21 transport cases plus REALITY, WireGuard, ShadowQUIC and SSH on September 5. `Config/ProtocolCoreEvidence.json` binds the normal core archives and test binary. Both 500-cycle core checks pass. These isolated tests do not replace signed-provider acceptance. |
| TUN and local proxy | Exact running candidate; IPv4/IPv6, DNS, bypass, leak and fail-closed observations; loopback-only HTTP/SOCKS payloads | QA 2026090502 completed all three routing modes in Tart with candidate-bound IPv4 and HTTP/SOCKS probes. Each mode disconnected and restored routes and proxy settings; the final DNS snapshot also matches the baseline. Rule/global IPv6-target TLS probes fail; direct mode cannot establish native IPv6 coverage. Native IPv6 and leak behavior remain unverified. A listening port alone is never evidence of this candidate. |
| Transparent Proxy | Exact candidate; recursion prevention, TCP/UDP, DNS/routing and fail-closed observations | QA 2026090502 completed all three routing modes with exact-provider IPv4 probes and verified teardown. Rule/global IPv6-target TLS probes fail; direct mode cannot establish native IPv6 coverage. The six-mode matrix records four failed checks and is not a release pass. UDP, attribution, leak and recovery acceptance remain separate gates. |
| Diagnostics and privacy | Bounded AR1/ART1 schemas, secret redaction and real signed-provider retrieval | Schema/AR1 tests pass. The unusable debug-text export UI was removed because the app and TUN did not produce the files it advertised. Fixed lifecycle events remain available through OSLog. Real signed retrieval must still be verified. |
| UI and responsiveness | English/Chinese, light/dark, keyboard, minimum size, expanded text, Reduce Motion, Increased Contrast, accessibility and screenshots; 30-minute responsiveness record | September 5 targeted offscreen recovery, bilingual routing controls, live language changes, About and free-edition settings checks passed; the Hangs positive control detected an injected 710 ms stall. The proxy narrow-window change in `16fc4c0` passed its geometry assertions in a 780×592 window, but that same full-page audit still failed on Tokyo Direct contrast ([geometry log][proxy-log], [failed result][proxy-result]). The old large/xxxLarge parameter left native font dimensions unchanged ([text probe][text-probe]); prior expanded-text results cannot satisfy that requirement. The final 40-test suite, real text expansion and 30-minute measurement remain pending. Earlier screenshots are historical references. |
| Stability | Continuous 24-hour exact-source soak plus signed sleep/wake, path changes and crash recovery | September 5 corrected runner/verifier sources, later committed as `daee38b`, passed timing/cleanup regressions and a real 62-second normal-core smoke with two pairs, no new diagnostics or orphans, and zero recorded gaps. The production verifier rejects that short result ([soak review][soak-review]). No final-source 24-hour result exists; interrupted or earlier-source runs cannot be combined into release evidence. |
| Performance | Measured CPU/RSS, throughput/latency and UI budgets for the installed candidate | September 5 normal-source `8357019` recorded a Release 5,000-node import at 0.114223 seconds and 4,980,736 bytes of RSS growth, plus isolated core UDP/TCP checks ([normal log][normal-log]). These and earlier disconnected-idle figures are revision-bound development observations; signed-provider, calibrated installed performance and frozen UI measurements remain open. See `PerformanceAcceptance.md` for unchanged budgets. |
| Notices and metadata | Complete packaged notices bound to the actual cores and resource files; stable release metadata | The combined 438-component notice includes DB-IP CC-BY-4.0 and V2Fly MIT data. Source and QA built-bundle checks pass. Regenerate after every core variant change and verify the final release bundle. |
| Developer ID and installation | Exact signed app/DMG, hardened runtime, timestamps, notarization, staple, Gatekeeper; clean install, upgrade and rollback preserving profiles | Signing identities, provisioning and notary authentication were verified on September 5. QA 2026090502 is signed but not notarized or production-approved. Earlier candidate 2026081466 was Apple-accepted; that does not approve another build. A fresh `aether-product-fresh-20260905` restore from the verified official Apple IPSW was started on September 5; the old task clean clone is stopped with its disk preserved ([creation record][fresh-vm]). Setup Assistant, default SIP/Gatekeeper state and installation have not been verified by this review. It is not yet a verified clean test machine. |

The production scripts continue to require exact-source evidence: at least
three signed canary-transition cycles for each engine, plus a schema-2
24-hour soak with at least 800 complete Flow/Packet pairs, 1,000 Packet cycles
per pair, the production RSS/FD limits and no more than 1 MiB/hour post-warm-up
RSS growth. The corrected soak must accumulate at least 86,400 seconds of
measured round runtime, with no overlapping intervals and at most one second
between adjacent recorded intervals. Preparation, gaps and final source hashing
earn no runtime credit; the existing total-duration cap remains in force.
Canary availability must change from unavailable, to the exact
expected response through the proxy, and back to unavailable after disconnect.
A public connectivity probe cannot substitute for this attribution check.

`release.sh` produces a notarized candidate only after those prerequisites and
its normal/sanitizer checks. `promote_candidate.sh` separately requires the
exact installed DMG's runtime, leak, recovery, performance, UI and clean-machine
evidence. QA automation and diagnostic core builds cannot be promoted as the
production artifact. Test scripts must report missing evidence or environment
limitations explicitly, never convert them into successful product checks.

[normal-result]: ../outputs/product-completion-20260905/evidence/full-normal-tests-sidebar-final/result.json
[normal-log]: ../outputs/product-completion-20260905/evidence/full-normal-tests-sidebar-final/test.log
[soak-review]: ../outputs/soak-continuity-review/review-status.json
[proxy-log]: ../outputs/product-completion-20260905/evidence/ui-final/proxies-layout-original-1/xcodebuild-full.log
[proxy-result]: ../outputs/product-completion-20260905/evidence/ui-final/proxies-layout-original-1/result.json
[text-probe]: ../outputs/product-completion-20260905/evidence/ui-final/dynamic-type-platform-probe/result.json
[fresh-vm]: ../outputs/product-completion-20260905/evidence/fresh-vm-creation/result.json

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
