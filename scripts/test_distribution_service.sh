#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SERVICE_ROOT="$ROOT/Services/DistributionService"
# Darwin limits Unix-domain socket paths to roughly 104 bytes. Keep the
# signer test root deliberately short even when TMPDIR is a long /var path.
TEMP_DIR=$(mktemp -d "/tmp/ar-dist.XXXXXX")
SIGNER_PID=
SERVER_PID=

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [ -n "$SIGNER_PID" ]; then
    kill "$SIGNER_PID" 2>/dev/null || true
    wait "$SIGNER_PID" 2>/dev/null || true
  fi
  find "$TEMP_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

test -z "$(gofmt -l "$SERVICE_ROOT")" || {
  echo "Distribution service Go sources require gofmt" >&2
  exit 1
}
if find "$SERVICE_ROOT" -type f \( -name '*.raw' -o -name 'licenses*.json' \) \
    -print -quit | grep -q .; then
  echo "Distribution service source contains a secret or mutable state file" >&2
  exit 1
fi
(cd "$SERVICE_ROOT" && go vet ./... && go test -race ./...)
(cd "$SERVICE_ROOT" && \
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
    -buildvcs=false -trimpath -ldflags='-s -w' \
    -o "$TEMP_DIR/aetherroute-distribution-linux-arm64" \
    ./cmd/aetherroute-distribution)
file "$TEMP_DIR/aetherroute-distribution-linux-arm64" | grep -F 'ARM aarch64' >/dev/null
(cd "$SERVICE_ROOT" && go build -buildvcs=false -trimpath \
  -o "$TEMP_DIR/aetherroute-distribution" ./cmd/aetherroute-distribution)

SEED="$TEMP_DIR/signing-seed.raw"
PUBLIC_KEY="$TEMP_DIR/public-key.raw"
PEPPER="$TEMP_DIR/pepper.raw"
STATE="$TEMP_DIR/licenses.json"
SOCKET="$TEMP_DIR/signer.sock"
UPDATE_PAYLOAD="$TEMP_DIR/update-payload.json"
UPDATE_ENVELOPE="$TEMP_DIR/update-envelope.json"
dd if=/dev/urandom of="$SEED" bs=32 count=1 2>/dev/null
dd if=/dev/urandom of="$PEPPER" bs=32 count=1 2>/dev/null
chmod 600 "$SEED" "$PEPPER"
xcrun swift "$ROOT/scripts/distribution_envelope_tool.swift" \
  public-key "$SEED" "$PUBLIC_KEY"
PUBLISHED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
jq -cn \
  --arg publishedAt "$PUBLISHED_AT" \
  '{schemaVersion:1, productID:"com.aetherroute.desktop", version:"1.0.1", build:101, publishedAt:$publishedAt, minimumSystemVersion:"15.0", architecture:"arm64", downloadURL:"https://downloads.example.com/AetherRoute-1.0.1-arm64.dmg", sha256:("a" * 64), releaseNotesURL:null}' \
  >"$UPDATE_PAYLOAD"
xcrun swift "$ROOT/scripts/distribution_envelope_tool.swift" \
  sign "$SEED" "$UPDATE_PAYLOAD" "$UPDATE_ENVELOPE"

ISSUED=$(
  "$TEMP_DIR/aetherroute-distribution" issue \
    -product-id com.aetherroute.desktop \
    -state "$STATE" -pepper "$PEPPER" -max-devices 1
)
ACTIVATION_KEY=$(printf '%s' "$ISSUED" | jq -er '.activationKey')
test -n "$ACTIVATION_KEY"
if grep -F "$ACTIVATION_KEY" "$STATE" >/dev/null; then
  echo "Distribution state leaked the plaintext activation key" >&2
  exit 1
fi
test "$(stat -f '%Lp' "$STATE")" = 600

"$TEMP_DIR/aetherroute-distribution" signer \
  -product-id com.aetherroute.desktop \
  -seed "$SEED" -socket "$SOCKET" \
  >"$TEMP_DIR/signer.log" 2>&1 &
SIGNER_PID=$!
attempt=0
while [ ! -S "$SOCKET" ] && [ "$attempt" -lt 50 ]; do
  kill -0 "$SIGNER_PID" 2>/dev/null || {
    echo "Distribution signer exited before readiness" >&2
    sed -n '1,80p' "$TEMP_DIR/signer.log" >&2
    exit 1
  }
  sleep 0.1
  attempt=$((attempt + 1))
done
test -S "$SOCKET"
test "$(stat -f '%Lp' "$SOCKET")" = 600

PORT=$(python3 - <<'PY'
import socket
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)
"$TEMP_DIR/aetherroute-distribution" serve \
  -product-id com.aetherroute.desktop \
  -state "$STATE" -pepper "$PEPPER" -public-key "$PUBLIC_KEY" \
  -update-envelope "$UPDATE_ENVELOPE" -signer-socket "$SOCKET" \
  -listen "127.0.0.1:$PORT" \
  >"$TEMP_DIR/server.log" 2>&1 &
SERVER_PID=$!
attempt=0
while [ "$attempt" -lt 50 ]; do
  kill -0 "$SERVER_PID" 2>/dev/null || {
    echo "Distribution web service exited before readiness" >&2
    sed -n '1,80p' "$TEMP_DIR/server.log" >&2
    exit 1
  }
  if lsof -nP -a -p "$SERVER_PID" -iTCP:"$PORT" -sTCP:LISTEN \
      | grep -F "127.0.0.1:$PORT" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
  attempt=$((attempt + 1))
done
LISTENER=$(lsof -nP -a -p "$SERVER_PID" -iTCP:"$PORT" -sTCP:LISTEN)
printf '%s\n' "$LISTENER" | grep -F "127.0.0.1:$PORT" >/dev/null
if printf '%s\n' "$LISTENER" | grep -Eq '\*:|0\.0\.0\.0:|\[::\]:'; then
  echo "Distribution web service opened a non-loopback listener" >&2
  exit 1
fi

PUBLIC_KEY_BASE64=$(base64 <"$PUBLIC_KEY" | tr -d '\n')
swiftc -parse-as-library \
  "$ROOT/Sources/AetherRouteKit/LocalProxySettings.swift" \
  "$ROOT/Sources/AetherRouteKit/TunnelConfiguration.swift" \
  "$ROOT/Sources/AetherRouteKit/IndependentDistribution.swift" \
  "$ROOT/Tests/DistributionServiceInterop/main.swift" \
  -o "$TEMP_DIR/distribution_service_interop"
"$TEMP_DIR/distribution_service_interop" \
  "$PORT" "$PUBLIC_KEY_BASE64" "$ACTIVATION_KEY"

test ! -s "$TEMP_DIR/signer.log" || {
  echo "Distribution signer emitted unexpected output" >&2
  exit 1
}
test ! -s "$TEMP_DIR/server.log" || {
  echo "Distribution web service emitted unexpected output" >&2
  exit 1
}
printf '%s\n' \
  'Production distribution service passed Go race tests, Linux arm64 build, isolated signer, and Swift client interop.'
