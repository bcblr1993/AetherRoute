# TCP half-close and diagnostic metering regression

## Changes

The transparent TCP pump previously cancelled a connection 15 seconds after
receiving the remote EOF, even while the local application was uploading.
It now uses a monotonic idle deadline. Accepted local reads and completed
bridge writes extend that deadline. A pending bridge write is allowed to drain;
the Rust core retains ownership of the network-side idle policy. One watchdog
checks the remaining interval, rather than allocating a new timer per chunk.
The default local half-close idle interval remains 15 seconds.

The provider's existing diagnostic observer now also receives confirmed TCP and
UDP byte counts. Upstream bytes are counted after the bridge acknowledges the
write; downstream bytes are counted after the Apple-side write succeeds. This
measures the pump boundary, not delivery to the final remote application. A
failed pump increments `sessionsFailed` once; stale callbacks, explicit user
cancellation and expected idle reclamation do not increment it. Native open
outcomes remain in `tcpOpen` / `udpOpen`; these counters alone do not establish
remote node reachability.

A half-close idle expiry now records `trigger=halfCloseTimeout` at the standard
diagnostic level. Ordinary user cancellation remains verbose-only. The terminal
record contains only fixed classifications, session UUIDs, times and counts;
it does not interpolate endpoints, payloads or arbitrary error descriptions.

## Regression evidence

`outputs/tcp-idle-metrics-fix-20261101/` retains the red/green build and test
logs, real-time probe, complete local regression log and memory investigation.

Five tests first failed on the old algorithms (seven assertions):

- An active reverse upload exceeds the half-close interval and then becomes
  idle: it must survive the active period and subsequently be reclaimed.
- A bridge write remains pending past that interval: backpressure must not be
  mistaken for an idle local client.
- Quiet half-closed connections must emit a standard-level timeout record.
- TCP successful/failed writes feed the real provider aggregate observer.
- UDP batches feed that observer and count a terminal failure exactly once.

A behavior-preserving test seam made the existing 15-second constant
configurable, allowing the deadline regressions to run in milliseconds. The
fixed algorithms pass all five cases. An additional probe uses the real default
15-second interval: the old code cancelled at about 15 seconds with local EOF
still false; the fixed code was still running at 16 seconds and had continued
forwarding bytes. The probe uses the production actor with fake I/O and never
changes the machine's network settings.

The new tests are in the existing XCTest targets executed by `scripts/test.sh`.
No Rust engine source or production dependency was changed. The subsequent
release work targets 2.0.2 / 2026110104; the installed extension used for the
measurements below was still 2.0.1.

## Live memory investigation — 2026-11-01

The live application measured here was AetherRoute 2.0.1 / 2026103102, launched on
2026-10-31 at 22:16. These measurements therefore describe the installed app,
not a claim that the uninstalled code changes reduced its memory.

Six `vmmap -summary` samples, taken about 31 seconds apart, show physical
footprint between 195.1M and 197.6M (median 195.75M), ending at 195.1M. Historical
peak is 391.9M. There is no sustained increase in this short observation window.
A `leaks --noContent` scan reports zero unreachable leaked allocations. That
result does not rule out reachable objects retained too long or later growth.

The heap's dominant unclassified blocks include roughly 50,000 allocations
in each of the 2 KiB and 2.5 KiB size classes. Two samples from their dense
allocation region have reference paths through `TTenuousComponentFont` and
the CoreGraphics `CGFontCacheGetLocalCache.local_font_cache` dictionary. This
identifies font-cache retention as a concrete investigation lead. It does not
prove that every allocation in either size class belongs to that cache.
Malloc allocation totals, dirty/resident regions and physical footprint have
different accounting rules and must not be added together.

Offscreen experiments exercise the production menu-bar renderer for 6,000
frames per scenario, with autorelease pools:

- AppKit rasterization: icon-only, static rates and changing rates all plateau
  at roughly 8–9 MiB physical footprint.
