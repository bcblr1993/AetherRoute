# macOS UI improvement acceptance plan

Scope: macOS application, settings, menu bar, and all editing sheets. Release is deferred until maintainer testing. Existing unrelated working-tree changes must remain outside the UI commit.

Execution boundary (latest maintainer instruction): source edits and signed builds may execute on the host; application interaction, UI screenshots and runtime acceptance execute on the physical Mac at `chenxu@192.168.50.226`. Earlier core regression executed in the isolated Tart clone `aether-ui-qa-20260926`, created after an external reboot interrupted the original VM. No signing private key is transferred. Release remains deferred until maintainer acceptance.

## Acceptance checklist

- [ ] Capture current isolated UI baseline, including languages, appearances, compact layouts and lifecycle states.
- [ ] Separate connection lifecycle from route-quality checks across overview, sidebar and menu bar.
- [ ] Correct routing-mode labels and explain when changes take effect.
- [ ] Explain custom, imported, bypass and optimization rule scope using verified engine behavior.
- [ ] Overview: consolidate state, active configuration/outlet, controls and telemetry.
- [ ] Proxies: distinguish endpoint/group/special outlet, testing scope and stale results.
- [ ] Connections: search, pause refresh, inspect/copy complete destination and stable tracking.
- [ ] Profiles: search, compact active summary, update feedback and distinguish duplicate names.
- [ ] Rules: compact tools, source/priority information and simulator limitations.
- [ ] DNS: source/override summary, advanced disclosure, reset and application timing.
- [ ] Settings: separate general/network/automation and label distribution appropriately.
- [ ] Menu bar: concise main controls and bounded searchable node selection.
- [ ] Sheets: consistent save/cancel, validation, pending changes and error recovery.
- [ ] Adaptation: compact window, long names, English, dark appearance, expanded text, keyboard and accessibility.
- [ ] Run required regression, product build, isolated UI review and network matrix within the authorized build/test boundary; record actual results and clean test artifacts.
- [ ] Inspect scoped diff and commit completed UI changes for maintainer testing; no version/tag/release publication.

## Baseline notes

Current source already contains adaptive connection filters, table layout, progress buttons and accessibility identifiers. Preserve these behaviors. Website screenshots show an older version and are insufficient evidence for current visual acceptance.

Confirmed semantic issues: settings' “Default routing mode” changes the live routing mode; connected lifecycle is presented as “Protected” in multiple surfaces; distribution settings are named “Account” although the free edition has no account flow.

The initial working tree contains changes in AetherRouteApp.swift, SparkleUpdaterController.swift, DomesticRoutingOptimizer.swift, ProfileKeyStore.swift and monitor_aetherroute_daemon.py. A pre-change patch is retained locally under outputs/ui-audit-work for scoped staging checks.

## VM verification progress

The final acceptance checklist remains open until the complete final-source run, UI interaction and screenshot review succeed.

Completed inside `aether-diag-1434`:
- Network switch regression: 3 tests passed.
- Engine reconnect: stop-before-start, cancellation, rollback and timeout regressions passed.
- Runtime environment: display continuity and sleep/wake passed.
- Latest localization snapshot: 1105 bilingual catalog entries passed.
- Design-token guard harness and actual source verification passed after replacing two diagnostic-row spacing literals with the existing 2-point token.
- Latest product build passed with Swift warnings treated as errors; 450 unit tests passed with zero failures.
- UI target compilation passed. This is compilation evidence only; the UI runner has not executed on this final source.
- Host/guest hashes matched for 562 source, test, script and documentation files at the verified snapshot. Subsequent documentation updates require a final resynchronization.

