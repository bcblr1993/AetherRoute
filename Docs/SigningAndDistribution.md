# Developer ID signing and independent distribution

AetherRoute is distributed as a notarized DMG outside the Mac App Store. No
Store target, Store receipt, App Store Connect upload, or Store provisioning
profile is part of the product.

The first public edition is free and accepts the user's own proxy profiles.
Its signed metadata explicitly sets `AetherRouteDistributionMode=free`.
It requires no account, activation, license server, or update server; upgrades
use a newer signed DMG and preserve the user's saved configurations. Free
builds reject embedded licensing/update service settings, so accidentally
mixed configuration cannot silently change the product's access policy.
The optional `licensed` mode retains signature and receipt verification and
refuses incomplete service configuration. Missing mode metadata does not
unlock a stable licensed build.

The `signedReceipt` terms used by the licensing client refer only to
AetherRoute's owner-operated Ed25519 license envelope; they do not use Apple's
Store receipt APIs. App Sandbox remains enabled because it is a deliberate
security boundary for the host and Network Extensions, not because the app is
a Mac App Store product. `scripts/verify_independent_distribution_boundary.sh`
requires the host's explicit independent-distribution build mode and fails if
StoreKit, Apple Store receipt APIs, Store commerce entitlements, Store signing
identities, or Store export methods reappear.

The exact owner-operated licensing and signed update API contract is defined
in [`IndependentDistributionServices.md`](IndependentDistributionServices.md).

## Read-only inventory and strict preflight

Inventory mode is safe on a clean M-series build host. It does not install a
profile, change Keychain access, sign an app, register a Network Extension, or
start a tunnel:

```sh
./scripts/signing_preflight.sh
```

For a real build, copy `Config/Signing.example.json` outside source control and
provide the final Team ID, application identifiers, App Group, Keychain group,
Developer ID Application certificate SHA-1, and three explicit Developer ID
profiles: host, Transparent Proxy, and Packet Tunnel. Never place certificates,
private keys, passwords, notary credentials, or the completed JSON in the
repository.

```sh
./scripts/signing_preflight.sh /absolute/path/to/Signing.json
./scripts/generate_signing_overrides.sh \
  /absolute/path/to/Signing.json \
  /absolute/path/to/AetherRouteSigning.xcconfig
```

The strict gate validates exact Team ID and App Identifier Prefix values,
non-wildcard application identifiers, App Group and Keychain groups, both
Network Extension grants, profile expiration, identity availability, and exact
agreement with the generated Xcode target settings. The generated override is
mode 600 and contains no certificate fingerprint, profile path, password, or
notary credential.

## Test candidate core variants

Both `build_signed_local_test_candidate.sh` and
`build_notarized_test_candidate.sh` accept
`AETHERROUTE_TEST_CORE_VARIANT=normal|diagnostics`. The default remains
`diagnostics` for investigation. Use `normal` when collecting signed-runtime
evidence that must remain valid for the normal production archives:

```sh
AETHERROUTE_TEST_CORE_VARIANT=normal \
./scripts/build_notarized_test_candidate.sh \
  /absolute/path/to/Signing.json notary-keychain-profile \
  1.0.0 1001 /absolute/new/normal-core-test-candidate
```

Every variant first builds the fixed normal Flow and Packet features, rejects
diagnostic markers, and verifies both archive hashes against the current
protocol evidence. Normal retains those archives. Diagnostics then rebuilds
with its diagnostic features and requires the expected markers. No protocol
hash or source-manifest guard is skipped or rewritten to accept a different
variant. Notices are regenerated for the actual archives and checked in the
source and signed app.

The schema-1 candidate manifest adds `core.variant`, actual Flow/Packet archive
hashes and features, and `core.protocolReference` with the verified normal
archive hashes and protocol-evidence hash. `safety.diagnosticsIncluded` remains
explicit. Normal requires `matchesCandidateArtifacts=true`; diagnostics
requires `false`. The core metadata is checked against the frozen source
manifest, and normal candidates reject diagnostic markers in every packaged
Mach-O. Normal artifact names end in `-Normal-Core` before their extension.

