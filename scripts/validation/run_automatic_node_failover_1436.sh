#!/bin/sh
set -eu
umask 077

usage() {
  echo "usage: $0 /absolute/nonexistent/evidence-directory A|B" >&2
  exit 64
}

test "$#" -eq 2 || usage
OUTPUT=$1
INITIAL_FIXTURE=$2
case "$OUTPUT" in /*) ;; *) usage ;; esac
case "$INITIAL_FIXTURE" in A|B) ;; *) usage ;; esac
test ! -e "$OUTPUT" || {
  echo "refusing to overwrite evidence: $OUTPUT" >&2
  exit 1
}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VM=chenxu@192.168.64.6
FIXTURE_HOST=192.168.64.1
LABEL_A=com.aetherroute.fixture.proxy.a.1431
LABEL_B=com.aetherroute.fixture.proxy.b.1431
PORT_A=59103
PORT_B=59104
LOG_A=/Users/chenxu/Downloads/AetherRoute-1429-AutoFailover-Fixtures-v1/logs-1431/fixture-a.stderr.log
LOG_B=/Users/chenxu/Downloads/AetherRoute-1429-AutoFailover-Fixtures-v1/logs-1431/fixture-b.stderr.log
EXPECTED_BUILD=${EXPECTED_BUILD:-2026081436}
EXPECTED_APP_CDHASH=${EXPECTED_APP_CDHASH:-8019738e8034743d22af7bab70d4e2ae8cd02523}
EXPECTED_TUN_CDHASH=${EXPECTED_TUN_CDHASH:-07d9eae8d8210af21e87031e2c156c7fc26417e4}
EXPECTED_TUN_SHA=${EXPECTED_TUN_SHA:-1cf02eb0f12c39c4fd3b67eaf3fcf177ade288ca7c05b8637af21ae4f7f10821}
EXPECTED_DMG_SHA=${EXPECTED_DMG_SHA:-01915d663a2e1d787808b3006c8e7ad17196e872ca242b4fa02e1cf815bf04fc}
CANDIDATE=${CANDIDATE:-/Users/chenxu/Downloads/AetherRoute-1.0.0-build-2026081436-Notarized-Test-Candidate}
MANIFEST=${MANIFEST:-$CANDIDATE/AetherRoute-1.0.0-build-$EXPECTED_BUILD-arm64-Notarized-Test.json}
DMG=${DMG:-$CANDIDATE/AetherRoute-1.0.0-build-$EXPECTED_BUILD-arm64-Notarized-Test.dmg}

pid_for_label() {
  launchctl print "gui/$(id -u)/$1" 2>/dev/null |
    awk '/^[[:space:]]*pid = [0-9]+$/{print $3;exit}'
}

require_listener() {
  pid=$1
  port=$2
  lsof -nP -a -p "$pid" -iTCP@"$FIXTURE_HOST":"$port" \
    -sTCP:LISTEN >/dev/null
}

test -f "$MANIFEST" && test -f "$DMG"
test "$(shasum -a 256 "$DMG" | awk '{print $1}')" = "$EXPECTED_DMG_SHA"
test "$(jq -r .build "$MANIFEST")" = "$EXPECTED_BUILD"
test "$(jq -r .notarization.status "$MANIFEST")" = Accepted
test "$(jq -r .signing.app.cdhash "$MANIFEST")" = "$EXPECTED_APP_CDHASH"
test "$(jq -r .signing.packetTunnel.cdhash "$MANIFEST")" = "$EXPECTED_TUN_CDHASH"
test "$(jq -r .signing.packetTunnel.executableSHA256 "$MANIFEST")" = "$EXPECTED_TUN_SHA"

PID_A=$(pid_for_label "$LABEL_A")
PID_B=$(pid_for_label "$LABEL_B")
test -n "$PID_A" && test -n "$PID_B" && test "$PID_A" -ne "$PID_B"
require_listener "$PID_A" "$PORT_A"
require_listener "$PID_B" "$PORT_B"
test -f "$LOG_A" && test -f "$LOG_B"

mkdir -p "$OUTPUT"
printf 'phase\tsample\tutc\tgoogle_v4\tgoogle_v6\n' >"$OUTPUT/samples.tsv"
REMOTE_LOG_START=$(ssh -o BatchMode=yes "$VM" "date '+%Y-%m-%d %H:%M:%S'")

REMOTE_RUNTIME=$(ssh -o BatchMode=yes "$VM" /bin/zsh -s <<'REMOTE'
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
app=/Applications/AetherRoute.app
running_pid=$(pgrep -f '/Library/SystemExtensions/.*/com.aetherroute.desktop.tunnel.systemextension/Contents/MacOS/com.aetherroute.desktop.tunnel' | head -1)
test -n "$running_pid"
running_path=$(ps -p "$running_pid" -o command=)
running_bundle=${running_path%/Contents/MacOS/*}
printf 'app_build='; /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist"
printf 'app_cdhash='; codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '$1 == "CDHash" {print $2;exit}'
printf 'provider_pid=%s\n' "$running_pid"
printf 'tun_sha256='; shasum -a 256 "$running_path" | awk '{print $1}'
printf 'tun_cdhash='; codesign -dv --verbose=4 "$running_bundle" 2>&1 | awk -F= '$1 == "CDHash" {print $2;exit}'
printf 'vpn_status='; scutil --nc status AetherRoute | head -1
REMOTE
)
printf '%s\n' "$REMOTE_RUNTIME" >"$OUTPUT/runtime-before.txt"
PROVIDER_PID=$(printf '%s\n' "$REMOTE_RUNTIME" | awk -F= '$1=="provider_pid"{print $2}')
test "$(printf '%s\n' "$REMOTE_RUNTIME" | awk -F= '$1=="app_build"{print $2}')" = "$EXPECTED_BUILD"
test "$(printf '%s\n' "$REMOTE_RUNTIME" | awk -F= '$1=="app_cdhash"{print $2}')" = "$EXPECTED_APP_CDHASH"
test "$(printf '%s\n' "$REMOTE_RUNTIME" | awk -F= '$1=="tun_sha256"{print $2}')" = "$EXPECTED_TUN_SHA"
test "$(printf '%s\n' "$REMOTE_RUNTIME" | awk -F= '$1=="tun_cdhash"{print $2}')" = "$EXPECTED_TUN_CDHASH"
test "$(printf '%s\n' "$REMOTE_RUNTIME" | awk -F= '$1=="vpn_status"{print $2}')" = Connected

stopped_a=no
stopped_b=no
restore_fixtures() {
  if test "$stopped_a" = yes; then kill -CONT "$PID_A" 2>/dev/null || true; fi
  if test "$stopped_b" = yes; then kill -CONT "$PID_B" 2>/dev/null || true; fi
}
trap restore_fixtures EXIT HUP INT TERM

remote_google() {
  ssh -o BatchMode=yes "$VM" /bin/sh -s <<'REMOTE'
set +e
v4_file=$(mktemp /tmp/aetherroute-v4.XXXXXX)
v6_file=$(mktemp /tmp/aetherroute-v6.XXXXXX)
trap 'rm -f "$v4_file" "$v6_file"' EXIT HUP INT TERM
(curl -4 --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 7 https://www.google.com/generate_204 >"$v4_file" 2>/dev/null; printf ':%s' "$?" >>"$v4_file") &
p4=$!
(curl -6 --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 7 https://www.google.com/generate_204 >"$v6_file" 2>/dev/null; printf ':%s' "$?" >>"$v6_file") &
p6=$!
wait "$p4"; wait "$p6"
printf '%s\t%s\n' "$(cat "$v4_file")" "$(cat "$v6_file")"
REMOTE
}

sample() {
  phase=$1
  index=$2
  google=$(remote_google)
  printf '%s\t%s\t%s\t%s\n' \
    "$phase" "$index" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$google" \
    >>"$OUTPUT/samples.tsv"
}

wait_for_healthy_failover() {
  phase=$1
  i=1
  while test "$i" -le 30; do
    sample "$phase" "$i" || true
    last=$(tail -1 "$OUTPUT/samples.tsv")
    v4=$(printf '%s\n' "$last" | awk -F '\t' '{print $4}')
    v6=$(printf '%s\n' "$last" | awk -F '\t' '{print $5}')
    if test "$v4" = 204:0 && test "$v6" = 204:0; then
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  return 1
}

sample baseline 1
sample baseline 2
test "$(tail -1 "$OUTPUT/samples.tsv" | awk -F '\t' '{print $4}')" = 204:0
test "$(tail -1 "$OUTPUT/samples.tsv" | awk -F '\t' '{print $5}')" = 204:0

if test "$INITIAL_FIXTURE" = A; then
  FIRST_PID=$PID_A
  SECOND_PID=$PID_B
  FIRST_LOG=$LOG_A
  SECOND_LOG=$LOG_B
  stopped_a=yes
else
  FIRST_PID=$PID_B
  SECOND_PID=$PID_A
  FIRST_LOG=$LOG_B
  SECOND_LOG=$LOG_A
  stopped_b=yes
fi
FIRST_OTHER_OFFSET=$(wc -c <"$SECOND_LOG" | tr -d ' ')
kill -STOP "$FIRST_PID"
printf 'first_stopped=%s\nfirst_pid=%s\nfirst_stopped_utc=%s\n' \
  "$INITIAL_FIXTURE" "$FIRST_PID" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  >"$OUTPUT/faults.txt"
wait_for_healthy_failover first_failover
FIRST_OTHER_INBOUND=$(tail -c +$((FIRST_OTHER_OFFSET + 1)) "$SECOND_LOG" |
  grep -c 'inbound connection from 192\.168\.64\.6' || true)
test "$FIRST_OTHER_INBOUND" -gt 0

kill -CONT "$FIRST_PID"
if test "$INITIAL_FIXTURE" = A; then stopped_a=no; else stopped_b=no; fi
sleep 3

if test "$INITIAL_FIXTURE" = A; then stopped_b=yes; else stopped_a=yes; fi
SECOND_OTHER_OFFSET=$(wc -c <"$FIRST_LOG" | tr -d ' ')
kill -STOP "$SECOND_PID"
printf 'second_stopped=%s\nsecond_pid=%s\nsecond_stopped_utc=%s\n' \
  "$(test "$INITIAL_FIXTURE" = A && echo B || echo A)" "$SECOND_PID" \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$OUTPUT/faults.txt"
wait_for_healthy_failover second_failover
SECOND_OTHER_INBOUND=$(tail -c +$((SECOND_OTHER_OFFSET + 1)) "$FIRST_LOG" |
  grep -c 'inbound connection from 192\.168\.64\.6' || true)
test "$SECOND_OTHER_INBOUND" -gt 0

kill -CONT "$SECOND_PID"
if test "$INITIAL_FIXTURE" = A; then stopped_b=no; else stopped_a=no; fi
sleep 3
sample recovered 1
sample recovered 2
sample recovered 3

ssh -o BatchMode=yes "$VM" /bin/sh -s <<'REMOTE' >"$OUTPUT/final-network.txt"
set -eu
printf 'vpn_status='; scutil --nc status AetherRoute | head -1
printf 'dns_udp_status='; dig -4 @192.168.64.1 google.com A +time=5 +tries=1 +retry=0 +noall +comments | awk '/status:/{gsub(",", "", $6);print $6;exit}'
printf 'dns_tcp_status='; dig -4 @192.168.64.1 google.com A +tcp +time=5 +tries=1 +retry=0 +noall +comments | awk '/status:/{gsub(",", "", $6);print $6;exit}'
REMOTE
ssh -o BatchMode=yes "$VM" \
  '/Users/chenxu/Desktop/AetherRoute-1434-TUN-Preflight-Tools-v1/aetherroute_stun_udp_probe_1424.sh stun.l.google.com 19302 8' \
  >"$OUTPUT/final-stun.txt" 2>&1
ssh -o BatchMode=yes "$VM" \
  "/usr/bin/log show --style compact --start '$REMOTE_LOG_START' --info --debug --predicate 'process == \"AetherRoute\"'" \
  >"$OUTPUT/app-log.txt" 2>&1 || true

tail -c +1 "$LOG_A" >"$OUTPUT/fixture-a-complete.log"
tail -c +1 "$LOG_B" >"$OUTPUT/fixture-b-complete.log"
AFTER_RUNTIME=$(ssh -o BatchMode=yes "$VM" /bin/zsh -s <<'REMOTE'
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
pid=$(pgrep -f '/Library/SystemExtensions/.*/com.aetherroute.desktop.tunnel.systemextension/Contents/MacOS/com.aetherroute.desktop.tunnel' | head -1)
printf 'provider_pid=%s\n' "$pid"
printf 'vpn_status='; scutil --nc status AetherRoute | head -1
REMOTE
)
printf '%s\n' "$AFTER_RUNTIME" >"$OUTPUT/runtime-after.txt"

