#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SERVICE_ROOT="$ROOT/Services/DistributionService"
WIREGUARD_SERVER_ROOT="$ROOT/Tests/Interop/WireGuardGoServer"
EXPECTED_TOOLCHAIN=$(
  awk '$1 == "toolchain" { print $2; exit }' "$SERVICE_ROOT/go.mod"
)
if ! printf '%s\n' "$EXPECTED_TOOLCHAIN" | grep -Eq '^go[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Distribution service must pin an exact Go toolchain patch release" >&2
  exit 1
fi

for module in "$SERVICE_ROOT" "$WIREGUARD_SERVER_ROOT"; do
  module_toolchain=$(awk '$1 == "toolchain" { print $2; exit }' "$module/go.mod")
  if [ "$module_toolchain" != "$EXPECTED_TOOLCHAIN" ]; then
    echo "$module must pin $EXPECTED_TOOLCHAIN; found $module_toolchain" >&2
    exit 1
  fi
  actual_toolchain=$(cd "$module" && go env GOVERSION)
  if [ "$actual_toolchain" != "$EXPECTED_TOOLCHAIN" ]; then
    echo "$module requires $EXPECTED_TOOLCHAIN; found $actual_toolchain" >&2
    exit 1
  fi
done

TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-govulncheck.XXXXXX")
cleanup() {
  # Go's build cache contains read-only directories. Restore owner write
  # permission inside this disposable root so cleanup cannot silently leave
  # hundreds of megabytes behind.
  chmod -R u+w "$TEMP" 2>/dev/null || true
  find "$TEMP" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$TEMP/bin" "$TEMP/cache"

(
  cd "$SERVICE_ROOT"
  GOBIN="$TEMP/bin" GOCACHE="$TEMP/cache" \
    go install golang.org/x/vuln/cmd/govulncheck@v1.6.0
)
for module in "$SERVICE_ROOT" "$WIREGUARD_SERVER_ROOT"; do
  (cd "$module" && "$TEMP/bin/govulncheck" -db https://vuln.go.dev ./...)
done

printf 'Production service and WireGuard test server passed govulncheck with %s.\n' \
  "$EXPECTED_TOOLCHAIN"
