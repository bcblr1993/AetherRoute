#!/bin/sh
set -eu

EXPECTED_SHA=${1:-}
ARTIFACT_NAME=${2:-}
CHANNEL=${3:-}
EXPECTED_UPDATE_STATUS=${4:-any}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

usage() {
  echo "usage: $0 expected-sha256 artifact-filename prerelease-or-releases/version [200|404|any]" >&2
}

test -n "$EXPECTED_SHA" && test -n "$ARTIFACT_NAME" && test -n "$CHANNEL" || {
  usage
  exit 64
}
printf '%s\n' "$EXPECTED_SHA" | grep -Eq '^[0-9a-f]{64}$' || {
  echo "expected SHA-256 must be lowercase hexadecimal" >&2
  exit 64
}
printf '%s\n' "$ARTIFACT_NAME" | grep -Eq '^AetherRoute-[0-9A-Za-z._-]+-arm64(-[0-9A-Za-z._-]+)?\.dmg$' || {
  echo "invalid AetherRoute artifact filename" >&2
  exit 64
}
case "$EXPECTED_UPDATE_STATUS" in 200|404|any) ;; *) usage; exit 64 ;; esac
printf '%s\n' "$CHANNEL" | grep -Eq '^(prerelease|releases/[0-9]+\.[0-9]+(\.[0-9]+)?)$' || {
  echo "invalid distribution channel" >&2
  exit 64
}

unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy || true
site=https://aetherroute.baizhiedu.xin
downloads=https://downloads.baizhiedu.xin
updates=https://updates.baizhiedu.xin
artifact_url="$downloads/$CHANNEL/$ARTIFACT_NAME"

temporary=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-web-verify.XXXXXX")
cleanup() {
  test ! -d "$temporary" || find "$temporary" -depth -delete
}
trap cleanup EXIT HUP INT TERM

site_headers="$temporary/site.headers"
curl --noproxy '*' --silent --show-error --fail --head "$site/" >"$site_headers"
grep -F 'HTTP/2 200' "$site_headers" >/dev/null
grep -iF 'content-security-policy:' "$site_headers" >/dev/null
grep -iF 'strict-transport-security:' "$site_headers" >/dev/null
grep -iF 'x-content-type-options: nosniff' "$site_headers" >/dev/null
grep -iF 'x-frame-options: DENY' "$site_headers" >/dev/null

missing_code=$(curl --noproxy '*' --silent --show-error \
  --output "$temporary/404.html" --write-out '%{http_code}' \
  "$site/this-route-must-not-exist")
test "$missing_code" = 404
grep -F '这条路不存在' "$temporary/404.html" >/dev/null

update_code=$(curl --noproxy '*' --silent --show-error \
  --output "$temporary/update.json" --write-out '%{http_code}' \
  "$updates/v1/update")
case "$update_code" in
  200)
    test -s "$temporary/update.json"
    jq -e '.payload | type == "string"' "$temporary/update.json" >/dev/null
    jq -e '.signature | type == "string"' "$temporary/update.json" >/dev/null
    ;;
  404)
    :
    ;;
  *)
    echo "unexpected update endpoint status: $update_code" >&2
    exit 1
    ;;
esac
if [ "$EXPECTED_UPDATE_STATUS" != any ] && \
   [ "$update_code" != "$EXPECTED_UPDATE_STATUS" ]; then
  echo "update endpoint returned $update_code, expected $EXPECTED_UPDATE_STATUS" >&2
  exit 1
fi

if [ "$update_code" = 200 ] && [ "$EXPECTED_UPDATE_STATUS" = 200 ]; then
  public_key_base64=${AETHERROUTE_DISTRIBUTION_PUBLIC_KEY:-}
  test -n "$public_key_base64" || {
    echo "stable public verification requires AETHERROUTE_DISTRIBUTION_PUBLIC_KEY" >&2
    exit 64
  }
  printf '%s' "$public_key_base64" | base64 -D \
    >"$temporary/public-key.raw" 2>/dev/null || {
    echo "stable update public key is not valid base64" >&2
    exit 64
  }
  test "$(stat -f '%z' "$temporary/public-key.raw")" -eq 32 || {
    echo "stable update public key must contain 32 raw bytes" >&2
    exit 64
  }
  xcrun swift "$ROOT/scripts/distribution_envelope_tool.swift" verify \
    "$temporary/public-key.raw" "$temporary/update.json" \
    "$temporary/update-payload.json" >/dev/null
  version=${CHANNEL#releases/}
  expected_download_url="$downloads/$CHANNEL/$ARTIFACT_NAME"
  expected_notes_url="$site/releases/$version/"
  jq -e \
    --arg version "$version" \
    --arg downloadURL "$expected_download_url" \
    --arg sha256 "$EXPECTED_SHA" \
    --arg releaseNotesURL "$expected_notes_url" '
      .schemaVersion == 1 and
      .productID == "com.aetherroute.desktop" and
      .version == $version and
      (.build | type == "number" and . > 0 and floor == .) and
      .architecture == "arm64" and
      .downloadURL == $downloadURL and
      .sha256 == $sha256 and
      .releaseNotesURL == $releaseNotesURL
    ' "$temporary/update-payload.json" >/dev/null || {
    echo "public signed update does not describe the public stable DMG" >&2
    exit 1
  }
fi

curl --noproxy '*' --silent --show-error --range 0-1023 \
  --output "$temporary/range.bin" --dump-header "$temporary/range.headers" \
  "$artifact_url"
test "$(stat -f '%z' "$temporary/range.bin")" -eq 1024
grep -F 'HTTP/2 206' "$temporary/range.headers" >/dev/null
grep -iF 'content-range: bytes 0-1023/' "$temporary/range.headers" >/dev/null
grep -iF 'cache-control: public, max-age=31536000, immutable' \
  "$temporary/range.headers" >/dev/null

curl --noproxy '*' --silent --show-error --fail \
  --output "$temporary/artifact.dmg" "$artifact_url"
actual_sha=$(shasum -a 256 "$temporary/artifact.dmg" | awk '{print $1}')
test "$actual_sha" = "$EXPECTED_SHA" || {
  echo "public DMG checksum mismatch" >&2
  exit 1
}

echo "Public web distribution verified: sha256=$actual_sha update_http=$update_code"
