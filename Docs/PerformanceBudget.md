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
| Large lists | 10,000 rules and 2,000 connections scroll without dropped frames; filter ≤ 50 ms | Review fixtures with large data sets, added with the performance phase | Not measured yet |
| Live telemetry | Only the views showing a value re-render on a sample | `scripts/test_telemetry_observation_scope.sh` (structure guard) | Gate exists |
| Animation | No repeating animation except the connecting indicator; timers pause when no window is visible | Code review against `Docs/DesignQA.md`, idle gate above | Partly gated (idle CPU) |

## Rules that keep the budget

- High-frequency values (traffic, connections, latency) are observed only by
  the leaf view that draws them; pages never observe the whole model for them.
- Lists that can grow without bound (rules, connections, nodes) render lazily.
- Timers and `TimelineView`s pause when nothing on screen shows their output.
- Work triggered by a keystroke (search, filter) is debounced or done off the
  main thread when it touches more than a few hundred items.
