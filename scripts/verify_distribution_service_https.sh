#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BASE_URL=${1:-}
PUBLIC_KEY=${2:-}
ACTIVATION_KEY_FILE=${3:-}
EXPECTED_BUILD=${4:-}
EXPECTED_DOWNLOAD_URL=${5:-}

usage() {
  echo "usage: $0 https://license-staging.baizhiedu.xin /absolute/public-key.raw /absolute/activation-key.txt expected-build https://downloads.example/app.dmg" >&2
}

case "$BASE_URL" in
  https://license-staging.baizhiedu.xin) ;;
  *) usage; exit 64 ;;
esac
case "$PUBLIC_KEY:$ACTIVATION_KEY_FILE" in
  /*:/*) ;;
  *) usage; exit 64 ;;
esac
case "$EXPECTED_BUILD" in
  ''|*[!0-9]*) usage; exit 64 ;;
esac
test "$EXPECTED_BUILD" -gt 1 || { usage; exit 64; }
case "$EXPECTED_DOWNLOAD_URL" in
  https://downloads.baizhiedu.xin/*.dmg) ;;
  *) usage; exit 64 ;;
esac
test -f "$PUBLIC_KEY" && test "$(wc -c <"$PUBLIC_KEY" | tr -d ' ')" -eq 32
test -s "$ACTIVATION_KEY_FILE"
test "$(stat -f '%Lp' "$ACTIVATION_KEY_FILE")" = 600

temporary=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-https-service.XXXXXX")
cleanup() {
  find "$temporary" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

headers="$temporary/update.headers"
body="$temporary/update.json"
update_status=000
attempt=0
while [ "$attempt" -lt 30 ]; do
  update_status=$(curl --noproxy '*' --silent --show-error --proto '=https' --tlsv1.2 \
    --max-redirs 0 --connect-timeout 10 --max-time 20 \
    --dump-header "$headers" --output "$body" --write-out '%{http_code}' \
    "$BASE_URL/v1/update") || update_status=000
  if [ "$update_status" = 200 ]; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 2
done
if [ "$update_status" != 200 ]; then
  echo "Distribution HTTPS update endpoint did not become ready: HTTP $update_status" >&2
  exit 1
fi
jq -e '.payload | type == "string"' "$body" >/dev/null
grep -Eiq '^strict-transport-security: max-age=31536000' "$headers"
grep -Eiq '^cache-control: no-store' "$headers"
if grep -Eiq '^location:' "$headers"; then
  echo "Distribution update endpoint returned a redirect" >&2
  exit 1
fi

unknown_status=$(curl --noproxy '*' --silent --show-error --proto '=https' --tlsv1.2 \
  --max-redirs 0 --connect-timeout 10 --max-time 20 \
  --output /dev/null --write-out '%{http_code}' "$BASE_URL/not-an-api")
test "$unknown_status" = 404
wrong_method_status=000
attempt=0
while [ "$attempt" -lt 30 ]; do
  wrong_method_status=$(curl --noproxy '*' --silent --show-error --proto '=https' --tlsv1.2 \
    --max-redirs 0 --connect-timeout 10 --max-time 20 \
    --output /dev/null --write-out '%{http_code}' \
    "$BASE_URL/v1/license") || wrong_method_status=000
  if [ "$wrong_method_status" = 405 ]; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 2
done
if [ "$wrong_method_status" != 405 ]; then
  echo "Distribution HTTPS candidate edge did not become current: HTTP $wrong_method_status" >&2
  exit 1
fi

public_key_base64=$(base64 <"$PUBLIC_KEY" | tr -d '\n')
swiftc -parse-as-library \
  "$ROOT/Sources/AetherRouteKit/LocalProxySettings.swift" \
  "$ROOT/Sources/AetherRouteKit/TunnelConfiguration.swift" \
  "$ROOT/Sources/AetherRouteKit/IndependentDistribution.swift" \
  "$ROOT/Tests/DistributionServiceHTTPS/main.swift" \
  -o "$temporary/distribution_https_verifier"
"$temporary/distribution_https_verifier" \
  "$BASE_URL/v1/license" "$BASE_URL/v1/update" \
  "$public_key_base64" "$ACTIVATION_KEY_FILE" \
  "$EXPECTED_BUILD" "$EXPECTED_DOWNLOAD_URL"

printf '%s\n' \
  'Public HTTPS distribution boundary passed: TLS, no redirects, exact paths, no-store, native signed lifecycle.'

