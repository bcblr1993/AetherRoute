# Codex WebSocket interruption investigation — 2026-11-01

## Result and scope

A synthetic Codex request reproduces the reported sequence on the installed
AetherRoute 2.0.1 (2026103102) transparent proxy: successful WebSocket upgrade,
repeated `Broken pipe (os error 32)`, five retries, then successful HTTPS
fallback on the same route. An independent authenticated probe observes a
remote WebSocket close frame with code **1009** as soon as a text frame header
announces **16,777,217 bytes (16 MiB + 1 byte)**. A declaration of 16,777,216
bytes produces no immediate size rejection during the six-second observation.
20, 24, 32 and 34 MiB declarations also receive 1009.

The probe validates the TLS certificate and WebSocket accept value, uses the
existing Codex login in memory and prints only status, size and close code. It
sends no model prompt, image, credential log or frame body. The close frame is
received inside the authenticated TLS connection to the Codex endpoint; this
is evidence of a limit at the remote service/edge, rather than a guessed cause
based on a local TCP reset. The measured boundary is a frame-header rejection
at this endpoint on this date, not a documented guarantee about every OpenAI
product or about successfully processing a complete 16 MiB request.

This establishes a concrete cause of the reproduced retries. It does not prove
that every historical timeout, push-channel reconnect or interruption had the
same cause. The original 09:22 incident had the same upgrade/write-failure/
fallback pattern and substantial image/tool history, but its exact outbound
WebSocket message and close frame were not captured.

## Reproduction and evidence

Evidence lives in the ignored directory
`outputs/diagnostics-codex-ws-20261101/`:

- `codex-small.jsonl`: one synthetic 512 × 512 random PNG; success.
- `codex-large.jsonl`: one synthetic 2048 × 2048 random PNG; success.
- `codex-double.jsonl` / `.stderr`: two copies of the large PNG; repeated
  `Broken pipe`, HTTPS fallback and final `NETWORK_DIAGNOSTIC_OK`.
- `server-close-frames.jsonl` and `server-size-boundary.jsonl`: independent
  authenticated close-frame probes; boundary results above.
- `probe_close_frame.py`: the investigation helper. It reads the existing
  local login only in memory and never prints headers. Do not capture raw
  authentication headers or copy login files into a report.
- `tcp-red-tests.log`: the diagnostic tests before the logging implementation;
  eight assertions fail because the write-failure record is absent.

The Codex CLI tests use `--ignore-user-config --ephemeral --sandbox read-only`,
model `gpt-6.1-sol` (the model from the failing incident), disabled app/plugin/
memory/multi-agent features, no project instructions, and a prompt requesting
only `NETWORK_DIAGNOSTIC_OK` without tools. Synthetic images carry no user
content. For `-i`'s multiple image arguments, separate the prompt with `--`.
The `thread.started` events identify ephemeral diagnostics, not saved work.

For the header probe, keep the declaration bounded (the observed limit plus
one byte is sufficient). Never send subscription details or user conversation
history to an echo service. Public API documentation describes WebSocket
operation but does not establish this measured Codex endpoint size boundary:
<https://developers.openai.com/api/docs/guides/websocket-mode>.

## TCP termination diagnostics

`TCPFlowStateMachine` now emits one `stage=tcpTermination` failure record with:

- the session UUID shared with the ingress session and operation tokens;
- the operation that failed (`flowRead`, `bridgeRead`, `flowWrite`,
  `bridgeWrite`, or either half-close operation), outcome and fixed error class;
- monotonic lifetime, first EOF direction, completed bytes in each direction
  and pending write size.

`flowRead` means bytes read from the local application. `bridgeWrite` means
those bytes being accepted by the Rust bridge; successful bridge acceptance
is not proof of delivery to the node or final server. `bridgeRead` and
`flowWrite` cover the reverse direction. The first observed EOF is a local
observation, not an assertion about who originally initiated a remote close.

Failures are observable in unified logging even with diagnostic mode off.
Ordinary completion/cancellation records remain verbose-only. Arbitrary error
descriptions are excluded because they may contain endpoints or credentials.
Normal terminal summaries are not formatted when verbose logging is disabled.

The Apple network-extension message `closed by plugin (flow error: 50)` is not
sufficient to identify the original fault: session destruction also drains and
closes the Apple flow after normal completion or a remote-side closure.
Likewise, a successful short health probe does not validate a large WebSocket
request. Existing global `up/down/sessionsFailed` aggregate fields were not
wired to the pump and must not be interpreted as proof of zero failures.

The failure-summary changes described here alone do not alter connection
lifetimes or relay policy. Subsequent idle-reclamation and metering fixes are
documented in `TCPHalfCloseAndMemoryDiagnostics.md`. These changes are not
installed into the 2.0.1 extension used for this transport investigation. That
investigation changed no proxy setting, node selection or production dependency.

## Validation

- New diagnostic tests first failed against the behavior-preserving test
  scaffolding (eight assertions), then passed with the implementation.
- Complete `scripts/test.sh` passed (exit 0), including 566 XCTest cases,
  113 Swift Testing cases, 98 transparent-proxy tests and 24 bridge tests.
  All three new TCP diagnostic tests passed in the complete run.
- Network-switch, engine-reconnect and runtime-environment gates passed
  independently. The complete gate also passed the local protocol, plugin,
  recovery, upload and distribution/upgrade regression checks.
- Swift compilation used warnings-as-errors. Xcode's AppIntents metadata-skip
  messages and the existing `hdiutil create` deprecation notices are system-tool
  notices, not new Swift compiler warnings.
- The installed application still reports build 2026103102. No diagnostic build
  was installed, no proxy preferences changed, and no test DMG remains mounted.
  Synthetic image fixtures (13,376,100 bytes) were removed; evidence is retained
  with verified SHA-256 checksums. The test runner removed its temporary roots.

## Practical handling

For the demonstrated oversized-request case, reduce serialized history/images
(for example, compact a long conversation or start a shorter one), or allow the
client's HTTPS fallback to finish. Token count alone does not bound base64
image bytes. Repeatedly reconnecting the identical oversized frame cannot
remove the remote limit. Do not add TLS interception or split the encrypted
application request in AetherRoute; the relevant transport/fallback behavior
belongs in the Codex client/service.

A future failure on a build containing these logs can be collected with:

```sh
/usr/bin/log show --last 10m --style compact --info \
  --predicate 'subsystem == "com.aetherroute.desktop" AND eventMessage CONTAINS "stage=tcpTermination"'
```

Correlate its timestamp/session/stage with Codex's model-request error, rather
than treating unrelated push-channel reconnects as the same event.
