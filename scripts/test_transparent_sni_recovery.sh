#!/bin/sh
set -eu

# Release gate (transparent engine): an app that resolved the name itself
# must still reach the host its ClientHello names.
#
# Chrome resolves with its own DNS client, so the provider receives a bare IP
# and no hostname. Under poisoned DNS that IP belongs to an unrelated server;
# the engine once routed by it and Chrome could not open Google. curl's
# --connect-to reproduces this: it dials DECOY_IP directly while sending
# HOST as SNI and verifying HOST's certificate.
#
# Exit status: 0 routed by SNI, 1 routed by the decoy IP.

HOST=${AETHERROUTE_SNI_RECOVERY_HOST:-www.apple.com}
DECOY_IP=${AETHERROUTE_SNI_RECOVERY_DECOY_IP:-1.1.1.1}

printf '%s\n' "$HOST" | grep -Eq '^[A-Za-z0-9.-]+$' || {
  echo "invalid host" >&2
  exit 64
}
printf '%s\n' "$DECOY_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || {
  echo "decoy must be an IPv4 literal" >&2
  exit 64
}

code=$(curl --proxy '' -s -o /dev/null -w '%{http_code}' --max-time 15 \
  --connect-to "$HOST:443:$DECOY_IP:443" "https://$HOST/" 2>/dev/null) || code=000

case "$code" in
  000) echo "transparent SNI recovery: $HOST dialed at $DECOY_IP failed (routed by IP)"; exit 1 ;;
  *) echo "transparent SNI recovery: $HOST dialed at $DECOY_IP answered HTTP $code"; exit 0 ;;
esac
