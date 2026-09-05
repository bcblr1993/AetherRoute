# Independent license and update services

The first public edition uses explicit `free` distribution and does not call
these services. Its signed DMG has no activation requirement. The following
contract applies only to optional `licensed` builds; it is retained so those
builds continue to fail closed if their configuration or receipts are invalid.

AetherRoute's independent build uses two owner-operated HTTPS endpoints and
one embedded Ed25519 public key. The matching private key remains outside the
application, repository, build logs, DMG, and diagnostics.

This document is the version 1 wire contract implemented by
`IndependentDistributionClient`. All JSON uses UTF-8. Dates use UTC RFC 3339
format, for example `2026-08-01T08:00:00Z`.

## Release configuration

Licensed builds require these inputs:

| Input | Meaning |
| --- | --- |
| `AETHERROUTE_DISTRIBUTION_MODE` | `licensed`; free releases set `free` and leave all service inputs empty |
| `AETHERROUTE_DISTRIBUTION_PRODUCT_ID` | Stable product identifier; defaults to the signed host bundle identifier |
| `AETHERROUTE_LICENSE_SERVICE_URL` | Exact HTTPS endpoint for activate, refresh, and deactivate requests |
| `AETHERROUTE_UPDATE_MANIFEST_URL` | Exact HTTPS URL of the current signed update envelope |
| `AETHERROUTE_DISTRIBUTION_PUBLIC_KEY` | Base64 raw 32-byte Ed25519 public key |

URLs must not contain credentials, fragments, or whitespace. The client does
not follow redirects and requires the final response URL to equal the embedded
URL exactly.

## Signed envelope

Every successful activation, refresh, and update response is a JSON envelope:

```json
{
  "payload": "BASE64_OF_EXACT_UTF8_JSON_BYTES",
  "signature": "BASE64_OF_64_BYTE_ED25519_SIGNATURE"
}
```

The Ed25519 signature is calculated over the decoded `payload` bytes exactly,
not over the base64 string or the outer envelope. The complete HTTP response
is limited to 64 KiB and the decoded signed payload is limited to 32 KiB. Any
invalid signature, unknown schema, mismatched product/device, oversized
response, unsafe URL, or malformed JSON fails closed.

## License endpoint

The client sends `POST AETHERROUTE_LICENSE_SERVICE_URL` with
`Content-Type: application/json` and one of these actions:

```json
{
  "schemaVersion": 1,
  "action": "activate",
  "productID": "com.example.aetherroute",
  "deviceID": "lowercase-or-uppercase-uuid",
  "appVersion": "1.0.0",
  "appBuild": "100",
  "licenseKey": "CUSTOMER-ACTIVATION-KEY",
  "signedReceipt": null
}
```

- `activate`: `licenseKey` is present and `signedReceipt` is null.
- `refresh`: `licenseKey` is null and `signedReceipt` is the base64-encoded
  complete previously returned envelope.
- `deactivate`: uses the same fields as `refresh`.

The activation key is held only for the request and is cleared from the native
UI after submission. It must never be returned inside the entitlement, saved
by the server as plaintext, written to logs, or included in analytics.

`activate` and `refresh` return HTTP 200 with a signed envelope whose decoded
payload is:

```json
{
  "schemaVersion": 1,
  "productID": "com.example.aetherroute",
  "licenseID": "non-secret-stable-license-id",
  "deviceID": "same-uuid-as-request",
  "state": "active",
  "issuedAt": "2026-08-01T08:00:00Z",
  "expiresAt": null
}
```

`state` is one of `active`, `expired`, `revoked`, or `deviceLimit`.
`expiresAt` may be null for a perpetual entitlement. `deactivate` returns HTTP
204 with an empty body only. Other status codes are treated as failures; the
service should use generic responses that do not disclose whether a key or
license exists.

The app stores only a random device UUID and the complete signed receipt in
the non-synchronizing Data Protection Keychain using
after-first-unlock-this-device-only accessibility.

When all release service values are absent, development builds remain
unrestricted. Once a release configures the service and public key, the host
allows a new Transparent Proxy or TUN session only for a locally verified,
active, unexpired receipt. The same gate covers the main window, menu-bar
control, global shortcut, and a pre-existing system VPN session discovered at
launch. A newly signed `expired`, `revoked`, or `deviceLimit` state stops an
active session. After the user accepts the network disclosure, a configured
build refreshes a stored receipt at launch and every 24 hours while the app is
running. A transient refresh or deactivation network failure preserves the
last locally verified unexpired receipt and shows a service warning; it does
not falsely revoke or disconnect an offline customer.

