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
EXPECTED_BUILD=2026081431
EXPECTED_APP_CDHASH=2598335de893828c64cb1b72540ff6a2b6d15faf
EXPECTED_TUN_SHA=f6db1b082f66271b8e8db478cfbe6a3dd6e761a8252564785048ff7200041067

pid_for_label() {
  launchctl print "gui/$(id -u)/$1" 2>/dev/null |
    awk '/^[[:space:]]*pid = [0-9]+$/{print $3;exit}'
}

case "$ACTION" in
  begin)
    test ! -e "$OUTPUT" || {
      echo "refusing to overwrite $OUTPUT" >&2
      exit 1
    }
    mkdir -p "$OUTPUT"
    PID_A=$(pid_for_label "$LABEL_A")
    PID_B=$(pid_for_label "$LABEL_B")
    test -n "$PID_A" && test -n "$PID_B" && test "$PID_A" -ne "$PID_B"
    test -f "$LOG_A" && test -f "$LOG_B"
    APP_BUILD=$(ssh -o BatchMode=yes "$VM" 'defaults read /Applications/AetherRoute.app/Contents/Info CFBundleVersion')
    APP_CDHASH=$(ssh -o BatchMode=yes "$VM" \
      'codesign -dv --verbose=4 /Applications/AetherRoute.app 2>&1' |
      awk -F= '/^CDHash=/{print $2;exit}')
    TUN_SHA=$(ssh -o BatchMode=yes "$VM" \
      'shasum -a 256 /Applications/AetherRoute.app/Contents/PlugIns/AetherRouteTunnel.appex/Contents/MacOS/AetherRouteTunnel' |
      awk '{print $1}')
    test "$APP_BUILD" = "$EXPECTED_BUILD"
    test "$APP_CDHASH" = "$EXPECTED_APP_CDHASH"
    test "$TUN_SHA" = "$EXPECTED_TUN_SHA"
    VPN_STATUS=$(ssh -o BatchMode=yes "$VM" 'scutil --nc list' |
      awk '/com.aetherroute.desktop/{gsub(/[()*]/,"");print $1;exit}')
    test "$VPN_STATUS" = Disconnected
    {
      printf 'schema=1\n'
      printf 'started_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      printf 'fixture_a_pid=%s\nfixture_b_pid=%s\n' "$PID_A" "$PID_B"
      printf 'fixture_a_log_offset=%s\n' "$(wc -c <"$LOG_A" | tr -d ' ')"
      printf 'fixture_b_log_offset=%s\n' "$(wc -c <"$LOG_B" | tr -d ' ')"
      printf 'app_build=%s\napp_cdhash=%s\ntun_sha256=%s\n' "$APP_BUILD" "$APP_CDHASH" "$TUN_SHA"
      printf 'vpn_status_before=%s\n' "$VPN_STATUS"
      printf 'profile_catalog_sha256=%s\n' "$(ssh -o BatchMode=yes "$VM" 'shasum -a 256 "$HOME/Library/Group Containers/group.com.aetherroute.desktop/Library/Application Support/AetherRoute/profile-catalog.v1.json"' | awk '{print $1}')"
      printf 'active_profile_sha256=%s\n' "$(ssh -o BatchMode=yes "$VM" 'shasum -a 256 "$HOME/Library/Group Containers/group.com.aetherroute.desktop/Library/Application Support/AetherRoute/active-profile.v2.json"' | awk '{print $1}')"
      printf 'selection_store_sha256=%s\n' "$(ssh -o BatchMode=yes "$VM" 'shasum -a 256 "$HOME/Library/Group Containers/group.com.aetherroute.desktop/Library/Application Support/AetherRoute/proxy-selections.v1.json"' | awk '{print $1}')"
    } >"$OUTPUT/before.txt"
    cp "$0" "$OUTPUT/manual_pinned_node_watch_1431.sh"
    chmod 400 "$OUTPUT/manual_pinned_node_watch_1431.sh"
    echo "manual pinned watch armed: $OUTPUT"
    ;;
  finish)
    test -f "$OUTPUT/before.txt" || {
      echo "missing before.txt in $OUTPUT" >&2
      exit 1
    }
    test ! -e "$OUTPUT/result.txt" || {
      echo "refusing to overwrite completed evidence" >&2
      exit 1
    }
    OFFSET_A=$(awk -F= '$1=="fixture_a_log_offset"{print $2}' "$OUTPUT/before.txt")
    OFFSET_B=$(awk -F= '$1=="fixture_b_log_offset"{print $2}' "$OUTPUT/before.txt")
    tail -c +$((OFFSET_A + 1)) "$LOG_A" >"$OUTPUT/fixture-a-delta.log"
    tail -c +$((OFFSET_B + 1)) "$LOG_B" >"$OUTPUT/fixture-b-delta.log"
    ssh -o BatchMode=yes "$VM" /bin/sh -s <<'REMOTE' >"$OUTPUT/runtime-after.txt"
