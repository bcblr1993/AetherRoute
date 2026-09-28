#!/bin/sh
set -eu

# Release gate: an idle keep-alive connection must survive the relay.
#
# Opens one TLS connection through whichever engine is active, sends a
# request, stays silent for IDLE_SECONDS, then sends a second request on the
# same connection. Both must be answered. The engine once closed every
# client flow after 60 seconds of silence, so clients that pool connections
# (Claude Code between tool calls) reused a dead connection and saw
# ECONNRESET. Run it with the TUN engine and again with the transparent proxy.
#
# Exit status: 0 both answered, 1 the idle connection was closed,
# 2 inconclusive (the first request never got through, so the path under
# test was not reached).

HOST=${AETHERROUTE_IDLE_REUSE_HOST:-api.anthropic.com}
IDLE_SECONDS=${AETHERROUTE_IDLE_REUSE_SECONDS:-75}
OPENSSL=${AETHERROUTE_IDLE_REUSE_OPENSSL:-/usr/bin/openssl}

case "$IDLE_SECONDS" in
  ''|*[!0-9]*) echo "idle seconds must be a positive integer" >&2; exit 64 ;;
esac
test "$IDLE_SECONDS" -gt 60 || {
  echo "idle seconds must exceed 60 to cover the regression" >&2
  exit 64
}
printf '%s\n' "$HOST" | grep -Eq '^[A-Za-z0-9.-]+$' || {
  echo "invalid host" >&2
  exit 64
}

request() {
  printf 'GET /v1/messages HTTP/1.1\r\nHost: %s\r\nUser-Agent: aetherroute-idle-reuse\r\nConnection: keep-alive\r\n\r\n' "$HOST"
}

# -no_ign_eof lets s_client exit once stdin closes, so the trailing sleep is
# the only wait for the second response and nothing can hang the gate.
responses=$(
  {
    request
    sleep "$IDLE_SECONDS"
    request
    sleep 15
  } | "$OPENSSL" s_client -quiet -no_ign_eof \
      -connect "$HOST:443" -servername "$HOST" 2>/dev/null \
    | tr -d '\r' | grep -Ec '^HTTP/1\.[01] [0-9]{3}' || true
)

case "$responses" in
  2) echo "idle keep-alive reuse: both requests answered after ${IDLE_SECONDS}s idle"; exit 0 ;;
  1) echo "idle keep-alive reuse: connection closed during ${IDLE_SECONDS}s idle"; exit 1 ;;
  *) echo "idle keep-alive reuse: inconclusive, first request not answered ($responses)"; exit 2 ;;
esac
