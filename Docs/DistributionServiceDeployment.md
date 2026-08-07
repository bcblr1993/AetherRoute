# Owner-operated distribution service deployment

`Services/DistributionService` is AetherRoute's deployable reference service
for independent licensing and signed updates. It uses only the Go standard
library, builds as a static Linux arm64 or amd64 binary, and implements the exact
version 1 contract consumed by the native Swift client.

This service is not embedded in the app or DMG. It belongs on infrastructure
controlled by the product owner.

## Security architecture

Run two processes under separate Unix accounts:

1. `aetherroute-distribution signer` owns the mode-400 or mode-600 raw 32-byte
   Ed25519 seed. It accepts only canonical entitlement payloads for the exact
   configured product over a mode-600 Unix socket. When the Web process runs
   as a separate account, `-socket-group` changes only that socket to mode 660
   for one dedicated shared group; it never broadens access to the seed.
2. `aetherroute-distribution serve` owns the license store pepper, public key,
   signed update envelope, and license state. It has no signing private key and
   listens only on an explicit loopback IP.

Place an owner-managed TLS reverse proxy in front of the loopback Web process.
Expose only the exact `/v1/license` and `/v1/update` paths without redirects.
Do not terminate plain HTTP on a public interface. The service intentionally
rejects non-loopback listen addresses so that this boundary cannot be disabled
by a deployment typo.

The service enforces a bounded global/source window plus keyed device and
activation-digest windows. Because the default source is the loopback proxy,
production deployments may add `-trust-forwarded-for` only when that proxy
overwrites `X-Forwarded-For` with exactly one validated client IP. Forwarding
chains, malformed values, and untrusted headers fall back to the loopback
identity. Do not enable the option when clients can preserve or append their
own forwarding header.

Activation keys are generated with cryptographic randomness and written to
standard output once by the `issue` command. The state file contains only an
HMAC-SHA256 digest keyed by a separate 32-byte pepper. The Web handler uses
generic rejection bodies and neither process logs requests, activation keys,
receipts, device identifiers, or entitlement payloads.

## Build and isolated verification

The module keeps Go 1.24 language compatibility while pinning the production
compiler to the exact security-patched toolchain declared by the `toolchain`
line in `go.mod`. CI fails if it uses a different patch release or if the
official Go vulnerability database reports a reachable vulnerability.

```sh
./scripts/test_go_vulnerabilities.sh
./scripts/test_distribution_service.sh

cd Services/DistributionService
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
  -buildvcs=false -trimpath -ldflags='-s -w' \
  -o /absolute/output/aetherroute-distribution \
  ./cmd/aetherroute-distribution
```

The repository gate runs Go vet and race tests, creates stripped static Linux
arm64 and amd64 executables, generates keys and an update envelope through the
production CLI, starts the signer and Web processes on a private Unix
socket and random IPv4 loopback port, verifies file/listener permissions, and
runs the actual Swift `IndependentDistributionClient` through activation,
refresh, signed-update validation, deactivation, and fail-closed refresh. It
does not modify the Mac's proxy, DNS, routes, or Network Extension state.

## External secret and state inputs

Create these directly on the service hosts; do not put them in Git, chat,
shell history, CI logs, or a DMG:

- raw 32-byte Ed25519 seed, readable only by the signer account;
- matching raw 32-byte public key, readable by the Web account;
- independent random 32-byte license-store pepper, readable only by the Web
  account;
- private state directory and `licenses.json`, owned by the Web account;
- private Unix-socket directory owned by the signer, group-owned by the one
  shared service group, and mode 710. The Web account receives only that group
  and can traverse to the known socket name without listing or modifying the
  directory.

The state parent directory must already exist with mode 700. A same-account
signer socket parent may also be 700; a split-account deployment uses exactly
710, never group-write or any access for other users. The service canonicalizes
paths, rejects final-component symlinks for secret, state, and lock files, and
bounds state-file reads. Keep the signer socket path short (for example under
`/run/aetherroute`) because Unix-domain socket path limits are much smaller than
normal filesystem path limits.

Back up the seed, pepper, and state separately with encryption and restore
drills. Losing the seed prevents signing new receipts; losing the pepper makes
existing activation keys unresolvable; losing state removes license/device
history. Public-key rotation requires a signed app release carrying the new
public key.

Use the production CLI rather than shell redirection or ad-hoc random-file
commands. Each output path must be absolute, its parent must already be mode
700, and the final component must not exist. The commands use exclusive,
no-follow creation and never print secret bytes:

```sh
aetherroute-distribution keygen \
  -seed /absolute/signer/ed25519-seed.raw \
  -public-key /absolute/signer/ed25519-public.raw

aetherroute-distribution generate-pepper \
  -output /absolute/service/license-pepper.raw
```

Copy the raw public key to the Web account with an owner-controlled install
step. Do not give the Web account traverse or read access to the signer seed
directory.

