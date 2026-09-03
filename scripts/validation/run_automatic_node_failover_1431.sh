#!/bin/sh
set -eu
umask 077

usage() {
  echo "usage: $0 /absolute/nonexistent/output-directory" >&2
  exit 64
}

test "$#" -eq 1 || usage
OUTPUT=$1
case "$OUTPUT" in /*) ;; *) usage ;; esac
test ! -e "$OUTPUT" || {
  echo "refusing to overwrite $OUTPUT" >&2
  exit 1
}

VM=chenxu@192.168.64.4
FIXTURE_HOST=192.168.64.1
LABEL_A=com.aetherroute.fixture.proxy.a.1431
LABEL_B=com.aetherroute.fixture.proxy.b.1431
PORT_A=59103
PORT_B=59104
DEAD_PORT=59999
PROBE=/tmp/aetherroute_provider_selection_probe_1431
PROBE_SHA=9b550398351a300a851f6ee2404cdae05d0491b8cb0ea4a50616ea230b8fec63
HASH_A=cdf43ab94e69b991163c34bb669814a6b32286a764ef38787a91af64521b735d
HASH_B=bb4dddba5c543fe2e856f779a150af10e2bf98e74e520d6d1f2275e1f9e6b268
GROUP=Route
EXPECTED_TUN_SHA=f6db1b082f66271b8e8db478cfbe6a3dd6e761a8252564785048ff7200041067
EXPECTED_TUN_CDHASH=13a5d5d8f469646f2857e04b617ae2ed0002d46d
EXPECTED_BUILD=2026081431
LOG_A=/Users/chenxu/Downloads/AetherRoute-1429-AutoFailover-Fixtures-v1/logs-1431/fixture-a.stderr.log
LOG_B=/Users/chenxu/Downloads/AetherRoute-1429-AutoFailover-Fixtures-v1/logs-1431/fixture-b.stderr.log

mkdir -p "$OUTPUT"
printf 'phase\tsample\tutc\tselected_sha256\tmember_count\tgoogle_v4\tgoogle_v6\n' >"$OUTPUT/samples.tsv"

pid_for_label() {
  launchctl print "gui/$(id -u)/$1" 2>/dev/null |
    awk '/^[[:space:]]*pid = [0-9]+$/{print $3;exit}'
}

PID_A=$(pid_for_label "$LABEL_A")
PID_B=$(pid_for_label "$LABEL_B")
test -n "$PID_A" && test -n "$PID_B" && test "$PID_A" -ne "$PID_B"
lsof -nP -a -p "$PID_A" -iTCP@"$FIXTURE_HOST":"$PORT_A" -sTCP:LISTEN >/dev/null
lsof -nP -a -p "$PID_B" -iTCP@"$FIXTURE_HOST":"$PORT_B" -sTCP:LISTEN >/dev/null
if nc -z -w 1 "$FIXTURE_HOST" "$DEAD_PORT" >/dev/null 2>&1; then
  echo "dead fixture unexpectedly listening" >&2
  exit 1
fi
test -f "$LOG_A" && test -f "$LOG_B"
LOG_A_OFFSET=$(wc -c <"$LOG_A" | tr -d ' ')
LOG_B_OFFSET=$(wc -c <"$LOG_B" | tr -d ' ')

test "$(ssh -o BatchMode=yes "$VM" "shasum -a 256 '$PROBE'" | awk '{print $1}')" = "$PROBE_SHA"

REMOTE_RUNTIME=$(ssh -o BatchMode=yes "$VM" /bin/sh -s <<'REMOTE'
set -eu
app=/Applications/AetherRoute.app
tun="$app/Contents/PlugIns/AetherRouteTunnel.appex/Contents/MacOS/AetherRouteTunnel"
pid=$(pgrep -f '/AetherRouteTunnel.appex/Contents/MacOS/AetherRouteTunnel' | head -1)
test -n "$pid"
build=$(defaults read "$app/Contents/Info" CFBundleVersion)
sha=$(shasum -a 256 "$tun" | awk '{print $1}')
cdhash=$(codesign -dv --verbose=4 "$tun" 2>&1 | awk -F= '/^CDHash=/{print $2;exit}')
vpn=$(scutil --nc list | awk '/com.aetherroute.desktop/{gsub(/[()*]/,"");print $1;exit}')
printf 'provider_pid=%s\napp_build=%s\ntun_sha256=%s\ntun_cdhash=%s\nvpn_status=%s\n' "$pid" "$build" "$sha" "$cdhash" "$vpn"
REMOTE
)
printf '%s\n' "$REMOTE_RUNTIME" >"$OUTPUT/runtime-before.txt"
PROVIDER_PID=$(printf '%s\n' "$REMOTE_RUNTIME" | awk -F= '$1=="provider_pid"{print $2}')
test "$(printf '%s\n' "$REMOTE_RUNTIME" | awk -F= '$1=="app_build"{print $2}')" = "$EXPECTED_BUILD"
test "$(printf '%s\n' "$REMOTE_RUNTIME" | awk -F= '$1=="tun_sha256"{print $2}')" = "$EXPECTED_TUN_SHA"
test "$(printf '%s\n' "$REMOTE_RUNTIME" | awk -F= '$1=="tun_cdhash"{print $2}')" = "$EXPECTED_TUN_CDHASH"
test "$(printf '%s\n' "$REMOTE_RUNTIME" | awk -F= '$1=="vpn_status"{print $2}')" = Connected

stopped_a=no
stopped_b=no
restore() {
  if test "$stopped_a" = yes; then kill -CONT "$PID_A" 2>/dev/null || true; fi
  if test "$stopped_b" = yes; then kill -CONT "$PID_B" 2>/dev/null || true; fi
}
trap restore EXIT HUP INT TERM

selection_json() {
  ssh -o BatchMode=yes "$VM" "$PROBE '$GROUP'"
}

selected_hash() {
  selection_json | plutil -extract selected_name_sha256 raw -o - -
}

member_count() {
  selection_json | plutil -extract member_count raw -o - -
}

remote_google() {
  ssh -o BatchMode=yes "$VM" /bin/sh -s <<'REMOTE'
set +e
v4=$(curl -4 --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 6 https://www.google.com/generate_204 2>/dev/null); r4=$?
v6=$(curl -6 --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 6 https://www.google.com/generate_204 2>/dev/null); r6=$?
printf '%s:%s\t%s:%s\n' "$v4" "$r4" "$v6" "$r6"
REMOTE
}

sample() {
  phase=$1
  index=$2
  json=$(selection_json)
  selected=$(printf '%s\n' "$json" | plutil -extract selected_name_sha256 raw -o - -)
  count=$(printf '%s\n' "$json" | plutil -extract member_count raw -o - -)
  google=$(remote_google)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$phase" "$index" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$selected" "$count" "$google" >>"$OUTPUT/samples.tsv"
}

INITIAL=$(selected_hash)
case "$INITIAL" in
  "$HASH_A") FIRST_PID=$PID_A; FIRST_NAME=A; OTHER_HASH=$HASH_B ;;
  "$HASH_B") FIRST_PID=$PID_B; FIRST_NAME=B; OTHER_HASH=$HASH_A ;;
  *) echo "unexpected initial selection hash" >&2; exit 1 ;;
esac
test "$(member_count)" -eq 2
sample baseline 1
sample baseline 2

if test "$FIRST_NAME" = A; then stopped_a=yes; else stopped_b=yes; fi
kill -STOP "$FIRST_PID"
printf 'first_stopped=%s pid=%s utc=%s\n' "$FIRST_NAME" "$FIRST_PID" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$OUTPUT/faults.txt"

FIRST_FAILOVER=none
i=1
while test "$i" -le 45; do
  sample first_failover "$i" || true
  current=$(tail -1 "$OUTPUT/samples.tsv" | awk -F '\t' '{print $4}')
  v4=$(tail -1 "$OUTPUT/samples.tsv" | awk -F '\t' '{print $6}')
  v6=$(tail -1 "$OUTPUT/samples.tsv" | awk -F '\t' '{print $7}')
  if test "$current" = "$OTHER_HASH" && test "$v4" = 204:0 && test "$v6" = 204:0; then
    FIRST_FAILOVER=$current
    break
  fi
  i=$((i + 1))
  sleep 2
done
test "$FIRST_FAILOVER" = "$OTHER_HASH"

kill -CONT "$FIRST_PID"
if test "$FIRST_NAME" = A; then stopped_a=no; else stopped_b=no; fi
sleep 2

if test "$FIRST_NAME" = A; then
  SECOND_PID=$PID_B
  SECOND_NAME=B
  stopped_b=yes
else
  SECOND_PID=$PID_A
  SECOND_NAME=A
  stopped_a=yes
fi
kill -STOP "$SECOND_PID"
printf 'second_stopped=%s pid=%s utc=%s\n' "$SECOND_NAME" "$SECOND_PID" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$OUTPUT/faults.txt"

SECOND_FAILOVER=none
i=1
while test "$i" -le 45; do
  sample second_failover "$i" || true
  current=$(tail -1 "$OUTPUT/samples.tsv" | awk -F '\t' '{print $4}')
  v4=$(tail -1 "$OUTPUT/samples.tsv" | awk -F '\t' '{print $6}')
  v6=$(tail -1 "$OUTPUT/samples.tsv" | awk -F '\t' '{print $7}')
  if test "$current" = "$INITIAL" && test "$v4" = 204:0 && test "$v6" = 204:0; then
    SECOND_FAILOVER=$current
    break
  fi
  i=$((i + 1))
  sleep 2
done
test "$SECOND_FAILOVER" = "$INITIAL"

kill -CONT "$SECOND_PID"
if test "$SECOND_NAME" = A; then stopped_a=no; else stopped_b=no; fi
sleep 2
sample recovered 1
sample recovered 2
sample recovered 3

ssh -o BatchMode=yes "$VM" /bin/sh -s <<'REMOTE' >"$OUTPUT/final-dns.txt"
set -eu
nonce="aetherroute-1431-$(uuidgen | tr A-Z a-z).example.com"
dig -4 @192.168.64.1 "$nonce" A +time=5 +tries=1 +retry=0 +noall +comments +stats
dig -4 @192.168.64.1 "tcp-$nonce" A +tcp +time=5 +tries=1 +retry=0 +noall +comments +stats
REMOTE
ssh -o BatchMode=yes "$VM" \
  '/Users/chenxu/Desktop/AetherRoute-1431-TUN-Cycle-Tools-v1/aetherroute_stun_udp_probe_1424.sh stun.l.google.com 19302 8' \
  >"$OUTPUT/final-stun.txt" 2>&1

tail -c +$((LOG_A_OFFSET + 1)) "$LOG_A" >"$OUTPUT/fixture-a-delta.log"
tail -c +$((LOG_B_OFFSET + 1)) "$LOG_B" >"$OUTPUT/fixture-b-delta.log"
ssh -o BatchMode=yes "$VM" /bin/sh -s <<REMOTE >"$OUTPUT/runtime-after.txt"
set -eu
pid=\$(pgrep -f '/AetherRouteTunnel.appex/Contents/MacOS/AetherRouteTunnel' | head -1)
status=\$(scutil --nc list | awk '/com.aetherroute.desktop/{gsub(/[()*]/,"");print \$1;exit}')
printf 'provider_pid=%s\nvpn_status=%s\n' "\$pid" "\$status"
REMOTE

AFTER_PID=$(awk -F= '$1=="provider_pid"{print $2}' "$OUTPUT/runtime-after.txt")
AFTER_STATUS=$(awk -F= '$1=="vpn_status"{print $2}' "$OUTPUT/runtime-after.txt")
MAX_CONSECUTIVE_FAILURES=$(awk -F '\t' '
  NR==1{next}
  $6=="204:0" && $7=="204:0" {run=0;next}
  {run++;if(run>max)max=run}
  END{print max+0}
' "$OUTPUT/samples.tsv")
FINAL_THREE_PASS=$(tail -3 "$OUTPUT/samples.tsv" | awk -F '\t' '
  $6!="204:0" || $7!="204:0" {bad++}
  END{print (bad+0)==0?"yes":"no"}
')
DNS_FINAL=$(test "$(grep -c 'status: NOERROR' "$OUTPUT/final-dns.txt")" -eq 2 && echo passed || echo failed)
STUN_FINAL=$(grep -q '^result=passed$' "$OUTPUT/final-stun.txt" && echo passed || echo failed)

GATE=failed
if test "$FIRST_FAILOVER" = "$OTHER_HASH" \
  && test "$SECOND_FAILOVER" = "$INITIAL" \
  && test "$AFTER_PID" = "$PROVIDER_PID" \
  && test "$AFTER_STATUS" = Connected \
  && test "$MAX_CONSECUTIVE_FAILURES" -le 3 \
  && test "$FINAL_THREE_PASS" = yes \
  && test "$DNS_FINAL" = passed \
  && test "$STUN_FINAL" = passed; then
  GATE=passed
fi

{
  printf 'schema=1\n'
  printf 'completed_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'initial_selected_sha256=%s\n' "$INITIAL"
  printf 'first_failover_selected_sha256=%s\n' "$FIRST_FAILOVER"
  printf 'second_failover_selected_sha256=%s\n' "$SECOND_FAILOVER"
  printf 'provider_pid_stable=%s\n' "$(test "$AFTER_PID" = "$PROVIDER_PID" && echo yes || echo no)"
  printf 'max_consecutive_google_failures=%s\n' "$MAX_CONSECUTIVE_FAILURES"
  printf 'final_three_pass=%s\n' "$FINAL_THREE_PASS"
  printf 'dns_final=%s\n' "$DNS_FINAL"
  printf 'stun_final=%s\n' "$STUN_FINAL"
  printf 'release_gate=%s\n' "$GATE"
} >"$OUTPUT/result.txt"

cp "$0" "$OUTPUT/run_automatic_node_failover_1431.sh"
chmod 400 "$OUTPUT/run_automatic_node_failover_1431.sh"
(cd "$OUTPUT" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print |
  LC_ALL=C sort | while IFS= read -r path; do
    shasum -a 256 "${path#./}"
  done >SHA256SUMS)

test "$GATE" = passed || {
  echo "automatic failover failed; evidence preserved at $OUTPUT" >&2
  exit 1
}
echo "automatic failover passed: $OUTPUT"
