# Interface performance budget

Targets the app must keep while the interface is rebuilt. Each one names how
it is measured; a target without a measurement yet says so and which phase
adds it.

| Area | Target | Measured by | Status |
|---|---|---|---|
| Disconnected idle, window open | CPU median ≤ 0.5%, p95 ≤ 1.5%, RSS ≤ 128 MiB | `scripts/test_disconnected_idle_performance.sh` (Release, 5 min warm-up, 10 min sample) | Gate exists; last evidence 2026-08-02: 0.000% / 0.000%, 122.75 MiB |
| Disconnected idle, menu bar only | Same limits | Same script | Same evidence: 0.000% / 0.000%, 119.23 MiB |
| Page switch, first rendered frame | p95 ≤ 100 ms (gate today: 120 ms) | `UIResponsivenessProbe` through `scripts/test_ui_responsiveness.sh` (XCUITest; run in the macos27 VM) | Gate exists at 120 ms; tighten to 100 ms after the design-system phase |
| Settings tab switch | p95 ≤ 100 ms | Same probe (`settings.<tab>`) | Probe exists |
| Menu bar panel open | Content on first frame, ≤ 150 ms | Probe to add with the panel rebuild | Not measured yet |
| Large lists | 10,000 rules and 2,000 connections: page first frame ≤ 300 ms, filter ≤ 50 ms | `AETHERROUTE_UI_REVIEW_PROFILE=large` review fixture with the page tour below | Measured 2026-10-01: filter 0.2 ms (rules), 2.4 ms (connections); first frame Connections ≈ 310 ms, Profiles ≈ 200 ms; scroll smoothness not yet measured |
| Live telemetry | Only the views showing a value re-render on a sample | `scripts/test_telemetry_observation_scope.sh` (structure guard) | Gate exists |
| Animation | No repeating animation except the connecting indicator; timers pause when no window is visible | Code review against `Docs/DesignQA.md`, idle gate above | Partly gated (idle CPU) |

## Rules that keep the budget

- High-frequency values (traffic, connections, latency) are observed only by
  the leaf view that draws them; pages never observe the whole model for them.
- Lists that can grow without bound (rules, connections, nodes) render lazily.
- Timers and `TimelineView`s pause when nothing on screen shows their output.
- Work triggered by a keystroke (search, filter) is debounced or done off the
  main thread when it touches more than a few hundred items.

## Page tour (Debug review builds)

`AETHERROUTE_UI_REVIEW_PERF_TOUR=<file>` switches through every page three
times, records selection-to-first-frame for each, times the pure work behind
the large lists (profile parsing, rule search, route test, connection search
and sort), writes the results to `<file>` and quits.
`AETHERROUTE_UI_REVIEW_PERF_FOCUS=<page>` alternates one page with DNS twelve
times instead, so `sample` can profile just that page. Combine with
`AETHERROUTE_UI_REVIEW_PROFILE=large` (500 nodes, 10,000 rules, 2,000 flows).
Build with `SWIFT_OPTIMIZATION_LEVEL=-O` for numbers close to Release.

Measured 2026-10-01 (Apple Silicon, optimized Debug, second and third visits):

| Page | Standard fixture | Large fixture |
|---|---|---|
| Overview | 59-150 ms | 60-158 ms |
| Proxies | 85-89 ms | 116-136 ms |
| Connections | 151-180 ms | 310-386 ms |
| Profiles | 106-108 ms | 194-254 ms |
| Rules | 61-153 ms | 77-185 ms |
| DNS | 45-64 ms | 34-49 ms |

What changed to get there: one glass container per page; Connections counts
outlets in one pass and offers two toolbar layouts instead of four; segmented
widths are cached with digits normalised, so live counts do not re-measure the
control on every sample; the Proxies node list is lazy; profile node counts are
cached per profile version. Profile parsing (10,000 rules: about 130 ms) runs
on import or activation, not on page visits. The remaining time is SwiftUI and
AppKit layout; Connections with 2,000 rows spends most of it building the
table's rows.
