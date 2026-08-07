#!/bin/sh
set -eu

EXPECTED_SHA=${1:-}
ARTIFACT_NAME=${2:-}
CHANNEL=${3:-}

usage() {
  echo "usage: $0 expected-sha256 artifact-filename prerelease-or-releases/version" >&2
}

test -n "$EXPECTED_SHA" && test -n "$ARTIFACT_NAME" && test -n "$CHANNEL" || {
  usage
  exit 64
}
printf '%s\n' "$EXPECTED_SHA" | grep -Eq '^[0-9a-f]{64}$' || {
  echo "expected SHA-256 must be lowercase hexadecimal" >&2
  exit 64
}
printf '%s\n' "$ARTIFACT_NAME" | grep -Eq '^AetherRoute-[0-9A-Za-z._-]+-arm64-[0-9A-Za-z._-]+\.dmg$' || {
  echo "invalid AetherRoute artifact filename" >&2
  exit 64
}
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
