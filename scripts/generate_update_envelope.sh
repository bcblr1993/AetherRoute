#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOL="$ROOT/scripts/distribution_envelope_tool.swift"

private_key=${1:-}
dmg=${2:-}
product_id=${3:-}
version=${4:-}
build=${5:-}
published_at=${6:-}
minimum_system_version=${7:-}
download_url=${8:-}
release_notes_url=${9:--}
output=${10:-}

usage() {
  echo "usage: $0 /absolute/private-key.raw /absolute/release.dmg product-id version build published-at minimum-system-version https-download-url https-release-notes-url-or-dash /absolute/update-envelope.json" >&2
}

if [ -z "$private_key" ] || [ -z "$dmg" ] || [ -z "$product_id" ] || \
   [ -z "$version" ] || [ -z "$build" ] || [ -z "$published_at" ] || \
   [ -z "$minimum_system_version" ] || [ -z "$download_url" ] || \
   [ -z "$output" ]; then
  usage
  exit 64
fi
case "$private_key" in /*) ;; *) usage; exit 64 ;; esac
case "$dmg" in /*) ;; *) usage; exit 64 ;; esac
case "$output" in /*) ;; *) usage; exit 64 ;; esac
case "$private_key" in
  "$ROOT"/*)
    echo "distribution private key must remain outside the repository" >&2
    exit 64
    ;;
esac
test -f "$private_key" || {
  echo "private key file does not exist: $private_key" >&2
  exit 1
}
test "$(stat -f '%z' "$private_key")" -eq 32 || {
  echo "private key must contain exactly 32 raw Ed25519 bytes" >&2
  exit 64
}
private_mode=$(stat -f '%Lp' "$private_key")
case "$private_mode" in
  400|600) ;;
  *) echo "private key mode must be 400 or 600" >&2; exit 64 ;;
esac
test "$(stat -f '%u' "$private_key")" -eq "$(id -u)" || {
  echo "private key must be owned by the current user" >&2
  exit 64
}
test -f "$dmg" || {
  echo "DMG does not exist: $dmg" >&2
  exit 1
}
test ! -e "$output" || {
  echo "refusing to overwrite existing update envelope: $output" >&2
  exit 1
}
printf '%s\n' "$product_id" | grep -Eq '^[^[:space:]]{1,128}$' || {
  echo "invalid product identifier" >&2
  exit 64
}
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || {
  echo "invalid version" >&2
  exit 64
}
printf '%s\n' "$minimum_system_version" \
  | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || {
    echo "invalid minimum system version" >&2
    exit 64
  }
printf '%s\n' "$build" | grep -Eq '^[1-9][0-9]*$' || {
  echo "invalid build number" >&2
  exit 64
}
printf '%s\n' "$published_at" \
  | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || {
    echo "published-at must be UTC RFC 3339" >&2
    exit 64
  }
for url in "$download_url" "$release_notes_url"; do
  test "$url" = - && continue
  case "$url" in https://?*) ;; *) echo "release URLs must use HTTPS" >&2; exit 64 ;; esac
  if printf '%s\n' "$url" | grep -Eq '[@#[:space:]]'; then
    echo "release URL contains credentials, fragment, or whitespace" >&2
    exit 64
  fi
done

temporary=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-update-envelope.XXXXXX")
cleanup() {
  if [ -d "$temporary" ]; then
    find "$temporary" -depth -delete
  fi
}
trap cleanup EXIT HUP INT TERM

payload="$temporary/payload.json"
public_key="$temporary/public-key.raw"
verified_payload="$temporary/verified-payload.json"
dmg_sha256=$(shasum -a 256 "$dmg" | awk '{print $1}')

if [ "$release_notes_url" = - ]; then
  release_notes_json=null
else
  release_notes_json=$(jq -Rn --arg value "$release_notes_url" '$value')
fi
jq -cS -n \
  --arg productID "$product_id" \
  --arg version "$version" \
  --argjson build "$build" \
  --arg publishedAt "$published_at" \
  --arg minimumSystemVersion "$minimum_system_version" \
  --arg downloadURL "$download_url" \
  --arg sha256 "$dmg_sha256" \
  --argjson releaseNotesURL "$release_notes_json" \
  '{schemaVersion: 1, productID: $productID, version: $version,
    build: $build, publishedAt: $publishedAt,
    minimumSystemVersion: $minimumSystemVersion, architecture: "arm64",
    downloadURL: $downloadURL, sha256: $sha256,
    releaseNotesURL: $releaseNotesURL}' >"$payload"

xcrun swift "$TOOL" public-key "$private_key" "$public_key"
derived_public_key=$(base64 <"$public_key" | tr -d '\n')
configured_public_key=${AETHERROUTE_DISTRIBUTION_PUBLIC_KEY:-}
if [ -n "$configured_public_key" ] && \
   [ "$configured_public_key" != "$derived_public_key" ]; then
  echo "private key does not match AETHERROUTE_DISTRIBUTION_PUBLIC_KEY" >&2
  exit 64
fi
xcrun swift "$TOOL" sign "$private_key" "$payload" "$output"
xcrun swift "$TOOL" verify "$public_key" "$output" "$verified_payload"
cmp -s "$payload" "$verified_payload" || {
  echo "signed update envelope did not verify byte-for-byte" >&2
  exit 1
}

echo "Signed update envelope: $output"
echo "Ed25519 public key (base64): $derived_public_key"
echo "DMG SHA-256: $dmg_sha256"
