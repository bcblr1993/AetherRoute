#!/bin/sh
set -eu

: "${AETHERROUTE_PRODUCT_ID:?missing AETHERROUTE_PRODUCT_ID}"
: "${AETHERROUTE_STATE_PATH:?missing AETHERROUTE_STATE_PATH}"
: "${AETHERROUTE_PEPPER_PATH:?missing AETHERROUTE_PEPPER_PATH}"
: "${AETHERROUTE_PUBLIC_KEY_PATH:?missing AETHERROUTE_PUBLIC_KEY_PATH}"
: "${AETHERROUTE_UPDATE_ENVELOPE_PATH:?missing AETHERROUTE_UPDATE_ENVELOPE_PATH}"
: "${AETHERROUTE_SIGNER_SOCKET_PATH:?missing AETHERROUTE_SIGNER_SOCKET_PATH}"

service_pid=
nginx_pid=

shutdown() {
  trap - HUP INT TERM
  if [ -n "$service_pid" ]; then
    kill -TERM "$service_pid" 2>/dev/null || true
  fi
  if [ -n "$nginx_pid" ]; then
    kill -TERM "$nginx_pid" 2>/dev/null || true
  fi
  if [ -n "$service_pid" ]; then
    wait "$service_pid" 2>/dev/null || true
  fi
  if [ -n "$nginx_pid" ]; then
    wait "$nginx_pid" 2>/dev/null || true
  fi
}
trap shutdown EXIT HUP INT TERM

/usr/local/bin/aetherroute-distribution serve \
  -product-id "$AETHERROUTE_PRODUCT_ID" \
  -state "$AETHERROUTE_STATE_PATH" \
  -pepper "$AETHERROUTE_PEPPER_PATH" \
  -public-key "$AETHERROUTE_PUBLIC_KEY_PATH" \
  -update-envelope "$AETHERROUTE_UPDATE_ENVELOPE_PATH" \
  -signer-socket "$AETHERROUTE_SIGNER_SOCKET_PATH" \
  -listen 127.0.0.1:9080 \
  -trust-forwarded-for &
service_pid=$!

nginx -g 'daemon off;' &
nginx_pid=$!

while kill -0 "$service_pid" 2>/dev/null \
  && kill -0 "$nginx_pid" 2>/dev/null; do
  sleep 1
done

exit 1