Full regression: the first attempt failed because the shared Python executable path contained spaces in generated shebangs. A local guest Python executable fixed that environment issue. The second attempt was interrupted by an external VM reboot. The complete `./scripts/test.sh` run in `aether-ui-qa-20260926` finished with exit code 0. Its final build and 450 unit tests passed, along with local proxy checks, 12 manual-node protocols on 24 core surfaces and 49 protocol-input cases on 98 core surfaces. Neither earlier interrupted attempt counts as a complete pass. The regression and DMG-upgrade temporary workspaces were verified absent after completion. Existing Xcode AppIntents metadata extraction warnings remain; there were no Swift compiler errors.

Remaining gates: trusted UI runner execution, final 44-case screenshot review, signed candidate installation and actual network matrix acceptance, final scoped diff review and commit. Regression harness results do not prove these runtime gates.

Environment: macOS 27, Xcode 27.0 (27A266a), Swift 6.4, Rust 1.96. Test workspaces live under `/Users/chenxu/AetherRouteUIQA-20260926` in the guest, because macOS reboot removes temporary source trees.

## Physical Mac verification progress

The maintainer authorized local signed builds and remote execution after neither the Tart guests nor the physical Mac had a valid development signing identity. The local Apple Development signed XCTest products run remotely with an isolated test home. No private key was exported.

A separate notarized candidate was installed at `/Applications/AetherRoute-QA-20260926.app`; archive hashes, code signature, stapled notarization ticket and the remote distribution policy check passed. This candidate predates subsequent UI fixes and must be rebuilt before final delivery.

Remote UI execution is confirmed: About, subscription, connection search/pause/details and multiple settings workflows passed. The complete remote regression executed 44 tests: 2 were skipped and 24 failed. Failures include Chinese settings sidebar contrast, the sidebar version label and outdated assumptions about visible page content. This is a completed diagnostic run, not acceptance. Test navigation was updated to bind the semantic main window across Xcode versions, to use the new Rules heading and to scroll lazy content into view. Privacy roundtrip now opens its disclosure before checking the details. These changes have compiled locally and await remote retesting.

The 44-case window screenshot matrix has been prepared as an opt-in XCTest method, allowing capture through the trusted runner without granting SSH screen recording access. Capture and visual review remain pending. No full UI acceptance or final-source package acceptance is claimed yet.

The finalized result bundle and exported attachments were collected. A Chinese About screenshot confirms the selected settings row showed black text on blue; the row now explicitly uses the system selected text color, and unselected rows use the system label color. The version label is now 12pt semibold. A focused remote language-switch and Connections accessibility rerun is in progress. Configuration row hierarchy confirmed parent identifiers were inherited by child buttons and menus; rows now contain their accessible children explicitly. Additional test corrections target the visible profile radio control, native routing segment identifier, updated subscription metadata and scrolled advanced editor content. These changes still require final runtime verification.


### Consolidated remote retest evidence

Subsequent focused runs passed Connections accessibility in both appearances, active-profile protections and inactive-profile editing, profile activation/rename/removal, Chinese proxy latency measurement, subscription controls, REALITY creation, stable-state routing/profile/node changes, and explicit Settings sidebar selection. The manual editor advanced disclosure was replaced with an explicit native button after runtime evidence showed the nested Form disclosure did not expand. Cancel confirmation tests now resolve actions within the main window to avoid duplicate Touch Bar actions.

Settings selected-row contrast is corrected; the remaining unselected-row contrast report is under verification with 14pt bold system text and decorative icons hidden from accessibility. The latest signed batch built successfully and was transferred to the physical Mac. Seven focused workflows are running together in `Evidence/batch-final-focused-20260927.xcresult`: language switching and roundtrip, manual editor/cancel, privacy consent, Rules and DNS accessibility, and primary navigation. This batch is not yet a passing gate. Full regression, screenshot matrix and final package/network acceptance remain pending.

### Final scoped unit regression

