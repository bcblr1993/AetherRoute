#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GENERATOR="$ROOT/scripts/generate_update_envelope.sh"
TOOL="$ROOT/scripts/distribution_envelope_tool.swift"

sh -n "$GENERATOR"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-update-test.XXXXXX")
cleanup() {
  if [ -d "$temporary" ]; then
    find "$temporary" -depth -delete
  fi
}
trap cleanup EXIT HUP INT TERM

private_key="$temporary/private-key.raw"
public_key="$temporary/public-key.raw"
dmg="$temporary/AetherRoute-1.0.1-arm64.dmg"
envelope="$temporary/update.json"
decoded="$temporary/decoded.json"
printf '01234567890123456789012345678901' >"$private_key"
chmod 600 "$private_key"
printf 'not-a-real-dmg-test-fixture' >"$dmg"

xcrun swift "$TOOL" public-key "$private_key" "$public_key"
public_key_base64=$(base64 <"$public_key" | tr -d '\n')
AETHERROUTE_DISTRIBUTION_PUBLIC_KEY="$public_key_base64" \
  "$GENERATOR" \
  "$private_key" \
  "$dmg" \
  com.example.aetherroute \
  1.0.1 \
  101 \
  2026-08-01T08:00:00Z \
  15.0 \
  https://downloads.example.com/AetherRoute-1.0.1-arm64.dmg \
  https://downloads.example.com/releases/1.0.1 \
  "$envelope" >/dev/null

xcrun swift "$TOOL" verify "$public_key" "$envelope" "$decoded"
test "$(jq -r '.schemaVersion' "$decoded")" = 1
test "$(jq -r '.productID' "$decoded")" = com.example.aetherroute
test "$(jq -r '.architecture' "$decoded")" = arm64
test "$(jq -r '.build' "$decoded")" = 101
test "$(jq -r '.sha256' "$decoded")" = \
  "$(shasum -a 256 "$dmg" | awk '{print $1}')"

tampered="$temporary/tampered.json"
jq '.signature = ((if (.signature | startswith("A")) then "B" else "A" end) + .signature[1:])' \
  "$envelope" >"$tampered"
if xcrun swift "$TOOL" verify \
  "$public_key" "$tampered" "$temporary/should-not-exist.json" \
  >/dev/null 2>&1; then
  echo "tampered update envelope was accepted" >&2
  exit 1
fi

echo "Signed update envelope tests passed."
