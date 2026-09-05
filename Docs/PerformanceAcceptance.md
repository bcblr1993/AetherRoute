# Performance and reliability acceptance

Performance is a release gate, not an aspirational property. A candidate that
misses any mandatory budget below cannot be labelled production-ready. Local
checks use the isolated UI Review, loopback peers, or a network-denied sandbox;
they must not enable the host Mac's proxy, change DNS or routes, or start TUN.
Signed Network Extension measurements run only on the designated test Mac.

## Candidate budgets

| Surface | Mandatory budget | Required evidence | Current evidence |
| --- | --- | --- | --- |
| UI responsiveness | User actions p95 at or below 120 ms; zero main-thread stalls at or above 250 ms during the 30-minute scripted UI run | XCTest signposts plus Instruments hangs trace in English and Chinese | Automated UI behavior exists; signpost and hangs traces are pending |
| Disconnected idle | Host median CPU at or below 0.5%, p95 at or below 1.5%, resident memory at or below 128 MiB after a five-minute warm-up | Ten-minute `xctrace` CPU and memory sample with the window open, then menu-bar-only | A full fallback-`sample` diagnostic completed both five-minute warm-ups and both ten-minute samples: window-open and menu-bar-only median/p95 CPU were all 0%; maximum RSS was 124,928,000 and 127,205,376 bytes; both socket logs were empty and the system-proxy snapshots matched. The staged verifier passed against its recorded source manifest `7d394523…`. Later runner/assertion/comment/documentation-only changes make the retained `outputs/disconnected-idle-provisional-v7-diagnostic` diagnostic rather than exact-current release evidence. Final `xctrace` evidence remains pending |
| Connected idle | Combined host, extension, and core median CPU at or below 2%, p95 at or below 5%, combined resident memory at or below 256 MiB | Signed TUN and Transparent Proxy ten-minute samples | Pending current signed candidate measurements on the designated test environment |
| Core lifecycle | FlowOnly peak RSS at or below 64 MiB and PacketFlow at or below 32 MiB; no leaked processes or file descriptors | Verifier-backed 500-cycle gates and source manifest | Passing for the current lifecycle harness. Both harnesses measure file descriptors after warm-up and fail above a bounded growth allowance. The current release-shaped schema-2 smoke ran 75 seconds over two complete 500/1,000-cycle Flow/Packet pairs (1,000 and 2,000 lifecycles), with 9,306,112/12,124,160-byte peak RSS, 2/0 peak FD growth, no new exact-core diagnostic report, and no orphan harness process |
| URL tests | At most eight health checks in flight, bounded cancellation, and no file-descriptor exhaustion | 64-task concurrency regression | Passing |
| Large import | A 5,000-node fixture imports in at most two seconds with at most 100 MiB temporary RSS growth; cancellation remains responsive | Release-build XCTest metric and memory trace | Passing: the latest current arm64 Release gate reads, validates, encrypts, and activates 5,000 nodes in 0.118037 seconds with 4,128,768 bytes of sampled peak RSS growth. A controlled blocked-reader test proves cancellation returns `CancellationError` and leaves the encrypted catalog empty; line-scanning validation also has bounded cancellation checkpoints |
| TCP throughput | Current arm64 core throughput at least 1,024 MiB/s for each engine; p95 added loopback latency at or below 5 ms; raw kernel-direct ratio and later release-to-release regression remain visible | Same-host baseline and engine run, five 32 MiB repetitions, 200 latency samples, current artifact and harness hashes | Passing for the current unsigned isolated core surfaces: FlowOnly/flow ABI reached 3,612.962 MiB/s with 0.024 ms added p95; PacketFlow's hardened loopback SOCKS5 surface reached 3,127.443 MiB/s with 0.031 ms added p95. Raw no-relay socket ratios were 59.727% and 52.219% and remain recorded rather than relabelled as passes. The earlier 85% raw-socket target was removed because the zero-relay baseline varies with kernel buffering and excludes the mandatory user-space forwarding boundary. A signed Network Extension end-to-end run remains pending current signed candidate measurements on the designated test environment |
| UDP integrity | Zero missing or duplicated payloads across 10,000 numbered loopback datagrams after bounded warm-up | FlowOnly and PacketFlow black-box gate | Passing on both current arm64 core artifacts: after 32 warm-up payloads, FlowOnly and PacketFlow each delivered 10,000/10,000 numbered payloads with zero missing or duplicates and 8,945,664/11,763,712-byte peak RSS. PacketFlow uses a one-packet acknowledged integrity window; burst throughput is measured by the separate throughput gate |
| Long stability | Zero crashes, hangs, sanitizer reports, orphan processes, and unbounded descriptor growth; post-warm-up RSS slope no more than 1 MiB/hour over 24 hours | Hashed soak output, crash-log scan, RSS/FD time series, source manifest | First run failed at FlowOnly round 405; a later schema-1 run ended without a recoverable verifier-backed result and is invalid for release. Schema 2 records and verifies per-round FD growth in addition to wall time and peak RSS. The independent trend gate requires a verified 24-hour result, discards the first five percent as warm-up, and rejects either engine above a positive 1 MiB/hour least-squares RSS slope. Current release evidence must also show no new exact-name core crash/hang/spin report and no process remaining at either temporary harness path. A new schema-2 run remains required after source freeze |
| Sleep and path change | No crash or UI freeze; state becomes truthful within ten seconds and reconnect remains cancellable | Signed sleep/wake, Wi-Fi path-change, and recovery matrix | Pending current signed candidate measurements on the designated test environment |

Installed Network Extension throughput and latency use the separate
controlled-peer contract in `InstalledNEPerformanceEvidence.md`. Its budget
remains pending calibration and blocks production promotion. The isolated
1,024 MiB/s core floor above stays mandatory; copying it into an installed
TUN/Transparent result does not supply end-to-end evidence.

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
