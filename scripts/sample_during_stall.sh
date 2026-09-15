#!/bin/sh
# Samples the tunnel provider *while a request is stalled*, to show where the
# engine actually is during the 1.0.5 slowdown.
#
# Everything observable from outside has been ruled out: the hysteria2 QUIC
# connection stays up (same source port throughout), fake-ip DNS answers in
# ~1.3ms, the DIRECT path never degrades, link load does not correlate, and the
# app logs nothing at all. What is left is inside the engine, and the engine
# ships with log level Silent - so a stack sample taken mid-stall is the only
# way to see it.
#
# Method: fire a request in the background; if it has not finished after
# STALL_AFTER seconds this one is stalling, so sample immediately. A fast
# request is skipped, so every captured sample is a real stall.
#
#   sudo sh scripts/sample_during_stall.sh
#
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-$ROOT/outputs/105-diagnosis/stall-samples-$(date '+%Y%m%d-%H%M%S')}
WANT=${WANT:-4}            # stalls to capture
STALL_AFTER=${STALL_AFTER:-1.5}
MAX_ROUNDS=${MAX_ROUNDS:-40}

[ "$(id -u)" -eq 0 ] || { echo "must run as root (sudo sh $0)" >&2; exit 1; }
REAL_USER=${SUDO_USER:-$(stat -f '%Su' /dev/console)}
mkdir -p "$OUT"; chown "$REAL_USER" "$OUT" 2>/dev/null

PID=$(pgrep -x com.aetherroute.desktop.tunnel | head -1)
[ -n "$PID" ] || { echo "tunnel provider is not running" >&2; exit 1; }
APP_PID=$(pgrep -x AetherRoute | head -1)
echo "provider pid=$PID  app pid=${APP_PID:-none}  target stalls=$WANT"
echo "out=$OUT"
echo

got=0
round=0
while [ "$got" -lt "$WANT" ] && [ "$round" -lt "$MAX_ROUNDS" ]; do
  round=$((round + 1))
  RESULT="$OUT/.curl-$round"

  su "$REAL_USER" -c "curl --noproxy '*' -sS -o /dev/null \
    -w '%{time_appconnect} %{time_total} %{http_code}' --max-time 25 \
    https://www.google.com/generate_204 >'$RESULT' 2>&1" &
  CURL_PID=$!

  # Give a healthy request time to finish; whatever is left is stalling.
  sleep "$STALL_AFTER"

  if kill -0 "$CURL_PID" 2>/dev/null; then
    got=$((got + 1))
    echo "round $round: STALLED - sampling (#$got)"
    sample "$PID" 3 -file "$OUT/stall-$got-provider.txt" >/dev/null 2>&1
    [ -n "$APP_PID" ] && sample "$APP_PID" 2 -file "$OUT/stall-$got-app.txt" >/dev/null 2>&1
    wait "$CURL_PID" 2>/dev/null
    printf '  request result: %s\n' "$(cat "$RESULT" 2>/dev/null)"
    cp "$RESULT" "$OUT/stall-$got-timing.txt" 2>/dev/null
  else
    wait "$CURL_PID" 2>/dev/null
    printf 'round %s: fast (%s)\n' "$round" "$(cat "$RESULT" 2>/dev/null)"
  fi
  rm -f "$RESULT"
  sleep 1
done

# A baseline sample taken while nothing is stalled, to diff against.
echo
echo "capturing an idle reference sample"
sample "$PID" 3 -file "$OUT/reference-idle-provider.txt" >/dev/null 2>&1

chown -R "$REAL_USER" "$OUT" 2>/dev/null
echo
echo "captured $got stall samples over $round rounds"
echo "$OUT"