- A SwiftUI `NSHostingView` carrying that image: all three scenarios plateau
  at roughly 12–13 MiB.

These experiments did not reproduce the live app's high footprint. They cover
the renderer and a simple hosted image, not the complete window, status-item
integration or 22 hours of user interactions. An initial harness without
`NSApplication` initialization hit a CoreText exception; that invalid startup
experiment was discarded, and all initialized controls completed successfully.

The existing process was not launched with allocation stack logging, so its
historical allocation call stacks cannot be recovered from these snapshots.
The remaining step for a unique root cause is a complete isolated UI process
with allocation stack logging and the actual triggering interaction sequence.
No private cache-flush API, debugger injection, production app restart, payload
memory dump or user-preference change was used during this investigation.

### Native status-item follow-up

A later live footprint sample was 388.7M (historical peak 398.6M). Comparing
heap inventories, however, shows only 4,652,777 additional allocated bytes
(314,928,480 to 319,581,257), not a 193 MB allocation increase. The 2 KiB and
2.5 KiB classes grew by roughly 1,000 allocations each. Diagnostic traversal
can change page residency, so these footprint and allocation changes must not
be equated or used alone to claim a new leak.

A further `vmmap -summary` sample at 2026-11-01 22:08:53, still from PID 12299
without a restart, reports a current footprint of 139.5M and a historical peak
of 400.1M. Its RSS was approximately 484 MiB immediately beforehand. This
observed decline further rules out treating the earlier footprint peak or RSS
as an equal amount of permanently leaked allocations; it does not isolate all
retention sources or replace the targeted renderer regression. The snapshot is
`memory/vmmap-app-before-update.txt` in the evidence directory.

The actual SwiftUI `MenuBarExtra` consumer exposed a failure missed by the
offscreen controls: rapidly changing traffic images raised a CoreText
`NSInvalidArgumentException`. Its stack runs from NSString drawing through
`NSCustomImageRep` and `NSStatusBarButtonCell`. A static-value control completed
6,000 iterations at roughly 16 MB. This is a reproduced diagnostic-process
failure; the installed application's logs did not establish that it crashed
with the same exception.

Traffic icons now finish drawing in a fixed Retina bitmap context and return
ready pixels. Native control drawing no longer invokes the text-layout closure.
The native status-item regression is part of `Tests/MenuBarTraffic/run.sh`,
uses 6,000 changing-rate updates, and rejects a footprint over 64 MiB. The
offscreen tests additionally reject empty images and
right-edge clipping. Four light/dark and badge combinations match the previous
renderer exactly in alpha and premultiplied color. The UI performance gate also
enables menu-bar traffic in its isolated test preferences.

This fixes the observed deferred-drawing failure. It does not by itself prove
the unique origin of every allocation retained by the long-running full app.

### Reproduced retained growth under changing drawing transforms

A controlled consumer varies its drawing scale from 1.0 to 1.3 while drawing
3,000 traffic images, draining autorelease pools each iteration. The old
renderer grows from about 8 MB to 54 MB. After 500 warmup iterations it retains
another 37,191,704 bytes, failing the 8 MiB growth budget. The fixed renderer
stays near 9–10 MB; a run including badged images grew by only 147,456 bytes
after warmup. These separate processes use the same consumer and the old/new
production renderer. This is a reproduced retained-growth path, not an
inference based only on the installed app's footprint.

`Tests/MenuBarTraffic/transforms.swift` enforces that behavioral budget. The
tests also create a colored icon under Aqua and consume it under Dark Aqua,
ensuring cached text pixels retain correct contrast. Colored icons precompute
native appearance variants; their consumers select and draw finished pixels
without text layout.

An allocation-stack-logging rerun of the old native status-item fixture also
completed 6,000 updates without the earlier exception. The exception is
intermittent; the transform-growth regression is deterministic. That short
isolated fixture did not reproduce the full app's roughly 50,000 allocations
in each dominant size class, so the complete historical allocation origin
remains unproven.
