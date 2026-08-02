# Disconnected idle-performance evidence — 2026-08-02

## Final isolated Release measurement

- Completed: `2026-08-02T10:39:41Z`
- Platform: Apple Silicon, macOS 26.3
- Configuration: Release with the dedicated performance-measurement fixture
- Profiler: Instruments `xctrace`
- Warm-up: 300 seconds per state
- Sample window: 600 seconds per state, one sample per second
- Window-open CPU median / p95: 0.000% / 0.000%
- Window-open maximum RSS: 128,712,704 bytes (122.75 MiB)
- Menu-bar-only CPU median / p95: 0.000% / 0.000%
- Menu-bar-only maximum RSS: 125,026,304 bytes (119.23 MiB)
- Acceptance limits: median CPU 0.5%, p95 CPU 1.5%, RSS 134,217,728 bytes
- Network Extension: disabled
- Network sockets observed: none
- System proxy snapshot: unchanged
- Full controller proxy, DNS, default-route, and interface snapshot: unchanged
- Source snapshot SHA-256: `98c3a371ff31a80b6120fe3004c5a18469d57fe5e7e28a67b90c9a4ca1601bd5`
- App executable SHA-256: `409043092ed119dab211742b2a69574457c30ab2dd1e6c6b26119c20b345c475`
- Result: passed

## Retained evidence

The complete verifier-backed evidence, including both Instruments traces and
their file manifests, is retained under
`outputs/disconnected-idle-xctrace-final-98c3a371`. The repository verifier
passes against the exact current source tree. The earlier fallback `sample`
measurement remains historical only and is not used as release evidence.
