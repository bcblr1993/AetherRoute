#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -ne 2 ] && [ "$#" -ne 4 ] && [ "$#" -ne 5 ]; then
  echo "usage: $0 PROFILE RUNTIME_DIR [GROUP MEMBER [PREFLIGHT_GROUP]]" >&2
  exit 64
fi

PROFILE=$1
RUNTIME_DIR=$2
case "$PROFILE:$RUNTIME_DIR" in
  /*:/*) ;;
  *) echo "profile and runtime paths must be absolute" >&2; exit 64 ;;
esac
test -f "$PROFILE" && test -r "$PROFILE" || {
  echo "profile is not a readable regular file" >&2
  exit 66
}
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-flow-egress-build.XXXXXX")
cleanup() {
  find "$BUILD_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

clang \
  -std=c17 \
  -Wall \
  -Wextra \
  -Werror \
  -mmacosx-version-min=14.0 \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/external_flow_egress_runner.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" \
  -framework Security \
  -framework SystemConfiguration \
  -framework CoreFoundation \
  -framework CoreServices \
  -lresolv \
  -o "$BUILD_DIR/external_flow_egress_runner"

"$BUILD_DIR/external_flow_egress_runner" "$@"
