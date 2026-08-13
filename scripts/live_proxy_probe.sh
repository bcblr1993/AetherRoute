#!/bin/sh
set -eu

# Drives the Direct core with a real profile and a loopback SOCKS5/HTTP
# listener, then reports whether traffic actually egresses through the selected
# node.
#
# This is the seam the project was missing. Every other gate runs on loopback
# peers with networking denied, so none of them can answer "does the proxy
# carry real traffic". Answering that previously required a signed, notarized
# build and a manual browser check, a 40-minute round trip. This answers it in
# seconds and cleanly separates two very different failure domains:
#
#   probe works, app does not  -> the fault is in the Swift NetworkExtension
#                                 integration, not in routing or the protocol
#   probe fails                -> the fault is in the profile, the node, or the
#                                 Rust core
#
# It binds loopback only and never changes system proxy, DNS, or routes.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROFILE=${1:-}
GROUP=${2:-PROXY}
MEMBER=${3:-}
PORT=${AETHERROUTE_PROBE_PORT:-17890}

# Unlike every other gate in this repository, this one reaches the real
# network and a real node, so it requires the same explicit opt-in the other
# authorized live checks use.
if [ "${AETHERROUTE_ALLOW_LIVE_PROBE:-NO}" != YES ]; then
  echo "Refusing to run: this gate contacts the real network." >&2
  echo "Set AETHERROUTE_ALLOW_LIVE_PROBE=YES to authorize it." >&2
  exit 78
fi

if [ -z "$PROFILE" ]; then
  echo "usage: $0 /absolute/profile.yaml [GROUP] [MEMBER_TO_SELECT]" >&2
  echo "  env: AETHERROUTE_ALLOW_LIVE_PROBE=YES (required)" >&2
  echo "       AETHERROUTE_PROBE_PORT (default 17890)" >&2
  exit 64
fi
test -f "$PROFILE" || { echo "profile not found: $PROFILE" >&2; exit 66; }

CORE="$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a"
test -f "$CORE" || {
  echo "Direct core artifact missing. Run scripts/build_direct_core.sh" >&2
  exit 1
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-live-probe.XXXXXX")
PROBE_PID=""
cleanup() {
  [ -n "$PROBE_PID" ] && kill "$PROBE_PID" 2>/dev/null || true
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$WORK/runtime"
# Rule matching needs the geo databases the app already maintains.
RESOURCES="$HOME/Library/Group Containers/group.com.aetherroute.desktop/Library/Application Support/AetherRoute/RoutingResources"
for NAME in GeoSite.dat Country.mmdb; do
  # The container is protected storage, so the copy can be denied even when
  # the file exists. A profile without GEOSITE/GEOIP rules does not need these
  # at all, so a failure here is a warning rather than a stop.
  if [ -f "$RESOURCES/$NAME" ] \
    && cp "$RESOURCES/$NAME" "$WORK/runtime/$NAME" 2>/dev/null; then
    continue
  fi
  echo "warning: $NAME unavailable; GEOSITE/GEOIP rules will not match" >&2
done

clang -std=c17 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/live_proxy_probe.c" \
  "$CORE" \
  -framework Security -framework SystemConfiguration \
  -framework CoreFoundation -framework CoreServices -lresolv \
  -o "$WORK/live_proxy_probe"

"$WORK/live_proxy_probe" "$PROFILE" "$WORK/runtime" "$PORT" "$GROUP" ${MEMBER:+"$MEMBER"} \
  >"$WORK/probe.log" 2>&1 &
PROBE_PID=$!

READY=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if grep -q '^READY ' "$WORK/probe.log" 2>/dev/null; then READY=1; break; fi
  if ! kill -0 "$PROBE_PID" 2>/dev/null; then break; fi
  sleep 1
done
cat "$WORK/probe.log"
test "$READY" -eq 1 || { echo "probe failed to start" >&2; exit 1; }

echo
echo "--- egress comparison ---"
DIRECT_IP=$(curl -s --max-time 15 https://api.ipify.org || echo "unreachable")
PROXY_IP=$(curl -s --max-time 25 -x "socks5h://127.0.0.1:$PORT" \
  https://api.ipify.org || echo "unreachable")
printf 'direct egress IP : %s\n' "$DIRECT_IP"
printf 'proxied egress IP: %s\n' "$PROXY_IP"

echo
echo "--- reachability through the proxy ---"
STATUS=0
for TARGET in https://www.google.com https://www.youtube.com; do
  CODE=$(curl -s -o /dev/null -w '%{http_code} %{time_total}s' --max-time 25 \
    -x "socks5h://127.0.0.1:$PORT" "$TARGET" || echo "000 timeout")
  printf '%-32s %s\n' "$TARGET" "$CODE"
  case "$CODE" in 2*|3*) ;; *) STATUS=1 ;; esac
done

echo
if [ "$STATUS" -eq 0 ]; then
  echo "PASS: the core routes real traffic through the selected node."
  echo "If the app still cannot browse, the fault is in the Swift"
  echo "NetworkExtension integration, not in the core or the profile."
else
  echo "FAIL: the core could not carry traffic. Check the profile, the"
  echo "selected node, and the node's own reachability before looking"
  echo "at the NetworkExtension layer."
fi
exit "$STATUS"
