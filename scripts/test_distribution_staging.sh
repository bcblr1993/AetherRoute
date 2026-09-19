#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-distribution-staging.XXXXXX")
SERVER_PID=

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  find "$TEMP_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

PRIVATE_KEY="$TEMP_DIR/private-key.raw"
PUBLIC_KEY="$TEMP_DIR/public-key.raw"
PORT_FILE="$TEMP_DIR/port"
dd if=/dev/urandom of="$PRIVATE_KEY" bs=32 count=1 2>/dev/null
chmod 600 "$PRIVATE_KEY"
xcrun swift "$ROOT/scripts/distribution_envelope_tool.swift" \
  public-key "$PRIVATE_KEY" "$PUBLIC_KEY"
PUBLIC_KEY_BASE64=$(base64 <"$PUBLIC_KEY" | tr -d '\n')

sign_payload() {
  name=$1
  state=$2
  payload="$TEMP_DIR/$name-payload.json"
  envelope="$TEMP_DIR/$name-envelope.json"
  jq -cn \
    --arg state "$state" \
    '{schemaVersion:1, productID:"com.example.aetherroute", licenseID:"license-staging", deviceID:"11111111-2222-3333-4444-555555555555", state:$state, issuedAt:"2026-08-01T00:00:00Z", expiresAt:null}' \
    >"$payload"
  xcrun swift "$ROOT/scripts/distribution_envelope_tool.swift" \
    sign "$PRIVATE_KEY" "$payload" "$envelope"
}

sign_payload active active
sign_payload revoked revoked
sign_payload device-limit deviceLimit

UPDATE_PAYLOAD="$TEMP_DIR/update-payload.json"
UPDATE_ENVELOPE="$TEMP_DIR/update-envelope.json"
jq -cn \
  '{schemaVersion:1, productID:"com.example.aetherroute", version:"1.0.1", build:101, publishedAt:"2026-08-01T00:00:00Z", minimumSystemVersion:"15.0", architecture:"arm64", downloadURL:"https://downloads.example/AetherRoute-1.0.1-arm64.dmg", sha256:("a" * 64), releaseNotesURL:"https://downloads.example/releases/1.0.1"}' \
  >"$UPDATE_PAYLOAD"
xcrun swift "$ROOT/scripts/distribution_envelope_tool.swift" \
  sign "$PRIVATE_KEY" "$UPDATE_PAYLOAD" "$UPDATE_ENVELOPE"

python3 "$ROOT/Tests/DistributionStaging/server.py" \
  "$PORT_FILE" \
  "$TEMP_DIR/active-envelope.json" \
  "$TEMP_DIR/revoked-envelope.json" \
  "$TEMP_DIR/device-limit-envelope.json" \
  "$UPDATE_ENVELOPE" \
  "$TEMP_DIR/active-envelope.json" \
  >"$TEMP_DIR/server.log" 2>&1 &
SERVER_PID=$!

attempt=0
while [ ! -s "$PORT_FILE" ] && [ "$attempt" -lt 200 ]; do
  kill -0 "$SERVER_PID" 2>/dev/null || {
    echo "distribution staging service exited before readiness" >&2
    exit 1
  }
  sleep 0.1
  attempt=$((attempt + 1))
done
test -s "$PORT_FILE" || {
  echo "distribution staging service readiness timed out; server.log:" >&2
  cat "$TEMP_DIR/server.log" >&2 || true
  exit 1
}
PORT=$(cat "$PORT_FILE")
case "$PORT" in
  ''|*[!0-9]*) echo "invalid staging port" >&2; exit 1 ;;
esac

LISTENER=$(lsof -nP -a -p "$SERVER_PID" -iTCP:"$PORT" -sTCP:LISTEN)
printf '%s\n' "$LISTENER" | grep -F "127.0.0.1:$PORT" >/dev/null || {
  echo "distribution staging service is not loopback-only" >&2
  exit 1
}
if printf '%s\n' "$LISTENER" | grep -Eq '\*:|0\.0\.0\.0:|\[::\]:'; then
  echo "distribution staging service opened a non-loopback listener" >&2
  exit 1
fi

swiftc -parse-as-library \
  "$ROOT/Sources/AetherRouteKit/LocalProxySettings.swift" \
  "$ROOT/Sources/AetherRouteKit/TunnelConfiguration.swift" \
  "$ROOT/Sources/AetherRouteKit/IndependentDistribution.swift" \
  "$ROOT/Tests/DistributionStaging/main.swift" \
  -o "$TEMP_DIR/distribution_staging_verifier"
"$TEMP_DIR/distribution_staging_verifier" "$PORT" "$PUBLIC_KEY_BASE64"

test ! -s "$TEMP_DIR/server.log" || {
  echo "distribution staging service emitted unexpected log output" >&2
  exit 1
}

printf '%s\n' \
  'Owner-operated distribution staging drill passed on an IPv4 loopback-only service.'