The prepared UI submission snapshot built successfully with the production bundle identifier and ran on the physical Mac: 346 AetherRouteKit tests, 84 transparent-proxy support tests and 20 flow bridge tests passed, plus 86 Swift Testing cases (16 suites), total 536 with zero failures. The exported xcresult summary independently reports 536 passed, zero failed or skipped. Matching Xcode27 Swift Testing framework and companion overlays were supplied inside the disposable test products to resolve the remote Xcode26.5 runtime mismatch. The terminal controller returned exit 0 and `TEST EXECUTE SUCCEEDED`; result `Evidence/unit-scoped-production-20260927.xcresult`. Earlier failed runtime/configuration attempts are excluded. Full UI regression and package/network acceptance remain pending.

Final-source additional regressions executed on the physical Mac: network-switch gate 3 tests passed; engine reconnect stop-before-start/cancellation/rollback/timeout passed; runtime environment display continuity and sleep/wake harness passed. Native harnesses were compiled locally with Swift warnings as errors, signed, transferred, and executed remotely. The initial runtime harness library-path failure was corrected and its terminal rerun returned exit 0. These harnesses do not replace the actual six-mode network matrix.

### Current final UI verification

The scoped submission snapshot passed a local build and 536 physical-machine unit tests. A full physical UI regression is still running. Completed language, subscription, automation, bypass, keyboard navigation, profile protection, connection detail and light/dark Connections accessibility workflows pass. The run identified DNS state-pill contrast, Overview configuration-name contrast, and an exposed decorative proxy-group symbol plus strategy-label contrast during expanded-text review. These findings are being corrected and verified in focused physical runs; the running older snapshot is diagnostic evidence, not a final passing gate.

A scoped notarized normal-core candidate completed both app and DMG notarization (app `cd2004a4-f43c-44df-aebc-952118aadba9`, DMG `ba086ddf-2a2c-48c5-94ed-3da70898ea7a`). It predates the most recent contrast corrections and must not be presented as the final delivered UI candidate.

The remote network preflight found an existing connected production app and no unattended sudo permission. The original VM matrix script overwrites `/Applications/AetherRoute.app` and uses privileged observation, so it cannot be executed unchanged on the physical machine. Actual six-mode acceptance remains open while a bounded execution route is prepared. Existing production app and connection are preserved.

### Completed full scoped UI diagnostic run

The full scoped physical-machine UI run completed 45 tests in 1985.6 seconds: 32 passed, 10 failed, and 3 explicit opt-in gates skipped. The collected xcresult independently confirms these counts. The skipped gates are release responsiveness, screenshot matrix and real Network Extension lifecycle; separate screenshot execution is now active. This full run is not an acceptance pass.

The ten failed cases cover DNS contrast; Chinese and English expanded text; Overview contrast; profile library actions; profile-search app foreground activation; Profiles accessibility; Proxies accessibility; Rules menu selection; and the minimum Chinese window. Subsequent source corrections include explicit system text colors, hidden decorative group icons, named-row profile menu targeting, explicit profile-search accessibility text, and dynamic Rules filter accessibility names. Focused reruns retain real interaction assertions and audit requirements. In the Profiles audit, every named native menu must actually open and expose Rename before the scoped Xcode26 native Menu metadata exception is applied.

The next notarized candidate completed app submission `a67afd3f-57f3-4616-8d57-d697937aa346` and DMG submission `1c148807-18e6-492f-b827-d2a545f2e64b`. The later DNS detail, telemetry refresh label and group-header fixes are not included in this artifact. It remains intermediate build evidence until the latest corrected source is packaged and verified.

Disk cleanup during verification removes only completed, unreferenced owned outputs. Four queued product copies were consolidated onto their verified shared snapshot, reclaiming approximately 776 MiB. Required result bundles remain available for audit.

### Latest visual and focused audit

The 44-case screenshot matrix completed successfully and all six contact sheets were inspected. The images cover both languages, both appearances, expanded text, minimum windows, settings and privacy. They revealed an English sidebar Settings label wrapping inside the footer; its text now keeps a single intrinsic-width line. These screenshots predate subsequent contrast corrections, so a fresh matrix is queued and the final visual gate remains open.

