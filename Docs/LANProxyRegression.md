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
signed candidate transports real traffic on physical hardware. Release packaging
therefore requires six successful runtime checks on the dedicated Mac mini: idle
reuse, 2 MiB upload and interface switch, each with TUN and Transparent Proxy.

The evidence is bound to the **notarized candidate DMG** (AGENTS.md step 5), not
the QA ZIP: the Mac mini's system extensions only load notarized builds, and the
QA ZIP only runs in the VM's developer mode. `package_release_dmg.sh` copies the
app out of that DMG unchanged, so the published app is the one tested on hardware.

1. Run the parallel runner (VM matrix, remote ARM64 gate, UI performance). It no
   longer checks physical evidence and says so when it passes.
2. Build the stable notarized candidate. Do not start or stop the Tart VM while it
   builds: the candidate's network-state check fails when the VM's interfaces change.
3. After the remote ARM64 and UI performance gates have finished (interface
   switching disrupts the same Mac mini), install the candidate DMG's app on the
   Mac mini, connect in TUN mode and collect, then reconnect in Transparent Proxy
   mode and collect again (commands below). The default evidence directory is
   `outputs/physical-runtime-<VERSION>-<BUILD>`.
4. Run `package_release_dmg.sh` on that same DMG. It accepts only a `.dmg` source
   and verifies the evidence against the DMG's SHA-256, build and host before any
   signing or notarization; `AETHERROUTE_PHYSICAL_RUNTIME_EVIDENCE` overrides the
   directory.

The collector mounts the DMG read-only, checks the installed app's executable and
both embedded extension executables against it, and checks active provider
readiness before and after each test. It never installs, launches, disconnects,
or changes the selected engine. Interface-switch testing deliberately interrupts
the remote test Mac's uplinks; explicit opt-in is required, and the collector
refuses the local hardware UUID or a host other than the SOP Mac mini.

```sh
AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES python3 scripts/collect_physical_runtime_evidence.py \
  /absolute/path/to/notarized-candidate.dmg chenxu@100.64.0.3 tun /absolute/path/to/physical-runtime
# Connect the candidate in Transparent Proxy mode before the second invocation.
AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES python3 scripts/collect_physical_runtime_evidence.py \
  /absolute/path/to/notarized-candidate.dmg chenxu@100.64.0.3 transparent /absolute/path/to/physical-runtime
```

Receipts are bound to the DMG SHA-256, build, host and engine. Each records the
exit status and hash of its full test output. A failed attempt retains its logs;
use a fresh directory for a new attempt. Skipped and inconclusive results fail.
To check the evidence on its own:

```sh
python3 scripts/verify_parallel_acceptance.py evidence \
  /absolute/path/to/physical-runtime BUILD chenxu@100.64.0.3 DMG_SHA256
```

This verifies only the physical runtime evidence. It does not substitute for the
VM matrix, protocol interoperability, signing, notarization or publication checks.
