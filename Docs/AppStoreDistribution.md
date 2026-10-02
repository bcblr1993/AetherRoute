# Mac App Store distribution

The Store channel is generated separately from the Developer ID project by
`scripts/generate_app_store_project.py`. Generated projects, entitlements,
profiles and packages live in ignored local output directories. The standard
website release scripts and their independent-distribution guard remain the
Developer ID path.

The first Store candidate is 1.1.2/build 2026100203. It retains both packet
tunnel and transparent proxy system extensions. It is free, has no activation
requirement, and excludes Sparkle, its metadata, updater controls and Mach
lookup exceptions. Both channels share the production network core.

The Store graph retains `AETHERROUTE_INDEPENDENT` to preserve the existing
dual-engine routing code and adds `AETHERROUTE_APP_STORE` to select the Store
updater boundary. Its signed host and both providers require explicit Mac
App Store profiles authorizing their identifiers, team, groups and certificate.
The desktop KVS entitlement is omitted, as in the production Developer ID host,
because neither production profile grants it.

The user explicitly requested attempting submission with the current individual
developer membership on 2026-10-02 after the VPN organization requirement was
explained. This is a submission choice, not evidence of App Review approval.
Do not hide the TUN/VPN function or imply that changing a listing category
changes Apple's eligibility rules.

Validation evidence belongs in the corresponding output directory. An existing
Developer ID release, unsigned build, or signed package does not establish
Store runtime acceptance, a successful upload, or review approval. Record each
of these stages separately, including any failed gates or exceptions.

References: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
and [TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).

## Build and audit

Run `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_app_store_project.py`, then
create a new output directory with the three exact Mac App Store profile UUIDs:

```sh
python3 scripts/generate_app_store_project.py outputs/store-candidate/project \
  --team "$TEAM_ID" --version "$VERSION" --build "$BUILD" \
  --identity "$STORE_APPLICATION_IDENTITY" \
  --host-profile "$HOST_PROFILE_UUID" \
  --tunnel-profile "$TUNNEL_PROFILE_UUID" \
  --transparent-profile "$TRANSPARENT_PROFILE_UUID"
xcodebuild -project outputs/store-candidate/project/AetherRouteAppStore.xcodeproj \
  -scheme AetherRoute -configuration Release \
  -archivePath outputs/store-candidate/AetherRoute.xcarchive archive
python3 scripts/audit_app_store_bundle.py \
  outputs/store-candidate/AetherRoute.xcarchive/Products/Applications/AetherRoute.app \
  --team "$TEAM_ID" --certificate "$STORE_APPLICATION_CERTIFICATE_SHA1" \
  --output outputs/store-candidate/store-audit.json
```

Audit the normal core and license coverage before export. Use a local
`ExportOptions.plist` with method `app-store-connect`, manual signing, the
exact team, Store application and installer certificates, all three profile mappings, and
`manageAppVersionAndBuildNumber=false`. Export with `xcodebuild -exportArchive`;
use `destination=upload` and `-allowProvisioningUpdates` to upload through the
existing Xcode account. Keep signing profiles and export options outside Git.
Package export, upload success, processed build selection, final review
submission and public release are distinct results.

## First submission result

On 2026-10-02 at 22:54 CST, Apple accepted submission
`8553c26f-9fef-4c18-8f86-5d0d95204434` for **AetherRoute for Mac**
(App Store Connect ID `6818543727`), version 1.1.2/build 2026100203.
The live observed status was **Waiting for Review**. Release is automatic after
approval, the price is free, and availability covers 174 territories. France
was excluded because the required encryption authorization document was not
available; the use of third-party standard cryptography was disclosed.

The four required local regression suites, Store graph regressions, exact
Store bundle audit, normal-core/license checks and installer signature passed.
Xcode reported only skipped AppIntents metadata extraction for targets that
have no AppIntents dependency; this was not represented as a zero-warning build.
VM runtime acceptance remains incomplete: the matrix stopped before scoring
because `macos27` did not have a logged-in graphical session. See
[the Store validation exception](ReleaseExceptions/1.1.2-app-store.md).
The listing reuses an existing public 1.1.0 overview with its original version
label and UI pixels intact; it is marketing material, not Store runtime proof.
The VM was restored to its original formal 1.1.2/build 2026100202 installation
and only this task's temporary files were removed. Detailed logs, signing audit,
submission record and the Apple status screenshot are retained locally under
`outputs/app-store-1.1.2-2026100203`.

The physical Apple Silicon fast gate passed at 23:07 CST with source/payload
hashes and system proxy, DNS, default routes and interfaces unchanged. Its
evidence is `outputs/test-evidence/remote-arm64-20261002T143830Z-fast`. This
source regression result does not establish Store-installed extension runtime.
The remote task temporary directory was verified removed after completion.
