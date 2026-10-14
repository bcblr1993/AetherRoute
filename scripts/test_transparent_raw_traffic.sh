#!/bin/sh
set -eu

# Release gate (transparent engine): verifies non-TLS plain HTTP (port 80) and
# bare IP destination routing without TLS SNI.
#
# When an application connects directly to an IPv4/IPv6 address or issues a
# plain HTTP request, NEAppProxyTCPFlow has no remoteHostname and there is no
# TLS ClientHello SNI to sniff. FlowCore must route the flow based on IP-CIDR
# rules or direct policy without hanging, stalling, or connection resets.

TIMEOUT_SECONDS=${AETHERROUTE_TRANSPARENT_RAW_TIMEOUT:-10}

clean_curl() {
  env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
    -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
    curl -q "$@"
}

# 1. Plain HTTP on port 80 (has Host header, no TLS / no SNI)
code_http=$(clean_curl --proxy '' -s -o /dev/null -w '%{http_code}' \
  --max-time "$TIMEOUT_SECONDS" "http://cp.cloudflare.com/generate_204" 2>/dev/null || echo "000")

if [ "$code_http" != "204" ]; then
  echo "transparent raw traffic: plain HTTP/80 probe failed (HTTP $code_http, expected 204)" >&2
  exit 1
fi

# 2. Bare IP connection without domain or SNI (dialing 1.1.1.1:80 directly)
code_ip=$(clean_curl --proxy '' -s -o /dev/null -w '%{http_code}' \
  --max-time "$TIMEOUT_SECONDS" "http://1.1.1.1/" 2>/dev/null || echo "000")

case "$code_ip" in
  000)
    echo "transparent raw traffic: bare IP dial to 1.1.1.1:80 timed out or was reset (HTTP 000)" >&2
    exit 1
    ;;
  *)
    echo "transparent raw traffic: plain HTTP/80 answered 204; bare IP 1.1.1.1:80 answered HTTP $code_ip"
    exit 0
    ;;
esac
