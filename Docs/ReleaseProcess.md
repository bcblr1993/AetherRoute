# Release process

AetherRoute uses Semantic Versioning tags. Development snapshots use tags such
as `v0.1.0-alpha.1`; beta builds use `v0.1.0-beta.1`; production releases use
`vMAJOR.MINOR.PATCH` without a prerelease suffix.

## Pull request and source freeze

1. Merge a focused pull request to `main` using squash merge.
2. Update `CHANGELOG.md`, `MARKETING_VERSION`, build number, release channel,
   and UTC release timestamp. The release pipeline must run from a clean
   `main` checkout; a feature branch, detached source snapshot, staged change,
   or untracked file is rejected.
3. Verify the embedded-core submodule commit and all license notices.
4. Run repository CI, the complete native regression, sanitizers, UI matrix,
   accessibility checks, isolated protocol interoperability, and the exact
   current 24-hour soak verification.
5. Freeze the source commit. Any source change invalidates runtime, soak, UI,
   and candidate evidence tied to the previous commit.

## Candidate and production promotion

1. Run `scripts/signing_preflight.sh` on the designated signing Mac.
2. Run the Developer ID pipeline for the frozen arm64 source.
3. Verify hardened-runtime signatures for the host and both extensions,
   notarization, stapling, Gatekeeper, installed TUN and Transparent Proxy
   cycles, leak/recovery behavior, performance, UI responsiveness, and a clean
   second Mac.
4. Promote only the exact verified DMG with `scripts/promote_candidate.sh`.
5. Generate the Ed25519 update envelope from the exact promoted DMG, using the
   promotion `approvedAt` value as `publishedAt` and the immutable owner-hosted
   download and release-notes URLs.
6. Run `scripts/deploy_distribution_web.sh ... stable ...` with the exact DMG,
   candidate manifest, production manifest, and update envelope. The deployer
   regenerates the stable website in a temporary directory and refuses any
   product, source, key, candidate, artifact, URL, or signature mismatch.
7. Publish the annotated tag and GitHub release only after the public HTTPS
   verifier downloads the complete DMG, matches SHA-256, verifies the live
   update envelope, and atomically activates the new immutable server release.
   Never replace an asset for an existing tag; publish a new patch or
   prerelease version.

The repository may publish a source-only prerelease while production signing
inputs are unavailable. Such a release must be marked as a prerelease, must not
attach an unsigned DMG, and must explicitly list every open production gate.

## GitHub release notes

Every release states:

- highlights and user-visible changes;
- supported macOS version and Apple Silicon requirement;
- protocol/import compatibility changes;
- security and privacy changes;
- known issues and migration notes;
- exact verification status and checksum links.

GitHub releases are created from annotated version tags. Stable releases are
never created from a dirty tree, a feature branch, or an unsigned preview.