## Update endpoint

The client sends `GET AETHERROUTE_UPDATE_MANIFEST_URL` with no cookie or cache.
HTTP 200 must contain a signed envelope whose decoded payload is:

```json
{
  "schemaVersion": 1,
  "productID": "com.example.aetherroute",
  "version": "1.0.1",
  "build": 101,
  "publishedAt": "2026-08-01T08:00:00Z",
  "minimumSystemVersion": "15.0",
  "architecture": "arm64",
  "downloadURL": "https://downloads.example.com/AetherRoute-1.0.1-arm64.dmg",
  "sha256": "64-lowercase-hex-characters",
  "releaseNotesURL": "https://downloads.example.com/releases/1.0.1"
}
```

The client accepts numeric `major.minor` or `major.minor.patch` versions,
positive builds, `arm64` only, HTTPS download/release-note URLs, and lowercase
SHA-256. It offers a native save panel only when the signed build number is
newer. The DMG download rejects redirects, cookies, caching, non-200 responses,
non-DMG destinations, empty/non-regular files, and artifacts larger than 512
MiB. It streams the SHA-256 from disk, verifies the temporary download, copies
to a hidden sibling, verifies again, atomically replaces the user-approved
destination, verifies the final file, and then reveals it in Finder. It never
silently installs, mounts, or executes downloaded content.

## Service and key operations

- Rate-limit activation per account, key, device, and network without logging
  plaintext activation keys.
- Store activation keys as slow password hashes or keyed server-side digests.
- Keep the Ed25519 private key in a restricted signing service or offline
  release environment; the web API does not need direct access if receipts are
  issued by a separate signer.
- Back up the signing key securely and document an explicit public-key rotation
  release. Version 1 embeds one public key, so rotating it requires shipping an
  app update signed by the previous trusted release process.
- Publish the notarized, stapled DMG first, verify its SHA-256, then sign and
  atomically publish the update payload/envelope last.
- Do not use HTTP redirects for either configured endpoint. CDN download URLs
  may redirect only after the user has explicitly opened them in the browser;
  AetherRoute itself validates the signed original HTTPS URL.

Static client tests prove parsing, binding, streaming response limits,
redirect and signature behavior, fail-closed connection access, and atomic
DMG SHA-256 verification including existing-file replacement. The
IPv4-loopback-only reference staging drill additionally proves the exact JSON
wire shape, active activation, refresh-to-revoked, device-limit restriction,
deactivation, generic unknown-key behavior, and signed arm64 update manifest
over real HTTP transport. The deployable Go service in
`Services/DistributionService` additionally passes race detection, static
Linux arm64 compilation, separate Unix-socket signer operation, private
state/activation-digest checks, and black-box interoperability with the real
Swift client. Production readiness still requires the same drill
against an externally hosted HTTPS staging deployment and verification against
the exact notarized DMG SHA-256. The isolated
`scripts/test_dmg_upgrade_rollback.sh` gate separately builds two unsigned
arm64 Release DMGs and passes temporary-root install, upgrade, rollback, and
external profile-data preservation. It never writes `/Applications`, launches
the app, or starts a Network Extension, so the equivalent Developer-ID-signed
clean-machine drill remains release-blocking.

Generate the update envelope from the exact notarized DMG using an external
mode-400 or mode-600 raw 32-byte Ed25519 private key:

```sh
AETHERROUTE_DISTRIBUTION_PUBLIC_KEY='base64-public-key' \
./scripts/generate_update_envelope.sh \
  /absolute/private-key.raw \
  /absolute/AetherRoute-1.0.1-arm64.dmg \
  com.example.aetherroute \
  1.0.1 \
  101 \
  2026-08-01T08:00:00Z \
  15.0 \
  https://downloads.example.com/AetherRoute-1.0.1-arm64.dmg \
  https://downloads.example.com/releases/1.0.1 \
  /absolute/AetherRoute-1.0.1-arm64.update.json
```

The generator rejects a key stored inside the repository, mismatched embedded
public key, insecure key permissions, unsafe URLs, invalid metadata, and
existing output. It derives the SHA-256 directly from the supplied DMG and
verifies the final envelope byte-for-byte before returning success.
