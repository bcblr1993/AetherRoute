# LAN proxy regression and acceptance

Run `sh Tests/AllowLAN/run.sh` for model tests and 18 production socket tests.
The Swift fixture supplies only an ephemeral `127.0.0.1` listener and session
ownership. All parsing and forwarding uses the application's `LANProxySession`.
Python supplies real IPv4/IPv6 echo and upload targets on loopback. It owns and
terminates the fixture process, with bounded socket waits and a fixture lifetime
limit. No application installation, user preferences, or system networking changes
are needed. The half-close test uses 20 fresh connections across HTTP and SOCKS5,
each uploading 2 MiB and validating the response digest and final EOF.

Once one relay direction finishes, the session is reclaimed after an idle bound
(60 s in the app, 2 s in the fixture) that traffic in the remaining direction
refreshes, so a long response after upload EOF still completes while a peer that
never closes cannot hold one of the 256 session slots indefinitely. A terminal
connection state during relay is given a 5 s grace for pending I/O to finish.
The fixture prints `closed <client port>` whenever a session terminates, so tests
assert that the session itself, not merely the client socket, was reclaimed.

Plain HTTP (non-CONNECT) requests are rewritten by `LANHTTPForwardRequest`: the
request line becomes origin-form, userinfo and fragments are dropped, `Host` is
taken from an absolute URL, hop-by-hop and `Connection`-listed fields are removed
(never `Content-Length`, `Transfer-Encoding` or `Host`), and `Connection: close`
is sent unless the request is a genuine `Upgrade`. The session ends once the
origin's response reaches the client, so a keep-alive client cannot send its next
request, possibly for a different host, to the first origin. Missing or duplicate
`Host`, both `Content-Length` and `Transfer-Encoding`, obsolete line folding, whitespace before a colon and non-`http` absolute
URLs are rejected.

`python3 scripts/test_parallel_acceptance_policy.py` tests release policy using
temporary fixtures. It does not contact SSH or start a VM. It rejects shortened
profiles, skipped ARM64 checks, incomplete matrices, missing engines, stale
candidate identity, modified logs, undersized transfers and incomplete switches.

## Physical runtime evidence

The parallel runner's source tests and UI fixtures do not establish that the
signed candidate transports real traffic on physical hardware. Acceptance now
requires six successful runtime checks: idle reuse, upload and interface switch,
each with TUN and Transparent Proxy. The runner writes the missing-evidence reason
to `physical-runtime-verification.log` and exits nonzero until these are verified.

Every candidate build re-signs with a new timestamp, so evidence can only match a
reused archive. The workflow is therefore two runs on one ZIP:

1. Run the parallel runner. It builds the candidate, runs all gates, and ends
   BLOCKED on missing evidence, printing the exact commands for steps 2 and 3.
   Collect only after it finishes: interface switching disrupts the Mac mini that
   the remote ARM64 and UI performance gates use.
2. Collect TUN and Transparent Proxy evidence for that ZIP (commands below). The
   default evidence directory is `outputs/physical-runtime-<VERSION>-<BUILD>`.
3. Rerun the runner with `AETHERROUTE_ACCEPTANCE_CANDIDATE_ZIP=/absolute/zip`.
   It checks the archive's build number and executables before any build, SSH or
   VM operation, never rebuilds, reruns every gate and then verifies the evidence.

Install the exact QA ZIP produced by the runner on the dedicated Mac mini and
connect it in the engine being tested. The collector checks the installed app and
both embedded extension executable hashes against the ZIP and checks active
provider readiness before and after each test. It never installs, launches,
disconnects, or changes the selected engine. Interface-switch testing deliberately
interrupts the remote test Mac's uplinks; explicit opt-in is required, and the
collector refuses the local hardware UUID or a host other than the SOP Mac mini.

For each engine, after connecting the candidate on that dedicated Mac:

```sh
AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES python3 scripts/collect_physical_runtime_evidence.py \
  /absolute/path/to/candidate.zip chenxu@100.64.0.3 tun /absolute/path/to/physical-runtime
# Connect the candidate in Transparent Proxy mode before the second invocation.
AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES python3 scripts/collect_physical_runtime_evidence.py \
  /absolute/path/to/candidate.zip chenxu@100.64.0.3 transparent /absolute/path/to/physical-runtime
```

Receipts are bound to the ZIP SHA-256, build, host and engine. Each records the
exit status and hash of its full test output. A failed attempt retains its logs;
use a fresh directory for a new attempt. Skipped and inconclusive results fail.
With the candidate unchanged, verify the collected evidence independently:

```sh
python3 scripts/verify_parallel_acceptance.py evidence \
  /absolute/path/to/physical-runtime BUILD chenxu@100.64.0.3 CANDIDATE_SHA256
```

This command verifies only the physical runtime evidence. It does not retroactively
turn a failed parallel run into a pass or substitute for VM, protocol interoperability,
signing, notarization or publication checks. Set `AETHERROUTE_PHYSICAL_RUNTIME_EVIDENCE`
to point the parallel runner at a non-default evidence directory.
