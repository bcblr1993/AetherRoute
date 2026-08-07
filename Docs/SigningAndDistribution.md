# Developer ID signing and independent distribution

AetherRoute is distributed as a notarized DMG outside the Mac App Store. No
Store target, Store receipt, App Store Connect upload, or Store provisioning
profile is part of the product.

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
profiles: host, Transparent Proxy system extension, and Packet Tunnel system
extension. The host profile must authorize System Extension installation. Both
the host and provider profiles must grant the Developer ID forms
`app-proxy-provider-systemextension` and/or
`packet-tunnel-provider-systemextension` that match their role. Never place
certificates, private keys, passwords, notary credentials, or the completed
JSON in the repository.

Because this product uses the registered `group.` App Group form, assign the
same App Group to all three explicit App IDs before generating the profiles.
Every profile must contain that exact
`com.apple.security.application-groups` value. A profile that signs or
notarizes successfully but omits the App Group is rejected by the production
preflight because the host and both providers would not have a validated
shared container at runtime.

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

Development builds intentionally use the standard Network Extension values.
Release builds switch to dedicated Developer ID entitlement files with the
`-systemextension` suffix. Both providers are packaged under
`Contents/Library/SystemExtensions`; direct distribution must not revert them
to App Extensions under `Contents/PlugIns`. Xcode 26 and earlier cannot export
this combination correctly through Organizer, so `scripts/release.sh` performs
the validated manual Developer ID archive and signing path. Xcode 27 or later
may remove that tooling limitation, but the entitlement and packaging checks
remain release gates.

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

## Notarized cross-machine test candidate

Use the dedicated test-candidate builder when a signed, notarized DMG is needed
for manual installation on another Apple-silicon Mac before production gates
are complete:

```sh
./scripts/build_notarized_test_candidate.sh \
  /absolute/path/to/Signing.json \
  notary-keychain-profile \
  0.1.0 \
  2026080703 \
  /absolute/new/test-candidate-output
```

The builder uses disposable DerivedData, requires the three Developer ID
profiles, verifies the host and both embedded Network Extensions, enforces
arm64-only Mach-O files, creates and signs a DMG, waits for Apple notarization,
staples the ticket, and runs Gatekeeper checks against both the DMG and mounted
app. It also compares system proxy, DNS, default routes, and interfaces before
and after the build. It never installs or launches the app and never activates
a Network Extension. Output is explicitly marked
`notarized-test-candidate`; it is not valid production or update-manifest
evidence and does not bypass the gates below.

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
AETHERROUTE_SOAK_EVIDENCE_DIRECTORY=/absolute/path/to/completed-soak-evidence \
AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY=/absolute/path/to/signed-ne-evidence \
./scripts/release.sh \
  /absolute/path/to/Signing.json \
  notary-keychain-profile \
  1.0.0 \
  100 \
  /absolute/path/to/release-output
```

The stable release environment must also provide
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
Transparent Proxy connect/readiness/canary/disconnect cycles under an Apple
Development signature, while retaining neither the canary URL nor raw
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
evidence digest and cycle count. It also records the signed host product ID,
numeric build, minimum macOS version from the archived app, frozen Git commit,
complete source-manifest SHA-256, and SHA-256 of the Ed25519 update
verification key embedded in that app.

The candidate manifest uses `releaseStatus: notarized-candidate` and a
`.candidate.json` suffix. It must not be served as the stable update manifest.
Production promotion remains a separate fail-closed step after the exact DMG
passes installed Developer ID TUN/Transparent Proxy, IPv4/IPv6/DNS leak,
sleep/wake, path-change, crash recovery, and clean-machine install/upgrade/
rollback gates.

After those tests create privacy-safe `metadata.txt`, `result.txt`, and
`SHA256SUMS`, validate and promote the exact candidate without uploading it:

```sh
./scripts/promote_candidate.sh \
  /absolute/AetherRoute-1.0.0-arm64.dmg \
  /absolute/AetherRoute-1.0.0-arm64.candidate.json \
  /absolute/postinstall-evidence \
  /absolute/production-approval-output
```

Promotion rechecks the DMG hash, code signature, stapled ticket, Gatekeeper,
the frozen Git/source manifest, and post-install evidence. The evidence
requires both engines, IPv4/IPv6/DNS
leak and recovery matrices, connected CPU/RSS, throughput/latency, and UI
responsiveness budgets. It writes a `.production.json` approval manifest that
binds the candidate, exact DMG, and post-install evidence hashes. It does not
upload files or mutate the owner's update service.

After creating the signed update envelope, use the stable web deploy command
documented in `Services/WebDistribution/README.md`. That command accepts all
four release-chain inputs rather than a directory of loosely related files.
It will not expose an update endpoint or label a release Stable unless the
candidate, production approval, DMG, source, embedded public key, and decoded
update payload all describe exactly the same product/version/build. The server
pointer changes only after health and public download/signature verification.
Both signed-runtime and post-install evidence verifiers use strict directory
allowlists and reject extra logs, xcresult bundles, packet captures, URLs,
endpoints, tokens, or password-like values.

Passing static pipeline tests proves only that the script has the expected
fail-closed gates. A production release is not proven until the exact artifact
passes signed provider tests, notarization, stapling, Gatekeeper, clean-machine
installation, upgrade/rollback, leak, sleep/wake, network-change, and soak
tests with the organization's real inputs.