Named-row profile activation, rename and removal passed on the physical machine. Profile search passed. The subsequent Profiles accessibility run still reported metadata contrast, and Proxies reported low contrast in strategy explanations and raw-inventory details. Those text styles were corrected and a signed build completed. Eight focused checks and a fresh 44-case matrix are queued behind the already-running physical test process. DNS state-pill contrast remained insufficient in the preceding snapshot; explicit black/white text by appearance is now being built and requires its own final verification.

The network QA archive transferred intact to the physical machine: local and remote SHA256 both `63cd7cdf5927ed138589d9e07812e46660f63edc05385760bb234cc4278e5a88`. The extracted candidate passed deep strict signature verification. Network transaction helpers passed shell syntax checks and were transferred; actual six-mode execution has not started. This archive predates the latest purely visual corrections and is network-test evidence only, not the final maintainer UI deliverable.

### Focused eight-case outcome and subsequent corrections

`Evidence/final-rule-count-focused-20260927.xcresult` completed eight tests: three passed (Profiles accessibility, Proxies accessibility, minimum Chinese window) and five failed (DNS, both expanded-text cases, Overview, Rules). The collected xcresult summary confirms 3/5/0 pass/fail/skip. The superseded screenshot matrix was explicitly interrupted and is not counted as a pass; the prior complete 44-case capture remains historical visual evidence.

Follow-up corrections use a separate accessible text element for state pills, hide decorative rule-kind symbols, display localized custom-rule counts with a noun, and use 12pt medium text for Overview refresh timing and DNS policy descriptions. The latest six-case physical run is active. DNS no longer reports Customized but still reports its AAAA explanatory text; the latter correction has built successfully and transferred separately for targeted verification. No final UI acceptance is claimed.

### Accepted focused pages and network candidate preparation

The collected six-case readable-captions run reports four passed and two failed, zero skipped: English expanded text, Overview accessibility, Rules accessibility and minimum Chinese window passed. The remaining failures concern DNS explanatory text, corrected in the subsequent DNSDetail products. Its physical DNS light/dark audit passed in 53.0 seconds; Chinese and English expanded-text checks and final screenshot capture are still running, so complete UI acceptance remains open.

The internal network QA archive was accepted by notarization submission `ee7a4e66-324e-47a3-bcce-98ee4807dec4`. A transient VPN path failure interrupted the wait, but querying that same submission confirmed Accepted. On the physical machine, stapling, ticket validation and execution policy assessment passed with `source=Notarized Developer ID`. The candidate is installed independently at `/Applications/AetherRoute-QA-20260926.app`; its previous QA installation is retained in the owned evidence workspace. The production installation remains untouched and connected. Actual six-mode network acceptance has not yet run.

### Final expanded-text regression collected

The completed physical DNSDetail focused result was copied back and inspected with `xcresulttool get test-results summary`: Passed, three tests passed, zero failed and zero skipped. This covers DNS accessibility in both appearances and expanded text across Chinese and English primary pages. Evidence: `outputs/ui-audit-work/dns-detail-focused-20260927.xcresult` and `dns-detail-focused-summary.json`. The final 44-case screenshot matrix started afterward with the same products; visual acceptance remains pending its completion and image review.

### Final maintainer candidate

The normal-core candidate completed signing, app and DMG notarization, stapling, bundle resource/security checks and license verification. Artifact: `outputs/ui-maintainer-final-20260927/AetherRoute-1.0.29-build-2026092601-arm64-Notarized-Test-Normal-Core.dmg`. App submission: `0a8c0b03-f935-4c18-a221-673b25e98244`; DMG submission: `cc3f5596-9125-4559-a869-6ea0a2fd6402`. All four SHA256SUMS entries passed locally and after transfer to the physical machine. Remote stapler validation and Gatekeeper assessment passed with `source=Notarized Developer ID`; evidence is `outputs/ui-audit-work/maintainer-final-remote-dmg-policy.log`. The 22 staged code paths match the build snapshot byte for byte, recorded in `maintainer-final-staged-binding.json`. This is a maintainer test candidate; version publication remains deferred.

