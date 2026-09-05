#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DMG=${1:-}
CANDIDATE_MANIFEST=${2:-}
POSTINSTALL_EVIDENCE=${3:-}
OUTPUT_DIRECTORY=${4:-}

usage() {
  echo "usage: promote_candidate.sh /absolute/AetherRoute-version-arm64.dmg /absolute/AetherRoute-version-arm64.candidate.json /absolute/postinstall-evidence /absolute/output-directory" >&2
}

for path in "$DMG" "$CANDIDATE_MANIFEST" "$POSTINSTALL_EVIDENCE" "$OUTPUT_DIRECTORY"; do
  case "$path" in /*) ;; *) usage; exit 64 ;; esac
done
test -f "$DMG" && test ! -L "$DMG" || { echo "candidate DMG is missing or a symlink" >&2; exit 1; }
test -f "$CANDIDATE_MANIFEST" && test ! -L "$CANDIDATE_MANIFEST" \
  || { echo "candidate manifest is missing or a symlink" >&2; exit 1; }
test -d "$OUTPUT_DIRECTORY" && test ! -L "$OUTPUT_DIRECTORY" \
  || { echo "output directory is missing or a symlink" >&2; exit 1; }
for command in codesign git head jq shasum sort spctl xcrun; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "production promotion requires $command" >&2
    exit 1
  }
done

jq -e '
  .schemaVersion == 1 and
  .releaseStatus == "notarized-candidate" and
  .product == "AetherRoute" and
  (.productID | test("^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$")) and
  (.version | test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$")) and
  (.build | type == "number" and . > 0 and floor == .) and
  (.minimumSystemVersion | test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$")) and
  .architecture == "arm64" and
  (.source.gitCommit | test("^[0-9a-f]{40}$")) and
  (.source.manifestSHA256 | test("^[0-9a-f]{64}$")) and
  (if .distribution.mode == "free" then
     .distribution.updateSigningPublicKeySHA256 == null
   elif (.distribution.mode // "licensed") == "licensed" then
     (.distribution.updateSigningPublicKeySHA256 | test("^[0-9a-f]{64}$"))
   else false end) and
  (.dmg.sha256 | test("^[0-9a-f]{64}$")) and
  (.dmg.bytes | type == "number" and . > 0) and
  .notarization.status == "Accepted" and
  .stability.schema == 2 and
  .signedRuntime.schema == 1 and
  .signedRuntime.engines == ["tun", "transparent"]
' "$CANDIDATE_MANIFEST" >/dev/null || {
  echo "candidate manifest is incomplete or already promoted" >&2
  exit 1
}

current_git_commit=$(git -C "$ROOT" rev-parse HEAD)
test "$current_git_commit" = \
  "$(jq -r '.source.gitCommit' "$CANDIDATE_MANIFEST")" || {
  echo "candidate was not produced from the current Git commit" >&2
  exit 1
}
current_source_manifest=$("$ROOT/scripts/source_manifest.sh" \
  | awk '$1 == "MANIFEST_SHA256" {print $2}')
test "$current_source_manifest" = \
  "$(jq -r '.source.manifestSHA256' "$CANDIDATE_MANIFEST")" || {
  echo "candidate was not produced from the current source manifest" >&2
  exit 1
}

dmg_sha256=$(shasum -a 256 "$DMG" | awk '{print $1}')
test "$dmg_sha256" = "$(jq -r '.dmg.sha256' "$CANDIDATE_MANIFEST")" || {
  echo "candidate DMG SHA-256 does not match its manifest" >&2
  exit 1
}
manifest_sha256=$(shasum -a 256 "$CANDIDATE_MANIFEST" | awk '{print $1}')
"$ROOT/scripts/verify_postinstall_evidence.sh" \
  "$POSTINSTALL_EVIDENCE" "$dmg_sha256" "$manifest_sha256" "$CANDIDATE_MANIFEST"

codesign --verify --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature \
  --verbose=4 "$DMG"

candidate_name=$(basename "$CANDIDATE_MANIFEST")
case "$candidate_name" in
  *.candidate.json) production_name=${candidate_name%.candidate.json}.production.json ;;
  *) echo "candidate manifest must use the .candidate.json suffix" >&2; exit 1 ;;
esac
production_manifest="$OUTPUT_DIRECTORY/$production_name"
test ! -e "$production_manifest" || {
  echo "refusing to overwrite production approval: $production_manifest" >&2
  exit 1
}

approved_at=${AETHERROUTE_PRODUCTION_APPROVED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}
printf '%s\n' "$approved_at" \
  | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  || { echo "AETHERROUTE_PRODUCTION_APPROVED_AT must be UTC RFC 3339" >&2; exit 64; }
released_at=$(jq -r '.releasedAt' "$CANDIDATE_MANIFEST")
first_timestamp=$(printf '%s\n%s\n' "$released_at" "$approved_at" \
  | LC_ALL=C sort | head -1)
test "$first_timestamp" = "$released_at" || {
  echo "production approval cannot predate the notarized candidate" >&2
  exit 1
}
postinstall_evidence_sha256=$(shasum -a 256 \
  "$POSTINSTALL_EVIDENCE/SHA256SUMS" | awk '{print $1}')

temporary=$(mktemp -d "$OUTPUT_DIRECTORY/.aetherroute-promotion.XXXXXX")
cleanup() { find "$temporary" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
jq \
  --arg approvedAt "$approved_at" \
  --arg candidateManifestSHA256 "$manifest_sha256" \
  --arg postInstallEvidenceSHA256 "$postinstall_evidence_sha256" \
  '.releaseStatus = "production-approved" |
   .promotion = {
     schema: 1,
     approvedAt: $approvedAt,
     candidateManifestSHA256: $candidateManifestSHA256,
     postInstallEvidenceSHA256: $postInstallEvidenceSHA256,
     exactDMGSHA256: .dmg.sha256
   }' "$CANDIDATE_MANIFEST" >"$temporary/production.json"
jq -e '.releaseStatus == "production-approved" and .promotion.schema == 1' \
  "$temporary/production.json" >/dev/null
mv "$temporary/production.json" "$production_manifest"

echo "Production approval manifest created: $production_manifest"
echo "No upload or update-service mutation was performed."
