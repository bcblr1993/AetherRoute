#!/bin/sh
set -eu
umask 077

usage() {
  echo "usage: $0 begin|finish /absolute/evidence-directory" >&2
  exit 64
}

test "$#" -eq 2 || usage
ACTION=$1
OUTPUT=$2
case "$OUTPUT" in /*) ;; *) usage ;; esac

VM=chenxu@192.168.64.4
LABEL_A=com.aetherroute.fixture.proxy.a.1431
LABEL_B=com.aetherroute.fixture.proxy.b.1431
LOG_A=/Users/chenxu/Downloads/AetherRoute-1429-AutoFailover-Fixtures-v1/logs-1431/fixture-a.stderr.log
LOG_B=/Users/chenxu/Downloads/AetherRoute-1429-AutoFailover-Fixtures-v1/logs-1431/fixture-b.stderr.log
EXPECTED_BUILD=2026081432
EXPECTED_APP_CDHASH=7be9c79f6bb36f317362242db7edf4e879957d2a
EXPECTED_TUN_CDHASH=24374fb39c2256d1df30c465c74d4c09f8999ad2
EXPECTED_TUN_SHA=906f992f210236104449aeec5a4023c2fac4b4663809943a269dd75cef2a5287

pid_for_label() {
  launchctl print "gui/$(id -u)/$1" 2>/dev/null |
    awk '/^[[:space:]]*pid = [0-9]+$/{print $3;exit}'
}

case "$ACTION" in
  begin)
    test ! -e "$OUTPUT" || {
      echo "refusing to overwrite evidence: $OUTPUT" >&2
      exit 1
    }
    mkdir -p "$OUTPUT"
    PID_A=$(pid_for_label "$LABEL_A")
    PID_B=$(pid_for_label "$LABEL_B")
    test -n "$PID_A" && test -n "$PID_B" && test "$PID_A" -ne "$PID_B"
    test -f "$LOG_A" && test -f "$LOG_B"
    REMOTE=$(ssh -o BatchMode=yes "$VM" /bin/zsh -s <<'REMOTE'
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
app=/Applications/AetherRoute.app
tun="$app/Contents/Library/SystemExtensions/com.aetherroute.desktop.tunnel.systemextension"
printf 'app_build='; /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist"
printf 'app_cdhash='; codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '$1 == "CDHash" {print $2;exit}'
printf 'tun_cdhash='; codesign -dv --verbose=4 "$tun" 2>&1 | awk -F= '$1 == "CDHash" {print $2;exit}'
printf 'tun_sha256='; shasum -a 256 "$tun/Contents/MacOS/com.aetherroute.desktop.tunnel" | awk '{print $1}'
printf 'vpn_status='; scutil --nc status AetherRoute | head -1
set +e
v4=$(curl -4 --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 7 https://www.google.com/generate_204 2>/dev/null); r4=$?
v6=$(curl -6 --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 7 https://www.google.com/generate_204 2>/dev/null); r6=$?
nc -z -G 2 192.168.64.1 59104 >/dev/null 2>&1; fixture_b=$?
set -e
printf 'google_v4_baseline=%s:%s\ngoogle_v6_baseline=%s:%s\nfixture_b_baseline_reachable=%s\n' \
  "$v4" "$r4" "$v6" "$r6" "$(test "$fixture_b" -eq 0 && echo yes || echo no)"
REMOTE
)
    APP_BUILD=$(printf '%s\n' "$REMOTE" | awk -F= '$1=="app_build"{print $2}')
    APP_CDHASH=$(printf '%s\n' "$REMOTE" | awk -F= '$1=="app_cdhash"{print $2}')
    TUN_CDHASH=$(printf '%s\n' "$REMOTE" | awk -F= '$1=="tun_cdhash"{print $2}')
    TUN_SHA=$(printf '%s\n' "$REMOTE" | awk -F= '$1=="tun_sha256"{print $2}')
    VPN_STATUS=$(printf '%s\n' "$REMOTE" | awk -F= '$1=="vpn_status"{print $2}')
    test "$APP_BUILD" = "$EXPECTED_BUILD"
    test "$APP_CDHASH" = "$EXPECTED_APP_CDHASH"
    test "$TUN_CDHASH" = "$EXPECTED_TUN_CDHASH"
    test "$TUN_SHA" = "$EXPECTED_TUN_SHA"
    test "$VPN_STATUS" = Disconnected
    REMOTE_LOG_START=$(ssh -o BatchMode=yes "$VM" "date '+%Y-%m-%d %H:%M:%S'")
    {
      printf 'schema=2\n'
      printf 'started_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      printf 'remote_log_start=%s\n' "$REMOTE_LOG_START"
      printf 'fixture_a_pid=%s\nfixture_b_pid=%s\n' "$PID_A" "$PID_B"
      printf 'fixture_a_log_offset=%s\n' "$(wc -c <"$LOG_A" | tr -d ' ')"
      printf 'fixture_b_log_offset=%s\n' "$(wc -c <"$LOG_B" | tr -d ' ')"
      printf '%s\n' "$REMOTE"
    } >"$OUTPUT/before.txt"
    cp "$0" "$OUTPUT/manual_pinned_node_watch_1432.sh"
    chmod 400 "$OUTPUT/manual_pinned_node_watch_1432.sh"
    echo "manual pinned watcher armed: $OUTPUT"
    ;;
  finish)
    test -f "$OUTPUT/before.txt" || {
      echo "missing before.txt in evidence directory" >&2
      exit 1
    }
    test ! -e "$OUTPUT/result.txt" || {
      echo "refusing to overwrite completed evidence" >&2
      exit 1
    }
    REMOTE_LOG_START=$(awk -F= '$1=="remote_log_start"{print $2}' "$OUTPUT/before.txt")
    OFFSET_A=$(awk -F= '$1=="fixture_a_log_offset"{print $2}' "$OUTPUT/before.txt")
    OFFSET_B=$(awk -F= '$1=="fixture_b_log_offset"{print $2}' "$OUTPUT/before.txt")
    tail -c +$((OFFSET_A + 1)) "$LOG_A" >"$OUTPUT/fixture-a-delta.log"
    tail -c +$((OFFSET_B + 1)) "$LOG_B" >"$OUTPUT/fixture-b-delta.log"
    ssh -o BatchMode=yes "$VM" /bin/sh -s <<'REMOTE' >"$OUTPUT/runtime-after.txt"
set +e
status=$(scutil --nc status AetherRoute | head -1)
default=$(route -n get default 2>/dev/null | awk '/interface:/{print $2;exit}')
stub=$(route -n get 198.18.0.1 2>/dev/null | awk '/interface:/{print $2;exit}')
app_pid=$(pgrep -f '/AetherRoute.app/Contents/MacOS/AetherRoute' | head -1)
v4=$(curl -4 --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 7 https://www.google.com/generate_204 2>/dev/null); r4=$?
v6=$(curl -6 --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 7 https://www.google.com/generate_204 2>/dev/null); r6=$?
nc -z -G 2 192.168.64.1 59104 >/dev/null 2>&1; fixture_b=$?
printf 'vpn_status=%s\ndefault_interface=%s\nsynthetic_stub_interface=%s\napp_pid=%s\ngoogle_v4=%s:%s\ngoogle_v6=%s:%s\nfixture_b_reachable=%s\n' \
  "$status" "$default" "$stub" "$app_pid" "$v4" "$r4" "$v6" "$r6" \
  "$(test "$fixture_b" -eq 0 && echo yes || echo no)"
REMOTE
    ssh -o BatchMode=yes "$VM" \
      "/usr/bin/log show --style compact --start '$REMOTE_LOG_START' --info --debug --predicate 'process == \"AetherRoute\"'" \
      >"$OUTPUT/app-log.txt" 2>&1 || true

    VPN_STATUS=$(awk -F= '$1=="vpn_status"{print $2}' "$OUTPUT/runtime-after.txt")
    DEFAULT_IF=$(awk -F= '$1=="default_interface"{print $2}' "$OUTPUT/runtime-after.txt")
    STUB_IF=$(awk -F= '$1=="synthetic_stub_interface"{print $2}' "$OUTPUT/runtime-after.txt")
    GOOGLE_V4=$(awk -F= '$1=="google_v4"{print $2}' "$OUTPUT/runtime-after.txt")
    GOOGLE_V6=$(awk -F= '$1=="google_v6"{print $2}' "$OUTPUT/runtime-after.txt")
    GOOGLE_V4_BASELINE=$(awk -F= '$1=="google_v4_baseline"{print $2}' "$OUTPUT/before.txt")
    GOOGLE_V6_BASELINE=$(awk -F= '$1=="google_v6_baseline"{print $2}' "$OUTPUT/before.txt")
    FIXTURE_B_BASELINE=$(awk -F= '$1=="fixture_b_baseline_reachable"{print $2}' "$OUTPUT/before.txt")
    FIXTURE_B_AFTER=$(awk -F= '$1=="fixture_b_reachable"{print $2}' "$OUTPUT/runtime-after.txt")
    A_INBOUND=$(grep -c 'inbound connection from 192\.168\.64\.4' "$OUTPUT/fixture-a-delta.log" || true)
    B_INBOUND=$(grep -c 'inbound connection from 192\.168\.64\.4' "$OUTPUT/fixture-b-delta.log" || true)
    READINESS_MANUAL=$(grep -c 'stage=connectionReadiness route behavior=manual' "$OUTPUT/app-log.txt" || true)
    READINESS_FAILED=$(grep -c 'stage=connectionReadiness failed' "$OUTPUT/app-log.txt" || true)
    RESTORED=no
    if test "$VPN_STATUS" = Disconnected \
      && test "$DEFAULT_IF" = en0 \
      && test "$STUB_IF" = en0; then
      RESTORED=yes
    fi
    NO_SIBLING_TRAFFIC=no
    if test "$A_INBOUND" -eq 0 && test "$B_INBOUND" -eq 0; then
      NO_SIBLING_TRAFFIC=yes
    fi
    BASELINE_NETWORK_MATCH=no
    if test "$GOOGLE_V4" = "$GOOGLE_V4_BASELINE" \
      && test "$GOOGLE_V6" = "$GOOGLE_V6_BASELINE" \
      && test "$FIXTURE_B_BASELINE" = yes \
      && test "$FIXTURE_B_AFTER" = yes; then
      BASELINE_NETWORK_MATCH=yes
    fi
    GATE=failed
    if test "$RESTORED" = yes \
      && test "$NO_SIBLING_TRAFFIC" = yes \
      && test "$READINESS_MANUAL" -ge 1 \
      && test "$READINESS_FAILED" -ge 1 \
      && test "$BASELINE_NETWORK_MATCH" = yes; then
      GATE=passed
    fi
    {
      printf 'schema=2\n'
      printf 'completed_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      printf 'candidate_build=%s\n' "$EXPECTED_BUILD"
      printf 'vpn_status=%s\n' "$VPN_STATUS"
      printf 'network_restored=%s\n' "$RESTORED"
      printf 'fixture_a_new_inbound_connections=%s\n' "$A_INBOUND"
      printf 'fixture_b_new_inbound_connections=%s\n' "$B_INBOUND"
      printf 'sibling_traffic_absent=%s\n' "$NO_SIBLING_TRAFFIC"
      printf 'manual_readiness_log_count=%s\n' "$READINESS_MANUAL"
      printf 'readiness_failure_log_count=%s\n' "$READINESS_FAILED"
      printf 'google_v4_baseline=%s\ngoogle_v4_after=%s\n' "$GOOGLE_V4_BASELINE" "$GOOGLE_V4"
      printf 'google_v6_baseline=%s\ngoogle_v6_after=%s\n' "$GOOGLE_V6_BASELINE" "$GOOGLE_V6"
      printf 'fixture_b_baseline_reachable=%s\nfixture_b_after_reachable=%s\n' "$FIXTURE_B_BASELINE" "$FIXTURE_B_AFTER"
      printf 'baseline_network_match=%s\n' "$BASELINE_NETWORK_MATCH"
      printf 'release_gate=%s\n' "$GATE"
    } >"$OUTPUT/result.txt"
    (
      cd "$OUTPUT"
      find . -maxdepth 1 -type f ! -name SHA256SUMS -print | LC_ALL=C sort |
        while IFS= read -r path; do shasum -a 256 "${path#./}"; done >SHA256SUMS
    )
    test "$GATE" = passed || {
      echo "manual pinned failure gate rejected; evidence preserved at $OUTPUT" >&2
      exit 1
    }
    echo "manual pinned failure gate passed: $OUTPUT"
    ;;
  *) usage ;;
esac
