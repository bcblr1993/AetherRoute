# AetherRoute web distribution

This directory is the versioned, owner-operated public website and static
distribution surface for AetherRoute. It deliberately separates three HTTPS
hosts:

- `aetherroute.baizhiedu.xin`: product, release, privacy, support, and license
  pages;
- `downloads.baizhiedu.xin`: immutable notarized DMGs and checksums;
- `updates.baizhiedu.xin`: the no-redirect `/v1/update` endpoint for optional
  licensed builds; free releases leave it empty and verify an HTTP 404.

The Nginx service is non-root, read-only, has no published host port, emits no
access log, and is reachable only through the existing Traefik `proxy` overlay
network. Every Swarm task binds an immutable release directory; the `current`
symlink is updated only after the replacement task is healthy. A failed Swarm
update rolls its complete service specification back automatically.

The deploy command has explicit `preview` and `stable` channels. A preview is
never copied into `/releases/<version>` and never creates the update endpoint.
Its DMG, candidate manifest, source manifest, README, and `SHA256SUMS` are
validated and published together; the checksum file is never allowed to name
an omitted download. Public verification downloads the complete audit set,
compares it with the local candidate, and rolls back if any file is absent or
different:

Preview preparation reads the selected candidate's version, build, size and
SHA-256 instead of relying on a fixed release name. It accepts exactly five
audited files from a normal-core, non-diagnostic notarized test candidate.
The exact DMG and mounted app must pass signing and stapler validation; app
and extension versions, CDHashes and executable hashes must match the manifest.
The signed app must explicitly use free distribution and contain no licensing,
automatic-update or update-signing-key configuration. The preparer never launches
the app or activates a Network Extension.

Each preview publishes its five files at `/prerelease/build-<build>/`, so
immutable caching cannot reuse a previous build's `SHA256SUMS` or audit files.
The generated homepage and `/releases/<version>-beta-<build>/` notes bind to that
exact directory and remain labeled Beta with `productionApproved: false`.
Historical notes retain their original facts but omit obsolete preview download
links. The verifier keeps compatibility with the old flat `/prerelease/` audit
path; new deployments always use the build-specific directory. When a candidate
folder also contains personal usage notes, copy only the original five audited
files to a new input folder and verify their checksums; do not modify the frozen
candidate or its checksum file.

```sh
./scripts/deploy_distribution_web.sh \
  chenyn@www.baizhiedu.xin preview \
  /absolute/notarized-preview-directory web-preview-unique-id
```

A stable deployment accepts only the complete, exact release chain. The first
public edition is free and does not require an update envelope or an update
signing key:

```sh
./scripts/deploy_distribution_web.sh \
  chenyn@www.baizhiedu.xin stable \
  /absolute/AetherRoute-1.0.0-arm64.dmg \
  /absolute/AetherRoute-1.0.0-arm64.candidate.json \
  /absolute/AetherRoute-1.0.0-arm64.production.json
```

The production and candidate manifests must both identify `free` distribution.
Do not set `AETHERROUTE_DISTRIBUTION_PUBLIC_KEY` or pass an update envelope for
this edition. Users update by installing a newer signed DMG; their saved
profiles remain available.

Optional licensed releases use the same command with an additional absolute
path to `current.update.json`, and require `AETHERROUTE_DISTRIBUTION_PUBLIC_KEY`
to contain the non-secret Ed25519 key embedded in that signed application.

Stable preparation verifies the production approval against the byte-for-byte
candidate manifest, frozen Git commit, complete source manifest, DMG hash,
byte count and product ID. Licensed releases also validate the update-signing
key and decoded signed update payload. It then generates the stable home page, release history entry, versioned
release notes, immutable download directory and checksums in a temporary
directory. Only licensed releases include a no-cache update envelope. The
checked-in website remains a truthful preview until this exact production
chain exists.

The replacement Swarm task must become healthy and the public verifier must
download the complete DMG and match SHA-256 before `current` is changed. It
also verifies an empty update endpoint (HTTP 404) for free releases or the live
Ed25519 update envelope (HTTP 200) for licensed releases. A failed public
verification rolls the service back and leaves the previous pointer active. An operator-initiated
rollback uses `scripts/rollback_distribution_web.sh`, which resolves the
immutable `PREVIOUS` pointer, validates that release, waits for a healthy
replacement, and only then changes `current`.

The current public package is clearly labeled as a technical preview. Never
rename it to Stable or publish `current.update.json` until the exact production
DMG has passed every gate in `Docs/ReleaseGates.md`. A licensed update envelope
must additionally be signed from that final DMG.
