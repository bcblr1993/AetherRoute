# Owner-operated distribution service deployment

`Services/DistributionService` is AetherRoute's deployable reference service
for independent licensing and signed updates. It uses only the Go standard
library, builds as a static Linux arm64 binary, and implements the exact
version 1 contract consumed by the native Swift client.

This service is not embedded in the app or DMG. It belongs on infrastructure
controlled by the product owner.

## Security architecture

Run two processes under separate Unix accounts:

1. `aetherroute-distribution signer` owns the mode-400 or mode-600 raw 32-byte
   Ed25519 seed. It accepts only canonical entitlement payloads for the exact
   configured product over a mode-600 Unix socket.
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

```sh
./scripts/test_distribution_service.sh

cd Services/DistributionService
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
  -buildvcs=false -trimpath -ldflags='-s -w' \
  -o /absolute/output/aetherroute-distribution \
  ./cmd/aetherroute-distribution
```

The repository gate runs Go vet and race tests, creates a stripped static
Linux arm64 executable, starts the signer and Web processes on a private Unix
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
- private Unix-socket directory shared only where required by the two service
  accounts.

The state and socket parent directories must already exist with mode 700. The
service canonicalizes their paths, rejects final-component symlinks for secret,
state, and lock files, and bounds state-file reads. Keep the signer socket path
short (for example under `/run/aetherroute`) because Unix-domain socket path
limits are much smaller than normal filesystem path limits.

Back up the seed, pepper, and state separately with encryption and restore
drills. Losing the seed prevents signing new receipts; losing the pepper makes
existing activation keys unresolvable; losing state removes license/device
history. Public-key rotation requires a signed app release carrying the new
public key.

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
  -socket /absolute/private-runtime/receipt-signer.sock

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

## Remaining production evidence

Local black-box verification is not public-service proof. Before release, run
the same native-client drill against the final owner HTTPS staging host, verify
TLS and no-redirect behavior, exercise backup/restore and signer-unavailable
failure paths, load-test the chosen deployment topology, and bind the final
payment/customer system to issuance and revocation. The signing seed and
license pepper must never be sent to the app-signing machine unless the owner
has explicitly designed that trust boundary.