Collect release evidence with a normal candidate after the source and notices
are frozen. A diagnostic candidate's source manifest and actual archive hashes
cannot serve as normal release evidence. Rebuilding another variant or editing
source invalidates that binding. A normal test candidate is still a test
artifact: production uses `release.sh`, followed by exact-DMG post-install
verification and `promote_candidate.sh`.

## Signed Network Extension lifecycle gate

This test starts and stops real providers. Run it only on the designated test
Mac after installing matching development profiles and preparing a non-secret
test profile:

```sh
AETHERROUTE_ALLOW_REAL_NETWORK_TEST=YES \
AETHERROUTE_SIGNED_PROFILE_READY=YES \
AETHERROUTE_NETWORK_TEST_HOST="$(scutil --get LocalHostName)" \
AETHERROUTE_SIGNED_NE_CYCLES=3 \
AETHERROUTE_SIGNED_NE_ENGINES=tun,transparent \
AETHERROUTE_SIGNED_PROBE_URL=https://canary.example/proxy-only \
AETHERROUTE_SIGNED_PROBE_SHA256=64-lowercase-hex-characters \
AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY=/absolute/new/signed-ne-evidence \
./scripts/test_signed_network_extension.sh /absolute/path/to/Signing.json
```

The wrapper refuses missing acknowledgements or the wrong host, repeats strict
preflight, validates built identifiers/signatures/entitlements before launch,
then performs bounded connect/readiness/disconnect cycles for both visible
capture engines and attempts disconnection during XCTest cleanup. Screenshots
and raw `.xcresult` data remain only in the disposable audit directory and are
deleted after the run. DerivedData cannot be redirected outside that temporary
directory. The persistent
evidence contains hashes and aggregate state only; it stores neither the
canary URL nor the test host name.
After each engine group, the wrapper also requires exact restoration of the
pre-test system proxy, DNS, IPv4/IPv6 default-route, and interface-list hash.

The canary must be an owner-controlled, credential-free HTTPS hostname whose
exact non-empty response body has the configured SHA-256 only when reached
through the prepared proxy profile. Direct access must fail or return a
different body. Each engine is therefore required to show three distinct
states: proxy-only response unavailable before connection, exact response
available after provider readiness, and unavailable again after disconnect.
The URL must have no query, fragment, user information, whitespace, localhost,
or literal loopback address. The test uses an ephemeral no-cookie, no-cache,
no-redirect session and never records the body or URL in the repository.

## Notarized release

Before production signing, the following isolated packaging smoke test builds
two ad-hoc-signed arm64 Release apps and DMGs, mounts them read-only, and checks
`1.0.0` install, `1.0.1` upgrade, `1.0.0` rollback, embedded-extension version
parity, and external profile-data preservation in a temporary root:

```sh
./scripts/test_dmg_upgrade_rollback.sh
```

It never writes `/Applications`, launches the app, starts a Network Extension,
or changes system networking. Passing it does not replace the final signed and
notarized clean-machine drill.

Store the notarization credentials with `notarytool store-credentials` under a
Keychain profile name. This is only for Apple's notarization service; no Mac
App Store, App Store Connect, Store receipt, or Store provisioning workflow is
used. Then run:

```sh
AETHERROUTE_DISTRIBUTION_MODE=free \
AETHERROUTE_SOAK_EVIDENCE_DIRECTORY=/absolute/path/to/completed-soak-evidence \
AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY=/absolute/path/to/signed-ne-evidence \
./scripts/release.sh \
  /absolute/path/to/Signing.json \
  notary-keychain-profile \
  1.0.0 \
  100 \
  /absolute/path/to/release-output
```

For the free edition, leave the license URL, update URL, and distribution
public key unset. `release.sh` defaults to `free`, matching the app project.
The explicit mode above documents the edition being packaged.
Free and licensed releases run the same signing, notarization, source,
stability, installed-runtime, and production-promotion gates.

