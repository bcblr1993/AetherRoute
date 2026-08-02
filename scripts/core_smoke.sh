#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SMOKE_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-core-smoke.XXXXXX")
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
  "$ROOT/Tests/CoreSmoke/flow_core_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" \
  -framework Security \
  -framework SystemConfiguration \
  -framework CoreFoundation \
  -framework CoreServices \
  -lresolv \
  -o "$SMOKE_TEMP/core_smoke"

"$SMOKE_TEMP/core_smoke" "$SMOKE_TEMP/runtime"

if find "$SMOKE_TEMP/runtime" -type f -print -quit | grep -q .; then
  echo "FlowOnly core unexpectedly persisted runtime data" >&2
  exit 1
fi
