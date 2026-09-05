# Performance and reliability acceptance

Performance is a release gate, not an aspirational property. A candidate that
misses any mandatory budget below cannot be labelled production-ready. Local
checks use the isolated UI Review, loopback peers, or a network-denied sandbox;
they must not enable the host Mac's proxy, change DNS or routes, or start TUN.
Signed Network Extension measurements run only on the designated test Mac.

## Candidate budgets

The observation column is a development record covering documentation recorded
on 2026-08-03 and measurements reviewed on 2026-09-05. Each result applies only
to its cited run and source revision, not to the final frozen candidate. Final
acceptance is determined by reports bound to the candidate's source manifest
and artifact hashes. Record later outcomes with that release evidence; this progress
table does not need to be edited merely to approve a frozen candidate.

| Surface | Mandatory budget | Required evidence | Dated development observations |
| --- | --- | --- | --- |
| UI responsiveness | User actions p95 at or below 120 ms; zero main-thread stalls at or above 250 ms during the 30-minute scripted UI run | XCTest signposts plus Instruments hangs trace in English and Chinese | September 5 targeted UI checks and an Instruments positive control exist; the final 40-test UI suite, verified text-expansion coverage and 30-minute signpost/Hangs measurement remain pending. The old large/xxxLarge parameter produced identical native macOS font dimensions and cannot establish expanded-text acceptance ([UI probe][ui-probe]). |
| Disconnected idle | Host median CPU at or below 0.5%, p95 at or below 1.5%, resident memory at or below 128 MiB after a five-minute warm-up | Ten-minute `xctrace` CPU and memory sample with the window open, then menu-bar-only | Historical fallback-`sample` observation recorded in [aabbe3e][historical-performance] (August 3 documentation date; original measurement date and raw bundle not revalidated in this review): both five-minute warm-ups and ten-minute samples completed; window-open/menu-bar-only median and p95 CPU were 0%, maximum RSS was 124,928,000/127,205,376 bytes, socket logs were empty and proxy snapshots matched. The record names source manifest `7d394523…` and `outputs/disconnected-idle-provisional-v7-diagnostic`. Subsequent free-distribution, bundled-resource, sidebar and narrow-window changes include product code. These numbers do not validate the final app; final-candidate `xctrace` evidence remains pending. |
| Connected idle | Combined host, extension, and core median CPU at or below 2%, p95 at or below 5%, combined resident memory at or below 256 MiB | Signed TUN and Transparent Proxy ten-minute samples | Pending final signed-candidate measurements on the designated test environment; signing inputs are available. |
| Core lifecycle | FlowOnly peak RSS at or below 64 MiB and PacketFlow at or below 32 MiB; no leaked processes or file descriptors | Verifier-backed 500-cycle gates and source manifest | September 5 normal-core smoke: 62 measured seconds, two complete 500/1,000-cycle Flow/Packet pairs (1,000/2,000 lifecycles), peak RSS 9,551,872/12,681,216 bytes, peak FD growth 2/0, no new diagnostic report or orphan process ([soak review][soak-review]). Its four corrected runner/verifier source hashes match commit `daee38b`; the recorded complete source manifest is `ecde5930…`. This is a short development observation, not 24-hour or signed-provider acceptance. Both harnesses retain their post-warm-up FD-growth checks. |
| URL tests | At most eight health checks in flight, bounded cancellation, and no file-descriptor exhaustion | 64-task concurrency regression | Historical passing report in [aabbe3e][historical-performance] (August 3 documentation date). It is not a source-bound approval of the final candidate; retain the required 64-task concurrency and cancellation regression. |
| Large import | A 5,000-node fixture imports in at most two seconds with at most 100 MiB temporary RSS growth; cancellation remains responsive | Release-build XCTest metric and memory trace | September 5, `8357019`: the arm64 Release gate read, validated, encrypted and activated 5,000 nodes in 0.114223 seconds with 4,980,736 bytes of sampled peak RSS growth. The blocked-reader cancellation and bounded line-scan cancellation checks also passed ([normal-run log][normal-log]). This belongs to the 13-minute-30-second normal development run, not the later frozen candidate. |
| TCP throughput | Current arm64 core throughput at least 1,024 MiB/s for each engine; p95 added loopback latency at or below 5 ms; raw kernel-direct ratio and later release-to-release regression remain visible | Same-host baseline and engine run, five 32 MiB repetitions, 200 latency samples, current artifact and harness hashes | September 5, `8357019`, unsigned isolated surfaces: FlowOnly/flow ABI reached 3,803.637 MiB/s with 0.031 ms added p95; PacketFlow/loopback SOCKS5 reached 3,211.562 MiB/s with 0.043 ms added p95. Raw no-relay ratios were 61.346%/51.004%; the log records both normal archive hashes and `network_extension=disabled` ([normal-run log][normal-log]). These are revision-bound core observations. The earlier 85% raw-socket target was removed because that zero-relay baseline varies with kernel buffering and excludes mandatory user-space forwarding. Final signed Network Extension end-to-end measurements remain pending. |
| UDP integrity | Zero missing or duplicated payloads across 10,000 numbered loopback datagrams after bounded warm-up | FlowOnly and PacketFlow black-box gate | September 5, `8357019`: after 32 warm-up payloads, both normal arm64 cores delivered 10,000/10,000 numbered datagrams with zero missing or duplicates; peak RSS was 9,158,656/12,042,240 bytes ([normal-run log][normal-log]). The log binds each archive/harness and records `network_extension=disabled`. PacketFlow uses a one-packet acknowledged integrity window; burst throughput has a separate gate. This is isolated development evidence. |
| Long stability | Zero crashes, hangs, sanitizer reports, orphan processes, and unbounded descriptor growth; post-warm-up RSS slope no more than 1 MiB/hour over 24 hours | Hashed soak output, crash-log scan, RSS/FD time series, source manifest | Earlier documentation records a FlowOnly failure at round 405 and an unrecoverable schema-1 run; neither is release evidence ([historical record][historical-performance]). September 5 fixed a verifier that could accept 800 synthetic pairs spanning 24 hours with only 2,400 measured seconds. The corrected mechanism, committed as `daee38b`, passed failure regressions and the actual 62-second smoke; the production verifier correctly rejected that short run ([soak review][soak-review]). No final-source 24-hour result exists. Schema 2 still verifies per-round wall time, peak RSS and FD growth, with no new exact-name core crash/hang/spin report or orphan harness. |
| Sleep and path change | No crash or UI freeze; state becomes truthful within ten seconds and reconnect remains cancellable | Signed sleep/wake, Wi-Fi path-change, and recovery matrix | Pending final signed-candidate measurements on the designated test environment; signing inputs are available. |

