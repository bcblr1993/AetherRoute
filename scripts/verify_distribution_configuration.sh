#!/bin/sh
set -eu

# This gate is shared by the archive metadata check and production release.
# All inputs are public build metadata; never print configured endpoint values.
MODE=${1:-}
PRODUCT=${2:-}
LICENSE_URL=${3:-}
UPDATE_URL=${4:-}
PUBLIC_KEY=${5:-}

fail() { echo "Distribution configuration rejected: $*" >&2; exit 64; }
printf '%s\n' "$PRODUCT" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$' \
  || fail "invalid product identifier"
case "$MODE" in
  free)
    test -z "$LICENSE_URL$UPDATE_URL$PUBLIC_KEY" \
      || fail "free distribution must not include licensing or update-service configuration"
    ;;
  licensed)
    test -n "$LICENSE_URL" || fail "licensed distribution requires a license service URL"
    test -n "$UPDATE_URL" || fail "licensed distribution requires an update manifest URL"
    test -n "$PUBLIC_KEY" || fail "licensed distribution requires a signing public key"
    for url in "$LICENSE_URL" "$UPDATE_URL"; do
      case "$url" in https://?*) ;; *) fail "distribution services must use HTTPS" ;; esac
      if printf '%s\n' "$url" | grep -Eq '[@#[:space:]]'; then
        fail "distribution service URL contains credentials, fragment, or whitespace"
      fi
    done
    key_bytes=$(printf '%s' "$PUBLIC_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')
    test "$key_bytes" -eq 32 || fail "signing public key must decode to 32 bytes"
    ;;
  *) fail "mode must be free or licensed" ;;
esac
