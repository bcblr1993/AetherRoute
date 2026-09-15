#!/bin/sh
# Decides whether the 1.0.5 slowdown is the Hysteria2 QUIC connection being torn
# down and rebuilt, or something else entirely.
#
# v1.0.5 added a generation check to the hysteria2 outbound: whenever the global
# network generation changes, it closes the live QUIC connection and dials a new
# one. A rebuild costs a QUIC handshake plus Hysteria2 auth, which matches the
# multi-second stalls we measured. v1.0.4 has no such code.
#
# The test: capture UDP on the physical uplink while probing the proxied path
# every 3s. QUIC "Initial" packets mark a *new* connection being established.
#   - Initials clustered at the slow samples  -> rebuild confirmed, 1.0.5 regression
#   - Slow samples with no Initials           -> connection kept, look elsewhere
#
# Needs root for the capture:
#   sudo sh scripts/verify_quic_rebuild.sh
#
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-$ROOT/outputs/105-diagnosis/quic-verify-$(date '+%Y%m%d-%H%M%S')}
SAMPLES=${SAMPLES:-25}

[ "$(id -u)" -eq 0 ] || { echo "must run as root (sudo sh $0)" >&2; exit 1; }

# Drop privileges for the probes so curl behaves like a normal app.
REAL_USER=${SUDO_USER:-$(stat -f '%Su' /dev/console)}
mkdir -p "$OUT"
chown "$REAL_USER" "$OUT" 2>/dev/null

PHYS=$(netstat -rn -f inet 2>/dev/null |
  awk '$1=="default" && $NF !~ /^utun/ {print $NF; exit}')
[ -n "$PHYS" ] || { echo "cannot find the physical uplink" >&2; exit 1; }
echo "uplink=$PHYS  samples=$SAMPLES  out=$OUT"

# Everything except the known non-proxy chatter: mDNS, ZeroTier, Tailscale,
# Kerberos, DHCPv6. Whatever Hysteria2 uses is in what remains.
FILTER='udp and not port 5353 and not port 9993 and not port 41641 and not port 88 and not port 547 and not port 2200'

tcpdump -i "$PHYS" -n -tt -s 96 "$FILTER" >"$OUT/udp.txt" 2>"$OUT/tcpdump.err" &
CAP=$!
sleep 3

: >"$OUT/samples.txt"
i=1
while [ "$i" -le "$SAMPLES" ]; do
  ts=$(perl -e 'print time()')
  line=$(su "$REAL_USER" -c "curl --noproxy '*' -sS -o /dev/null \
    -w '%{time_appconnect} %{time_total} %{http_code}' --max-time 25 \
    https://www.google.com/generate_204" 2>/dev/null)
  set -- $line
  printf '%s tls=%s total=%s code=%s\n' "$ts" "${1:-0}" "${2:-0}" "${3:-000}" \
    >>"$OUT/samples.txt"
  printf '%2d  epoch=%s tls=%-9s total=%-9s code=%s\n' "$i" "$ts" "${1:-0}" "${2:-0}" "${3:-000}"
  i=$((i + 1))
  sleep 3
done

sleep 2
kill -INT "$CAP" 2>/dev/null
wait "$CAP" 2>/dev/null
chown "$REAL_USER" "$OUT"/* 2>/dev/null

echo
echo "================= ANALYSIS ================="
# tcpdump labels QUIC long-header packets; a fresh connection starts with one.
grep -ci 'initial' "$OUT/udp.txt" >/dev/null 2>&1
INITIALS=$(grep -ci 'initial' "$OUT/udp.txt" 2>/dev/null || echo 0)
TOTALPKT=$(wc -l <"$OUT/udp.txt" 2>/dev/null | tr -d ' ')
echo "UDP packets captured : $TOTALPKT"
echo "QUIC Initial packets : $INITIALS"
echo

awk '
  { split($2,a,"="); tls=a[2]+0
    split($1,b,"");  ts=$1+0
    slow = (tls > 1.5)
    printf "%s\t%s\t%s\n", ts, tls, (slow ? "SLOW" : "ok")
  }
' "$OUT/samples.txt" >"$OUT/verdict.tsv"

echo "slow samples and QUIC Initials within +/-3s of each other:"
MATCH=0; SLOW=0
while IFS="$(printf '\t')" read -r ts tls flag; do
  [ "$flag" = "SLOW" ] || continue
  SLOW=$((SLOW + 1))
  near=$(awk -v t="$ts" 'tolower($0) ~ /initial/ { d = $1 - t; if (d < 0) d = -d; if (d <= 3) n++ } END { print n+0 }' "$OUT/udp.txt")
  printf '  epoch=%s tls=%-8s QUIC-Initials nearby=%s\n' "$ts" "$tls" "$near"
  [ "$near" -gt 0 ] && MATCH=$((MATCH + 1))
done <"$OUT/verdict.tsv"

echo
echo "slow samples: $SLOW   of which had a QUIC handshake alongside: $MATCH"
if [ "$SLOW" -eq 0 ]; then
  echo "VERDICT: no slow sample occurred - rerun when the slowdown is present."
elif [ "$MATCH" -eq "$SLOW" ] && [ "$SLOW" -gt 1 ]; then
  echo "VERDICT: every slow sample coincided with a QUIC handshake."
  echo "         The connection is being rebuilt - consistent with the 1.0.5"
  echo "         generation check in hysteria2/outbound/mod.rs."
elif [ "$MATCH" -eq 0 ]; then
  echo "VERDICT: slow samples had NO QUIC handshake. The connection is being"
  echo "         kept; the stall is elsewhere (server or path), not a rebuild."
else
  echo "VERDICT: mixed - $MATCH of $SLOW. Inspect udp.txt around the slow epochs."
fi
echo
echo "raw: $OUT/udp.txt  $OUT/samples.txt"
