# Installed Network Extension performance evidence

The 1,024 MiB/s floor belongs to the isolated arm64 core benchmark in
`test_tcp_performance.sh`. Its Flow ABI and Packet loopback SOCKS5 measurements
do not measure an installed Network Extension or an Internet connection.
That mandatory core gate remains unchanged.

Installed performance has a separate controlled-peer contract. The committed
`Config/InstalledNEPerformanceBudget.json` is initially `pending-calibration`:
no installed performance evidence can authorize production until repeatable
measurements justify reviewed, committed budgets. No environment override can
replace the policy. A completed collection is not an acceptance result.

## Collector interface

The real collector entry point is:

```sh
scripts/collect_installed_ne_performance.sh \
  /absolute/candidate.dmg /absolute/candidate.candidate.json \
  /absolute/new/installed-ne-performance
```

The collector uses `installed_ne_performance_peer.py`, an explicitly started,
task-owned HTTPS peer, and requires the controlled-peer options shown by
`collect_installed_ne_performance.sh --help`. Its private token and local CA
certificate stay in local files; the CA applies only to this collector's curl
requests, without changing a system trust store. The operator prepares and
confirms each disconnected or connected engine phase in the signed app; the
collector independently checks that state and does not activate the app itself.
Cancellation records an incomplete result and requires network restoration.

If the `.test` payload hostname has no test DNS record, pass
`--candidate-address` with a private or documentation IPv4 destination captured
by the profile's rules. It must differ from the baseline and node addresses.
This affects only candidate payload requests through curl's `--resolve`;
the HTTPS hostname, certificate verification and provider-flow/relay-receipt
checks remain required. Baseline and control requests retain their original
destinations, and no system DNS or hosts file is changed.

The validator requires every file named in `collectorSources` to exist and
match its recorded SHA-256. A new helper must be added to that committed list;
a missing or changed collector cannot satisfy the gate. Collection runs on the
designated test Mac with explicit network authorization and a recoverable
control path. It must hash and mount the exact candidate DMG, derive archived
provider identities from its signed app, compare installed identities, and
verify the tested provider's current process lifetime and actual traffic.
Never substitute an isolated core or local SOCKS port for either NE path.

Normal-core notarized test candidates may be collected for calibration or
diagnosis, with explicit `pending`/`incomplete` status. Their normal variant,
absent diagnostic markers and matching protocol-reference hashes must be
verified by the collector. The production validator still only accepts
`notarized-candidate`; a test candidate or diagnostic core cannot authorize
production. This distinction allows calibration before the formal release
without introducing a release-gate bypass.

The directory contains exactly `performance.json` and `SHA256SUMS`. The latter
has one SHA-256 entry naming `performance.json`. It contains no raw endpoint,
credential, profile, URL, process log, or packet capture. The enclosing
post-install `result.txt` binds this checksum file through
`installed_ne_performance_evidence_sha256`. The enclosing post-install metadata
uses schema 2; schema 1's standalone throughput/latency claims are obsolete.

`performance.json` has exactly these top-level fields:

Incomplete diagnostic collections may set `collectionStatus` to `incomplete`
or `pending` and include `blockingReasons`; the release validator rejects both.
Only `complete` collections may use the strict acceptance schema below.

| Field | Contract |
| --- | --- |
| `schemaVersion` | `1` |
| `collectionStatus` | `complete`; this never means performance passed |
| `surface` | `installed-network-extension` |
| `candidate` | `dmgSHA256`, `manifestSHA256`, `sourceManifestSHA256`, `productID`, `version`, integer `build`; all match the supplied production candidate manifest |
| `collectorSources` | Object mapping every committed collector source path to its actual SHA-256 |
| `budgetSHA256` | SHA-256 of the committed budget file |
| `machine` | `architecture` (`arm64`), nonempty `model`, `macOSBuild`, `hostNameSHA256` |
| `topology` | `kind` (`controlled-peer`), `transport` (`tcp`), `baseline` (`same-peer-provider-disconnected`), `peerIdentitySHA256`, `internetPath` (`false`) |
| `providers` | Objects `tun` and `transparent`, as below |
| `samples` | Exactly five paired samples per engine per direction, 20 pairs total |

Each provider has exactly `bundleID`, `version`, integer `build`, `teamID`,
`archivedExecutableSHA256`, `installedExecutableSHA256`, `archivedCDHash`, and
`installedCDHash`. Bundle IDs are the candidate `productID` plus `.tunnel` or
`.transparent-proxy`; version/build match the candidate. Installed and archived
executable hashes/CDHashes must agree, and both providers belong to one team.
Collector identity observations must come from the verified candidate and
installed binaries, not caller-supplied claims.