Installed Network Extension throughput and latency use the separate
controlled-peer contract in `InstalledNEPerformanceEvidence.md`. Its budget
remains pending calibration and blocks production promotion. The isolated
1,024 MiB/s core floor above stays mandatory; copying it into an installed
TUN/Transparent result does not supply end-to-end evidence.

The long-stability runner must accumulate at least 24 hours of measured round
runtime. Preparation, bookkeeping gaps and final source verification do not
earn runtime credit. Consecutive Flow/Packet intervals must not overlap or have
more than one second of recording gap; the existing total-duration cap still
applies. The independent trend gate still discards the first five percent as
warm-up and rejects either engine above a positive 1 MiB/hour least-squares
RSS slope. A short successful smoke only validates the runner and is not
release soak evidence.

The September 5 [normal-run result][normal-result] records exit 0, unchanged
source `8357019129edb78f8799d88d84f60091aa85ae75`, and a verified log digest;
its elapsed time was 809.942 seconds. Later product changes require their own
candidate-bound measurements.

[historical-performance]: https://github.com/bcblr1993/AetherRoute/blob/aabbe3e/Docs/PerformanceAcceptance.md
[normal-log]: ../outputs/product-completion-20260905/evidence/full-normal-tests-sidebar-final/test.log
[normal-result]: ../outputs/product-completion-20260905/evidence/full-normal-tests-sidebar-final/result.json
[soak-review]: ../outputs/soak-continuity-review/review-status.json
[ui-probe]: ../outputs/product-completion-20260905/evidence/ui-final/dynamic-type-platform-probe/result.json

## Measurement rules

- Use a Release arm64 build for CPU, memory, throughput, and latency numbers.
- The disconnected-idle fixture is compiled only into its dedicated Release
  measurement build. It forces a disconnected state, disables runtime path,
  subscription, licensing, and Network Extension preparation, rejects any app
  network socket, and verifies the system proxy snapshot is unchanged. The
  fallback macOS `sample` profiler may produce explicitly `provisional`
  evidence while Developer Tools automation is unavailable; only a finalized
  `xctrace` bundle can satisfy the release gate.
- AddressSanitizer runs execute the complete large-import path but do not apply
  the Release RSS ceiling because allocator redzones and quarantine are part of
  the instrumented process. The dedicated uninstrumented Release gate remains
  the only authority for the 100 MiB import budget.
- Record the Mac model, macOS build, source manifest, build configuration,
  engine, profile fixture, sample duration, and raw result path.
- Measure host app, Network Extension, and core separately and also report their
  combined resource use. A low host number cannot hide an expensive provider.
- Warm caches before steady-state measurements, but publish cold-start and
  first-import time separately.
- Compare against the previous accepted release on the same Mac. A regression
  above 10% requires explanation and explicit approval even when it remains
  under the absolute budget.
- Raw loopback socket throughput is diagnostic, not a pass threshold: it has no
  user-space relay and is highly sensitive to kernel buffering. The absolute
  core floor and p95 latency are mandatory; once an accepted release exists,
  the same-Mac 10% regression rule is mandatory as well.
- Scan macOS crash and spin reports after every long run. Test completion alone
  does not prove the absence of a crash or hang.
- Preserve failing evidence. Never replace an incomplete or failed run with a
  hand-written success marker.

## Runtime design constraints

- Language changes are event-driven. They add no polling loop, worker thread,
  network request, or relaunch, and only rebuild the visible SwiftUI hierarchy.
- Settings use a sidebar and instantiate only the selected detail surface.
- Telemetry UI updates are bounded to a human-readable cadence and do not
  trigger whole-window list reconstruction.
- Subscription refresh, update checks, and licensing refresh use bounded
  timeouts, cancellation, backoff, and concurrency. None may block the main
  actor or keep the app in an uninterruptible connecting state.
