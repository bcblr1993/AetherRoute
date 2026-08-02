#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_SOURCE=${AETHERROUTE_CORE_SOURCE:-"$ROOT/Core/Engine"}
CARGO_ABOUT=${CARGO_ABOUT:-cargo-about}
TARGET=aarch64-apple-darwin
CONFIG="$ROOT/Licenses/about.toml"
FILTER="$ROOT/Licenses/compact.jq"
DESTINATION="$ROOT/Config/Licenses"

command -v "$CARGO_ABOUT" >/dev/null 2>&1 || {
  echo "cargo-about 0.9.1 is required through CARGO_ABOUT or PATH" >&2
  exit 1
}
test "$("$CARGO_ABOUT" --version | awk '{print $2}')" = 0.9.1 || {
  echo "cargo-about 0.9.1 is required for deterministic notices" >&2
  exit 1
}

TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-licenses.XXXXXX")
cleanup() {
  find "$TEMP" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

generate_raw() {
  feature=$1
  output=$2
  "$CARGO_ABOUT" generate \
    --config "$CONFIG" \
    --manifest-path "$CORE_SOURCE/clash-ffi/Cargo.toml" \
    --no-default-features \
    --features "$feature" \
    --target "$TARGET" \
    --locked \
    --offline \
    --fail \
    --format json \
    --output-file "$output"
}

generate_raw aether-flow-only "$TEMP/transparent-proxy.json"
generate_raw aether-embedded "$TEMP/packet-tunnel.json"

TRANSPARENT_PROXY_HASH=$(shasum -a 256 \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" | awk '{print $1}')
PACKET_TUNNEL_HASH=$(shasum -a 256 \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" | awk '{print $1}')

mkdir -p "$DESTINATION"
jq -S \
  --arg surface independent \
  --arg transparentProxyHash "$TRANSPARENT_PROXY_HASH" \
  --arg packetTunnelHash "$PACKET_TUNNEL_HASH" \
  -s -f "$FILTER" \
  "$TEMP/transparent-proxy.json" "$TEMP/packet-tunnel.json" \
  > "$TEMP/ThirdPartyLicenses.json"

mv -f "$TEMP/ThirdPartyLicenses.json" \
  "$DESTINATION/ThirdPartyLicenses.json"

jq -e '.schemaVersion == 1 and (.components | length > 0) and (.licenses | length > 0)' \
  "$DESTINATION/ThirdPartyLicenses.json" >/dev/null

printf 'Independent product notices: %s components, %s license texts\n' \
  "$(jq '.components | length' "$DESTINATION/ThirdPartyLicenses.json")" \
  "$(jq '.licenses | length' "$DESTINATION/ThirdPartyLicenses.json")"