set +e
status=$(scutil --nc list | awk '/com.aetherroute.desktop/{gsub(/[()*]/,"");print $1;exit}')
default=$(route -n get default 2>/dev/null | awk '/interface:/{print $2;exit}')
stub=$(route -n get 198.18.0.1 2>/dev/null | awk '/interface:/{print $2;exit}')
app_pid=$(pgrep -f '/AetherRoute.app/Contents/MacOS/AetherRoute' | head -1)
tun_count=$(pgrep -f '/AetherRouteTunnel.appex/Contents/MacOS/AetherRouteTunnel' | wc -l | tr -d ' ')
v4=$(curl -4 --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 6 https://www.google.com/generate_204 2>/dev/null); r4=$?
v6=$(curl -6 --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 6 https://www.google.com/generate_204 2>/dev/null); r6=$?
printf 'vpn_status=%s\ndefault_interface=%s\nsynthetic_stub_interface=%s\napp_pid=%s\ntun_pid_count=%s\ngoogle_v4=%s:%s\ngoogle_v6=%s:%s\n' "$status" "$default" "$stub" "$app_pid" "$tun_count" "$v4" "$r4" "$v6" "$r6"
REMOTE
    ssh -o BatchMode=yes "$VM" \
      "log show --style compact --last 5m --predicate 'process == \"AetherRoute\"'" \
      >"$OUTPUT/app-log-last-5m.txt" 2>&1 || true

    VPN_STATUS=$(awk -F= '$1=="vpn_status"{print $2}' "$OUTPUT/runtime-after.txt")
    DEFAULT_IF=$(awk -F= '$1=="default_interface"{print $2}' "$OUTPUT/runtime-after.txt")
    STUB_IF=$(awk -F= '$1=="synthetic_stub_interface"{print $2}' "$OUTPUT/runtime-after.txt")
    GOOGLE_V4=$(awk -F= '$1=="google_v4"{print $2}' "$OUTPUT/runtime-after.txt")
    GOOGLE_V6=$(awk -F= '$1=="google_v6"{print $2}' "$OUTPUT/runtime-after.txt")
    A_INBOUND=$(grep -c 'inbound/vmess\[fixture-a\]: inbound connection from 192\.168\.64\.4' "$OUTPUT/fixture-a-delta.log" || true)
    B_INBOUND=$(grep -c 'inbound/vmess\[fixture-b\]: inbound connection from 192\.168\.64\.4' "$OUTPUT/fixture-b-delta.log" || true)
    READINESS_MANUAL=$(grep -c 'stage=connectionReadiness route behavior=manual' "$OUTPUT/app-log-last-5m.txt" || true)
    READINESS_FAILED=$(grep -c 'stage=connectionReadiness failed' "$OUTPUT/app-log-last-5m.txt" || true)
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
    GATE=failed
    if test "$RESTORED" = yes \
      && test "$NO_SIBLING_TRAFFIC" = yes \
      && test "$READINESS_MANUAL" -ge 1 \
      && test "$READINESS_FAILED" -ge 1 \
      && test "$GOOGLE_V4" != 204:0 \
      && test "$GOOGLE_V6" != 204:0; then
      GATE=passed
    fi
    {
      printf 'schema=1\n'
      printf 'completed_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      printf 'vpn_status=%s\n' "$VPN_STATUS"
      printf 'network_restored=%s\n' "$RESTORED"
      printf 'fixture_a_new_inbound_connections=%s\n' "$A_INBOUND"
      printf 'fixture_b_new_inbound_connections=%s\n' "$B_INBOUND"
      printf 'sibling_traffic_absent=%s\n' "$NO_SIBLING_TRAFFIC"
      printf 'manual_readiness_log_count=%s\n' "$READINESS_MANUAL"
      printf 'readiness_failure_log_count=%s\n' "$READINESS_FAILED"
      printf 'google_v4_after=%s\ngoogle_v6_after=%s\n' "$GOOGLE_V4" "$GOOGLE_V6"
      printf 'release_gate=%s\n' "$GATE"
    } >"$OUTPUT/result.txt"
    (cd "$OUTPUT" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print |
      LC_ALL=C sort | while IFS= read -r path; do
        shasum -a 256 "${path#./}"
      done >SHA256SUMS)
    test "$GATE" = passed || {
      echo "manual pinned failure gate rejected; evidence preserved at $OUTPUT" >&2
      exit 1
    }
    echo "manual pinned failure gate passed: $OUTPUT"
    ;;
  *) usage ;;
esac