Each sample pair has exactly `engine` (`tun` or `transparent`), `direction`
(`upload` or `download`), zero-based `pairIndex`, `baseline`, and `candidate`.
Each engine/direction has indices 0 through 4 exactly once. Alternate baseline
and candidate against the same controlled peer, outside the timed setup phase.
Warm up each path first. Choose a destination actually captured by the NE;
ordinary loopback and configured bypass destinations do not qualify. Exercise
both upload and download and verify payload integrity at the receiving end.

Both measurements contain exactly these common fields:

| Field | Contract |
| --- | --- |
| `bytesSent`, `bytesReceived` | Equal positive integers for payload actually received, excluding setup/headers; upload is client sent / peer received, download is peer sent / client received |
| `sentPayloadSHA256`, `receivedPayloadSHA256` | Equal lowercase SHA-256 of the transferred payload |
| `startedMonotonicNanoseconds`, `endedMonotonicNanoseconds` | Positive integers bounding the observation, from before starting curl to receipt of its payload result; include arm/TLS setup and pipe scheduling, and must cover `transferDurationNanoseconds` |
| `transferDurationNanoseconds` | Positive integer of curl's payload-operation `time_total`, at least 10 seconds; excludes the preceding arm/TLS setup and subsequent hold operation |
| `latencyNanoseconds` | Exactly 200 positive integer round-trip echo durations collected on the same path |
| `providerActive` | Baseline `false`, candidate `true` |
| `peerIdentitySHA256` | Matches the topology's controlled peer |

The candidate measurement additionally contains `providerPID` (positive),
`providerStartedAt` (UTC RFC3339), `providerBundleID`, `providerCDHash`,
`providerObservedBytesBefore`, `providerObservedBytesAfter`. The identity must
match the installed provider; the observed traffic counter must increase by at
least `bytesReceived`. This observation must belong to that PID/start lifetime,
direction and test interval. The additional `counterSource` must be
`nettop-process`, `pathAttribution` must be `provider-flow-observed`, and
`providerFlowObservationSHA256` must hash the temporary specific-flow
observation attributed to that PID/lifetime. These are provider process
counters, not core counters. Merely finding an idle extension process, changing
a route, or reading an aggregate counter is not traffic attribution. If a
collector cannot obtain this proof it must report failure, not invent fields.
Candidate transfer follows its paired baseline; all recorded transfer intervals
must be distinct and nonoverlapping. A task-owned peer may expose a reachable
baseline and enforce a proxy-only receipt for the candidate using the same
service and payload contract; the collector must verify that causal receipt.

## Verification and calibration

`verify_installed_ne_performance_evidence.sh EVIDENCE CANDIDATE_MANIFEST`
validates the strict schema, checksum and all bindings, then recomputes rates
from received bytes divided by the actual payload `transferDurationNanoseconds`.
The surrounding monotonic interval establishes order and coverage, not the
throughput denominator: stderr delivery and arm/setup delays are not transfer
time. For each engine/direction
it checks the median of the five candidate/baseline rate ratios against the
committed minimum. Baseline spread `(max - min) / median` must stay within the
committed bound; an unstable environment fails, never excuses a candidate.
Added latency is the nonnegative difference between candidate and baseline p95
over the combined echo samples. No caller-written throughput or latency scalar
is accepted. Thresholds and rates use exact rational arithmetic.

Calibration must use this real collector on a documented reference Mac and
controlled peer, with reproducible paired runs and retained privacy-safe raw
numeric samples. The reviewed policy must identify the calibration evidence
hash and set throughput ratio, baseline stability and added latency budgets
before the final candidate's acceptance run. Do not choose a threshold merely
to pass that candidate. Keep Internet bandwidth observations separate: the
isolated 1 GiB/s budget is not a promise about a user's ISP or proxy node.
Once an accepted release exists, also apply the same-Mac 10% regression review
rule from `PerformanceAcceptance.md`.

Missing collection, pending calibration, a stale collector/candidate/provider,
insufficient or inconsistent samples, altered checksums, or a failed measured
budget all block promotion. A checksum binds recorded evidence; it does not
authenticate a human-edited claim. Review and reproducible real collection
remain necessary, and regression fixtures must never become release evidence.