The optional licensed release environment must explicitly set
`AETHERROUTE_DISTRIBUTION_MODE=licensed` and provide
`AETHERROUTE_LICENSE_SERVICE_URL`, `AETHERROUTE_UPDATE_MANIFEST_URL`, and the
base64 raw 32-byte Ed25519 public key in
`AETHERROUTE_DISTRIBUTION_PUBLIC_KEY`. It must also provide an absolute
`AETHERROUTE_SOAK_EVIDENCE_DIRECTORY` containing a verified schema-2 run of at
least 24 hours. The release gate requires the exact current runner, both
harnesses, and both embedded core hashes, 1,000 PacketFlow cycles per round,
at least 800 complete paired rounds, UTC boundary agreement, the production
RSS/FD limits, at most 1 MiB/hour post-warm-up RSS growth, no new exact-core
crash/hang/spin report, and no orphan process at either harness path.
It must also provide `AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY` from the exact
current source tree. That evidence must cover at least three TUN and three
Transparent Proxy connect/readiness/canary/disconnect cycles using an Apple
Development-signed XCTest runner against the Developer ID candidate, while
retaining neither the canary URL nor raw
`.xcresult` data.
The optional
`AETHERROUTE_DISTRIBUTION_PRODUCT_ID` defaults to the signed host bundle ID.

The release script produces a notarized candidate, not a production-published
update. It refuses existing output artifacts, validates exact long-soak
evidence, signing inputs, and the notary profile, then records a complete source
manifest. It reruns the
normal release regression plus direct-`xctest` Thread Sanitizer and combined
Address/Undefined Behavior Sanitizer gates in disposable DerivedData and
refuses to continue if the source manifest changes during validation. It then
creates an arm64 Release archive, rejects every Mach-O inside the app unless it
contains exactly the arm64 slice, signs the app and both extensions with
Developer ID Application, requires hardened runtime and secure timestamps,
rejects `get-task-allow`, creates and signs a DMG containing the app and
Applications link, submits it with `notarytool --wait`, requires an Accepted
result, staples and validates the ticket, runs Gatekeeper assessments against
both the DMG and mounted app, and writes a versioned SHA-256 manifest. The
manifest binds that DMG to the exact verified soak `SHA256SUMS`, schema, actual
duration, and complete round count, plus the exact dual-engine signed-runtime
evidence digest and cycle count.

The candidate manifest uses `releaseStatus: notarized-candidate` and a
`.candidate.json` suffix. It must not be served as the stable update manifest.
Production promotion remains a separate fail-closed step after the exact DMG
passes installed Developer ID TUN/Transparent Proxy, IPv4/IPv6/DNS leak,
sleep/wake, path-change, crash recovery, and clean-machine install/upgrade/
rollback gates.

After those tests create privacy-safe `metadata.txt`, `result.txt`,
`SHA256SUMS`, and the bound `installed-ne-performance` evidence directory,
validate and promote the exact candidate without uploading it:

```sh
./scripts/promote_candidate.sh \
  /absolute/AetherRoute-1.0.0-arm64.dmg \
  /absolute/AetherRoute-1.0.0-arm64.candidate.json \
  /absolute/postinstall-evidence \
  /absolute/production-approval-output
```

Promotion accepts explicit free candidates without an update verification key;
licensed candidates continue to require its exact SHA-256.
Promotion rechecks the DMG hash, code signature, stapled ticket, Gatekeeper,
and post-install evidence. The evidence requires both engines, IPv4/IPv6/DNS
leak and recovery matrices, connected CPU/RSS, throughput/latency, and UI
responsiveness budgets. It writes a `.production.json` approval manifest that
binds the candidate, exact DMG, and post-install evidence hashes. It does not
upload files or mutate the owner's update service.
Both signed-runtime and post-install evidence verifiers use strict directory
allowlists and reject extra logs, xcresult bundles, packet captures, URLs,
endpoints, tokens, or password-like values.

Installed throughput and latency use the controlled paired-measurement
contract in `InstalledNEPerformanceEvidence.md`; the isolated core's mandatory
1,024 MiB/s floor is not an installed-provider or Internet bandwidth budget.
The installed policy is currently pending calibration, which blocks promotion.
Two hand-entered throughput numbers cannot satisfy this gate. The collector,
candidate/provider identities, actual transferred bytes, timing samples and
reviewed budget must all be bound and validated.

Passing static pipeline tests proves only that the script has the expected
fail-closed gates. A production release is not proven until the exact artifact
passes signed provider tests, notarization, stapling, Gatekeeper, clean-machine
installation, upgrade/rollback, leak, sleep/wake, network-change, and soak
tests with the organization's real inputs.
