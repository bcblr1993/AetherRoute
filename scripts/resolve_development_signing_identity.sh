#!/bin/sh
set -eu

identity=${AETHERROUTE_DEVELOPMENT_SIGNING_IDENTITY:-}
if [ -z "$identity" ]; then
  identity=${AETHERROUTE_UI_TEST_SIGNING_IDENTITY:-}
fi
if [ -z "$identity" ]; then
  identity=$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk '/"Apple Development:/ { print $2; exit }'
  )
fi

if ! printf '%s\n' "$identity" | grep -Eq '^[[:xdigit:]]{40}$'; then
  echo "A trusted Apple Development identity is required for macOS UI runs." >&2
  echo "An ad-hoc visible app can be rejected by Gatekeeper as damaged." >&2
  echo "Create an Apple Development certificate in Xcode, then rerun." >&2
  exit 77
fi

if ! security find-identity -v -p codesigning 2>/dev/null \
  | grep -Eq "^[[:space:]]*[0-9]+\)[[:space:]]+$identity[[:space:]]+\"Apple Development:"; then
  echo "The requested Apple Development identity is not valid in the login keychain." >&2
  exit 77
fi

printf '%s\n' "$identity"

