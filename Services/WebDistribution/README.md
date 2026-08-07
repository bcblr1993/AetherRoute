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

After deployment, verify the public HTTPS surface and full downloaded artifact
hash with `scripts/verify_distribution_web.sh`. An operator-initiated rollback
uses `scripts/rollback_distribution_web.sh`, which resolves the immutable
`PREVIOUS` pointer, validates that release, waits for a healthy replacement,
and only then changes `current`.

The current public package is clearly labeled as a technical preview. Never
rename it to Stable or publish `current.update.json` until the exact production
DMG has passed every gate in `Docs/ReleaseGates.md` and the envelope was signed
from that final DMG.
