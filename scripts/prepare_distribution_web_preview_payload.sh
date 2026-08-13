#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WEB="$ROOT/Services/WebDistribution"
CANDIDATE_DIRECTORY=${1:-}
SITE_SOURCE=${2:-}
OUTPUT=${3:-}

usage() {
  echo "usage: $0 /absolute/notarized-preview-directory /absolute/site-source /absolute/new-output-directory" >&2
}

for path in "$CANDIDATE_DIRECTORY" "$SITE_SOURCE" "$OUTPUT"; do
  case "$path" in /*) ;; *) usage; exit 64 ;; esac
done
for directory in "$CANDIDATE_DIRECTORY" "$SITE_SOURCE"; do
  test -d "$directory" && test ! -L "$directory" || {
    echo "preview input directory is missing or a symlink: $directory" >&2
    exit 1
  }
  if find "$directory" -type l -print -quit | grep -q .; then
    echo "preview input must not contain symbolic links: $directory" >&2
    exit 1
  fi
done
test ! -e "$OUTPUT" || {
  echo "refusing to overwrite preview distribution payload: $OUTPUT" >&2
  exit 1
}
output_parent=$(dirname "$OUTPUT")
test -d "$output_parent" && test ! -L "$output_parent" || {
  echo "preview distribution output parent is missing or a symlink" >&2
  exit 1
}
for command in ditto jq shasum stat; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "preview distribution preparation requires $command" >&2
    exit 1
  }
done

artifact_name=AetherRoute-0.1.0-build-2026080703-arm64-Notarized-Test.dmg
manifest_name=AetherRoute-0.1.0-build-2026080703-arm64-Notarized-Test.json
expected_sha=4a18a47dfbd0886008753b9bbbbe9e4a36c5b1f7dc9f62951df59bea69299c20
DMG="$CANDIDATE_DIRECTORY/$artifact_name"
MANIFEST="$CANDIDATE_DIRECTORY/$manifest_name"
SOURCE_MANIFEST="$CANDIDATE_DIRECTORY/source-manifest.txt"
README="$CANDIDATE_DIRECTORY/README.txt"
SUMS="$CANDIDATE_DIRECTORY/SHA256SUMS"
for file in "$DMG" "$MANIFEST" "$SOURCE_MANIFEST" "$README" "$SUMS"; do
  test -f "$file" && test ! -L "$file" || {
    echo "preview candidate is incomplete or contains a symlink: $file" >&2
    exit 1
  }
done
candidate_file_count=$(find "$CANDIDATE_DIRECTORY" -type f | wc -l | tr -d ' ')
test "$candidate_file_count" -eq 5 || {
  echo "preview candidate must contain exactly five audited files" >&2
  exit 1
}
(cd "$CANDIDATE_DIRECTORY" && shasum -a 256 -c SHA256SUMS)

actual_sha=$(shasum -a 256 "$DMG" | awk '{print $1}')
actual_bytes=$(stat -f '%z' "$DMG")
test "$actual_sha" = "$expected_sha" || {
  echo "preview DMG checksum differs from the published release page" >&2
  exit 1
}
jq -e \
  --arg sha "$actual_sha" \
  --argjson bytes "$actual_bytes" '
    .schemaVersion == 1 and
    .releaseStatus == "notarized-test-candidate" and
    .product == "AetherRoute" and
    .author == "陈艳男 (ChenYanNan)" and
    .version == "0.1.0" and
    .build == "2026080703" and
    .architecture == "arm64" and
    .safety.productionApproved == false and
    .safety.networkActivatedDuringBuild == false and
    .safety.systemNetworkState == "unchanged" and
    .dmg.sha256 == $sha and
    .dmg.bytes == $bytes and
    .notarization.status == "Accepted" and
    (.notarization.submissionID | test("^[0-9a-f-]{36}$")) and
    (.sourceManifestSHA256 | test("^[0-9a-f]{64}$"))
  ' "$MANIFEST" >/dev/null || {
  echo "preview manifest does not describe the exact notarized test candidate" >&2
  exit 1
}
source_manifest_sha=$(awk '$1 == "MANIFEST_SHA256" {print $2}' \
  "$SOURCE_MANIFEST")
test "$source_manifest_sha" = \
  "$(jq -r '.sourceManifestSHA256' "$MANIFEST")" || {
  echo "preview source manifest does not match the candidate manifest" >&2
  exit 1
}

for required in index.html releases/index.html assets/site.css assets/site.js; do
  test -s "$SITE_SOURCE/$required" || {
    echo "preview site source is missing: $required" >&2
    exit 1
  }
done

temporary=$(mktemp -d "$output_parent/.aetherroute-web-preview.XXXXXX")
cleanup() {
  test ! -d "$temporary" || find "$temporary" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

stage="$temporary/stage"
mkdir -p "$stage/payload/site" "$stage/payload/downloads/prerelease" \
  "$stage/payload/updates"
ditto "$SITE_SOURCE" "$stage/payload/site"
cp "$WEB/nginx.conf" "$stage/payload/nginx.conf"
cp "$WEB/docker-stack.yml" "$stage/docker-stack.yml"
for file in "$DMG" "$MANIFEST" "$SOURCE_MANIFEST" "$README" "$SUMS"; do
  cp "$file" "$stage/payload/downloads/prerelease/$(basename "$file")"
done
jq -n \
  --arg artifactName "$artifact_name" \
  --arg channel prerelease \
  --arg sha256 "$actual_sha" \
  '{schemaVersion: 1, releaseStatus: "notarized-test-candidate",
    artifactName: $artifactName, channel: $channel, sha256: $sha256,
    updateHTTPStatus: 404, publishedFiles: 5}' >"$stage/metadata.json"
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
mv "$stage" "$OUTPUT"

echo "Preview distribution payload prepared: $OUTPUT"
echo "DMG SHA-256: $actual_sha"

