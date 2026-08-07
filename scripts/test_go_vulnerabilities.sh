#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SERVICE_ROOT="$ROOT/Services/DistributionService"
EXPECTED_TOOLCHAIN=$(
  awk '$1 == "toolchain" { print $2; exit }' "$SERVICE_ROOT/go.mod"
)
if ! printf '%s\n' "$EXPECTED_TOOLCHAIN" | grep -Eq '^go[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Distribution service must pin an exact Go toolchain patch release" >&2
  exit 1
fi

ACTUAL_TOOLCHAIN=$(cd "$SERVICE_ROOT" && go env GOVERSION)
if [ "$ACTUAL_TOOLCHAIN" != "$EXPECTED_TOOLCHAIN" ]; then
  echo "Distribution service requires $EXPECTED_TOOLCHAIN; found $ACTUAL_TOOLCHAIN" >&2
  exit 1
fi

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
  "$TEMP/bin/govulncheck" -db https://vuln.go.dev ./...
)

printf 'Distribution service passed govulncheck with %s.\n' "$ACTUAL_TOOLCHAIN"
