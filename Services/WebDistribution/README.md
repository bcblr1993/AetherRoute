# AetherRoute web distribution

This directory is the versioned, owner-operated public website and static
distribution surface for AetherRoute. It deliberately separates three HTTPS
hosts:

- `aetherroute.baizhiedu.xin`: product, release, privacy, support, and license
  pages;
- `downloads.baizhiedu.xin`: immutable notarized DMGs and checksums;
- `updates.baizhiedu.xin`: the exact no-redirect `/v1/update` signed envelope.

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

```sh
./scripts/deploy_distribution_web.sh \
  chenyn@www.baizhiedu.xin preview \
  /absolute/notarized-preview-directory web-preview-unique-id
```

A stable deployment accepts only the complete, exact release chain. The public
key is the same non-secret Ed25519 key embedded in the signed application:

```sh
AETHERROUTE_DISTRIBUTION_PUBLIC_KEY='base64-public-key' \
./scripts/deploy_distribution_web.sh \
  chenyn@www.baizhiedu.xin stable \
  /absolute/AetherRoute-1.0.0-arm64.dmg \
  /absolute/AetherRoute-1.0.0-arm64.candidate.json \
  /absolute/AetherRoute-1.0.0-arm64.production.json \
  /absolute/current.update.json
```

Stable preparation verifies the production approval against the byte-for-byte
candidate manifest, frozen Git commit, complete source manifest, DMG hash and
byte count, product ID, update-signing key, and decoded signed update payload.
It then generates the stable home page, release history entry, versioned
release notes, immutable download directory, checksums, and no-cache update
endpoint in a temporary directory. The checked-in website remains a truthful
preview until this exact production chain exists.

The replacement Swarm task must become healthy and the public verifier must
download the complete DMG, match SHA-256, and verify the live Ed25519 update
envelope before `current` is changed. A failed public verification rolls the
service back and leaves the previous pointer active. An operator-initiated
rollback uses `scripts/rollback_distribution_web.sh`, which resolves the
immutable `PREVIOUS` pointer, validates that release, waits for a healthy
replacement, and only then changes `current`.

The current public package is clearly labeled as a technical preview. Never
rename it to Stable or publish `current.update.json` until the exact production
DMG has passed every gate in `Docs/ReleaseGates.md` and the envelope was signed
from that final DMG.