### Final screenshot review and physical extension preparation

The DNSDetail screenshot matrix completed successfully. All 44 named screenshot attachments were exported and viewed across six contact sheets in `outputs/ui-audit-work/dns-detail-matrix44-review`. Expanded English text exposed a compressed sidebar version label; the footer now uses a horizontal layout when it fits and a vertical fallback otherwise. This later footer change awaits compilation and physical retesting, and the preceding maintainer candidate consequently predates it.

The first physical network transaction successfully prepared both extensions at build 2026092601, including replacement of the old transparent extension. Baseline scoring then rejected the resident production tunnel because its binary differs from the QA candidate despite identical build numbers. No six-mode pass is claimed. The transaction restored the original Connected state and verified the production app binary was unchanged. An independent internal QA build number, 2026092701, is being prepared so registration cannot reuse the production version; the project release version remains unchanged.

The independent QA candidate at build 2026092701 completed signing and was accepted by notarization submission `dcc04ea7-6bb9-4a85-8ed5-7ac8a637952e`. Remote ticket lookup failed with a TLS error through the existing VPN, so the accepted app was stapled locally and transferred with its ticket. Remote Gatekeeper assessment passed with `source=Notarized Developer ID`, and deep strict signature verification passed after installation at the separate QA path. This is installation evidence, not a network matrix pass.

The footer change compiled successfully in the isolated UI build. A four-row capture request was rejected by the suite's explicit 44-row contract; the subsequent complete matrix could not activate its app because the physical desktop became locked. The remote console session confirmed `CGSSessionScreenIsLocked=Yes`. A request to unlock the desktop is pending; no successful footer screenshot retest is claimed. A normal maintainer candidate containing the footer fix is building while runtime testing awaits that environment change.

The maintainer candidate including the adaptive footer subsequently completed successfully at `outputs/ui-maintainer-footer-final-20260927`. App notarization submission: `39d97064-d30b-4554-925b-6ab0d735173c`; DMG submission: `0eada902-9c6b-419f-8178-980319d7e882`. The four checksum entries passed after synchronization to `MaintainerFooterFinal` on the physical machine. This supersedes the earlier maintainer candidate for testing the latest staged source; `maintainer-footer-final-staged-binding.json` records the 22-file source match. Runtime acceptance and the final commit remain pending.

After the physical desktop was unlocked, the complete footer matrix passed: one matrix test passed, zero failures and zero skips, with all 44 named screenshots exported. Evidence: `footer-matrix44-resumed-20260927.xcresult`, `footer-matrix44-resumed-summary.json` and `footer-matrix44-resumed-attachments` under `outputs/ui-audit-work`. The full-resolution English minimum-window expanded-text screenshot confirms the version label stays on one complete line below Settings instead of wrapping character by character. The independent QA network transaction is now running; its first TUN/rule session proves candidate identity and connectivity, but some external-destination probes time out, so network acceptance remains open.

### Completed physical network diagnostic matrix

All six modes completed with candidate identity checked: TUN/rule had eight failed checks, TUN/global three, TUN/direct zero, transparent/rule five, transparent/global three and transparent/direct zero. Total failed checks: 19. All six per-mode quit checks verified app exit, disconnected Network Extension state, listener removal and restoration of network baseline. The transaction restored the original Connected state and confirmed the production app executable was unchanged. Evidence is retained in `outputs/ui-audit-work/network-matrix-distinct-results`, including `matrix-summary.txt` and `restoration.txt`.

Failures concern external destination reachability, observed egress and IPv6 HTTPS/timeouts. A control probe after restoring the original app also timed out for Cloudflare, the egress service and IPv6; this establishes that those endpoints are unavailable through the restored configuration too, without proving the candidate's full network acceptance. A usable configuration/node has been requested from the maintainer. Network acceptance and the final commit remain open; the failed matrix is not recorded as passing.
