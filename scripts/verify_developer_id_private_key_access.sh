#!/bin/sh
set -eu
umask 077

IDENTITY=${1:-}

if ! printf '%s\n' "$IDENTITY" | grep -Eq '^[A-Fa-f0-9]{40}$'; then
  echo "usage: $0 developer-id-application-sha1" >&2
  exit 64
fi

PROBE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-signing-key.XXXXXX")
cleanup() {
  find "$PROBE_ROOT" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

cp /usr/bin/true "$PROBE_ROOT/probe"
if ! codesign --force --sign "$IDENTITY" -o runtime \
  "$PROBE_ROOT/probe" >"$PROBE_ROOT/codesign.log" 2>&1; then
  echo "Developer ID certificate is installed, but its private key is unavailable." >&2
  echo "Unlock the login Keychain in Keychain Access, then rerun this build." >&2
  echo "The build will not fall back to an automatic Mac Team profile." >&2
  sed -n '1,20p' "$PROBE_ROOT/codesign.log" >&2
  exit 1
fi

codesign --verify --strict --verbose=2 "$PROBE_ROOT/probe" >/dev/null 2>&1 || {
  echo "Developer ID private-key probe produced an invalid signature" >&2
  exit 1
}

echo "Developer ID private-key access passed."

