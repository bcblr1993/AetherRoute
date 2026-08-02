#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/promote_candidate.sh"

sh -n "$SCRIPT"
if "$SCRIPT" >/dev/null 2>&1; then
  echo "promotion script accepted missing inputs" >&2
  exit 1
fi
for required in \
  'releaseStatus == "notarized-candidate"' \
  'scripts/verify_postinstall_evidence.sh' \
  'codesign --verify' \
  'xcrun stapler validate' \
  'spctl --assess --type open' \
  'candidate DMG SHA-256 does not match' \
  '.releaseStatus = "production-approved"' \
  'candidateManifestSHA256' \
  'postInstallEvidenceSHA256' \
  'No upload or update-service mutation was performed.'
do
  grep -F "$required" "$SCRIPT" >/dev/null || {
    echo "production promotion pipeline is missing gate: $required" >&2
    exit 1
  }
done
if grep -Eq '(^|[[:space:]])(curl|scp|rsync|aws|rclone)[[:space:]]' "$SCRIPT"; then
  echo "promotion must not upload or mutate the update service" >&2
  exit 1
fi

echo "Production promotion pipeline static tests passed."
