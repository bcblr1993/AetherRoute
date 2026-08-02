#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SMOKE_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-local-proxy.XXXXXX")
cleanup() {
  find "$SMOKE_TEMP" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$SMOKE_TEMP/runtime"

clang \
  -std=c17 \
  -Wall \
  -Wextra \
  -Werror \
  -mmacosx-version-min=14.0 \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/local_proxy_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" \
  -framework Security \
  -framework SystemConfiguration \
  -framework CoreFoundation \
  -framework CoreServices \
  -lresolv \
  -o "$SMOKE_TEMP/local_proxy_smoke"

touch "$SMOKE_TEMP/runtime/existing-sentinel"
"$SMOKE_TEMP/local_proxy_smoke" \
  "$SMOKE_TEMP/runtime" \
  "$SMOKE_TEMP/ignored.log"

if [ -e "$SMOKE_TEMP/ignored.log" ]; then
  echo "Local proxy smoke unexpectedly opened the compatibility log path" >&2
  exit 1
fi

if find "$SMOKE_TEMP/runtime" -type f ! -name existing-sentinel -print -quit \
  | grep -q .; then
  echo "Local proxy smoke unexpectedly persisted runtime data" >&2
  exit 1
fi