## Administrative operations

The examples below use placeholders only. All paths must be absolute.

```sh
# Issue a perpetual one-device license. The activation key is shown once.
aetherroute-distribution issue \
  -product-id PRODUCT_ID \
  -state /absolute/private/licenses.json \
  -pepper /absolute/private/license-pepper.raw \
  -max-devices 1

# Issue a time-limited license using a future UTC RFC3339 timestamp.
aetherroute-distribution issue \
  -product-id PRODUCT_ID \
  -state /absolute/private/licenses.json \
  -pepper /absolute/private/license-pepper.raw \
  -max-devices 3 \
  -expires-at 2027-08-01T00:00:00Z

# List non-secret license summaries, or revoke/reactivate by license ID.
aetherroute-distribution list \
  -product-id PRODUCT_ID \
  -state /absolute/private/licenses.json \
  -pepper /absolute/private/license-pepper.raw
aetherroute-distribution set-state \
  -product-id PRODUCT_ID \
  -state /absolute/private/licenses.json \
  -pepper /absolute/private/license-pepper.raw \
  -license-id LICENSE_ID -new-state revoked
```

Payment and customer-account systems should call a narrow privileged issuance
worker rather than execute administrative commands from the public Web
process. Payment-provider webhook verification, refunds, invoices, account
recovery, customer portal, tax handling, and abuse policy are deliberately
outside this repository until the owner selects those external systems.

## Runtime processes

```sh
aetherroute-distribution signer \
  -product-id PRODUCT_ID \
  -seed /absolute/signer/ed25519-seed.raw \
  -socket /absolute/private-runtime/receipt-signer.sock \
  -socket-group aetherroute-service

aetherroute-distribution serve \
  -product-id PRODUCT_ID \
  -state /absolute/private/licenses.json \
  -pepper /absolute/private/license-pepper.raw \
  -public-key /absolute/config/ed25519-public.raw \
  -update-envelope /absolute/public/current.update.json \
  -signer-socket /absolute/private-runtime/receipt-signer.sock \
  -listen 127.0.0.1:9080 \
  -trust-forwarded-for
```

Use a process supervisor with separate users, read-only filesystem access
except for the exact state/socket directories, a memory limit, restart policy,
and health monitoring performed through the loopback listener. Deploy the
signed update envelope atomically only after the exact notarized and stapled
DMG is available at its final HTTPS URL and its SHA-256 matches the signed
manifest.

Generate that envelope directly from the final DMG. The command streams the
artifact into SHA-256, validates every manifest field, creates a canonical
Ed25519 envelope, verifies its own signature, and refuses to replace an
existing output:

```sh
aetherroute-distribution sign-update \
  -product-id PRODUCT_ID \
  -seed /absolute/signer/ed25519-seed.raw \
  -dmg /absolute/releases/AetherRoute-1.0.0-arm64.dmg \
  -version 1.0.0 -build 100 \
  -published-at 2026-08-07T00:00:00Z \
  -minimum-system 15.0 \
  -download-url https://downloads.example/releases/1.0.0/AetherRoute-1.0.0-arm64.dmg \
  -release-notes-url https://example/releases/1.0.0/ \
  -output /absolute/private/current.update.json
```

## Owner staging operations

The checked deployment assets run signer and Web under separate numeric users,
drop all capabilities, use read-only container roots, apply `NoNewPrivs`, and
wait for the exact immutable image tag to become healthy before verification.
Each immutable release also retains a bounded SHA-256 source manifest and binds
its digest into `metadata.json`; activation rejects either an image-ID or source
manifest mismatch.
The public verifier uses the native Swift client rather than a synthetic JSON
decoder. The operational and rollback gates are explicit because they scale the
staging signer and switch immutable staging releases:

```sh
./scripts/test_distribution_service_operations.sh OWNER@HOST
./scripts/rollback_distribution_service.sh OWNER@HOST TARGET_STAGING_RELEASE
```

The operations gate requires signer-unavailable activation to fail with 503,
restores the signer before continuing, exercises activation and deactivation,
checks exact 405/404 boundaries, mutates and restores only a private state
clone, performs a bounded 200-request read test at concurrency 8, and rejects
client request metadata in the current Web task log. The rollback gate deploys
the exact recorded target image ID, repeats the native signed lifecycle, and
changes the `current` pointer only after public verification. Failure restores
the previous exact release before removing private verification material.

## Remaining production evidence

The owner HTTPS staging, signer-unavailable, isolated state restore, bounded
read load, and immutable rollback paths have been exercised. Before charging
customers, bind the selected payment/customer system to a narrow issuance and
revocation worker and complete an encrypted off-host backup and restore drill
for the signer seed, license pepper, and state together. Repeat the native
public verifier with the exact final notarized DMG and stable update envelope.
The signing seed and license pepper must never be sent to the app-signing
machine unless the owner has explicitly designed that trust boundary.
