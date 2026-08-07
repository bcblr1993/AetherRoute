#!/bin/sh
set -eu

socket=/run/aetherroute/receipt-signer.sock
if [ -e "$socket" ] || [ -L "$socket" ]; then
  test -S "$socket" || {
    echo "refusing to replace a non-socket signer path" >&2
    exit 1
  }
  identity=$(stat -c '%u:%g:%a' "$socket")
  test "$identity" = 10001:12000:660 || {
    echo "refusing to replace a signer socket with unexpected ownership or mode" >&2
    exit 1
  }
  rm "$socket"
fi

exec /usr/local/bin/aetherroute-distribution signer "$@"