AFTER_PID=$(printf '%s\n' "$AFTER_RUNTIME" | awk -F= '$1=="provider_pid"{print $2}')
AFTER_STATUS=$(printf '%s\n' "$AFTER_RUNTIME" | awk -F= '$1=="vpn_status"{print $2}')
RECOVERY_LOGS=$(grep -c 'stage=automaticRouteHealth explicitReselection success' "$OUTPUT/app-log.txt" || true)
MAX_CONSECUTIVE_FAILURES=$(awk -F '\t' '
  NR==1{next}
  $4=="204:0" && $5=="204:0" {run=0;next}
  {run++;if(run>max)max=run}
  END{print max+0}
' "$OUTPUT/samples.tsv")
FINAL_THREE_PASS=$(tail -3 "$OUTPUT/samples.tsv" | awk -F '\t' '
  $4!="204:0" || $5!="204:0" {bad++}
  END{if ((bad+0) == 0) print "yes"; else print "no"}
')
DNS_UDP=$(awk -F= '$1=="dns_udp_status"{print $2}' "$OUTPUT/final-network.txt")
DNS_TCP=$(awk -F= '$1=="dns_tcp_status"{print $2}' "$OUTPUT/final-network.txt")
STUN=$(grep -q '^stun_udp=passed$' "$OUTPUT/final-stun.txt" && echo passed || echo failed)

GATE=failed
if test "$AFTER_PID" = "$PROVIDER_PID" \
  && test "$AFTER_STATUS" = Connected \
  && test "$FIRST_OTHER_INBOUND" -gt 0 \
  && test "$SECOND_OTHER_INBOUND" -gt 0 \
  && test "$RECOVERY_LOGS" -ge 2 \
  && test "$MAX_CONSECUTIVE_FAILURES" -le 6 \
  && test "$FINAL_THREE_PASS" = yes \
  && test "$DNS_UDP" = NOERROR \
  && test "$DNS_TCP" = NOERROR \
  && test "$STUN" = passed; then
  GATE=passed
fi

{
  printf 'schema=2\n'
  printf 'completed_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'candidate_build=%s\n' "$EXPECTED_BUILD"
  printf 'initial_fixture=%s\n' "$INITIAL_FIXTURE"
  printf 'first_other_fixture_new_inbound=%s\n' "$FIRST_OTHER_INBOUND"
  printf 'second_other_fixture_new_inbound=%s\n' "$SECOND_OTHER_INBOUND"
  printf 'automatic_reselection_success_logs=%s\n' "$RECOVERY_LOGS"
  printf 'provider_pid_stable=%s\n' "$(test "$AFTER_PID" = "$PROVIDER_PID" && echo yes || echo no)"
  printf 'max_consecutive_google_failures=%s\n' "$MAX_CONSECUTIVE_FAILURES"
  printf 'final_three_pass=%s\n' "$FINAL_THREE_PASS"
  printf 'dns_udp=%s\ndns_tcp=%s\nstun=%s\n' "$DNS_UDP" "$DNS_TCP" "$STUN"
  printf 'release_gate=%s\n' "$GATE"
} >"$OUTPUT/result.txt"

cp "$0" "$OUTPUT/run_automatic_node_failover_1436.sh"
chmod 400 "$OUTPUT/run_automatic_node_failover_1436.sh"
(
  cd "$OUTPUT"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -print | LC_ALL=C sort |
    while IFS= read -r path; do shasum -a 256 "${path#./}"; done >SHA256SUMS
)

test "$GATE" = passed || {
  echo "automatic failover rejected; evidence preserved at $OUTPUT" >&2
  exit 1
}
echo "automatic failover passed: $OUTPUT"
