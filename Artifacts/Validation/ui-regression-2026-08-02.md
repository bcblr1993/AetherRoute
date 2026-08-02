# UI regression evidence — 2026-08-02

## Final isolated full-suite run

- Remote host: Apple Silicon macOS test machine
- Started: `2026-08-02T09:17:25Z`
- Finished: `2026-08-02T09:50:16Z`
- Tests executed: 38
- Passed: 36
- Skipped by explicit build conditions: 2
  - UI responsiveness performance condition is covered by the separate idle-performance gate.
  - Signed Network Extension lifecycle requires a production-signed build.
- Failed: 0
- Test process status: 0
- Source snapshot SHA-256: `2883288ef1162abef795e9b7adb53f5ed6ee44411cfd3e85752c0380e7d7adbc`
- Source unchanged after run: yes
- Network-control snapshot before/after SHA-256: `73d863a636a5ab375373bf01ee40d0b129b3d9ac73d1edccf7c7e899ce5bf9fe`
- System proxy, DNS, routes, and interface inventory unchanged: yes
- Raw result bundle and build directory were temporary and were deleted by the test harness.

## Findings corrected before the final run

- About-page version text failed the first accessibility contrast audit. It now uses an explicit high-contrast light/dark foreground and a semibold monospaced subheadline.
- Rules-page `Evaluation order` failed the first contrast audit. It now uses a dedicated native title-level section heading.
- A shared custom headline weight changed glyph metrics and caused the English `Proxy groups` heading to fail contrast auditing. Shared feature headings were restored to the native macOS `.headline` style.

## Targeted confirmation before the final suite

- Proxies page accessibility audit in light and dark appearances: passed.
- Rules page accessibility audit in light and dark appearances: passed.
- English expanded-text coverage across all primary pages: passed.
- Chinese/English language round-trip, all visible surfaces, and About version: passed.
- Every targeted run preserved both the source manifest and the remote network-control snapshot.

## Acceptance boundary

This result closes the unsigned UI-preview gate. It does not substitute for the
production-signed Network Extension lifecycle gate, Developer ID signing,
notarization, or the 24-hour isolated soak.
