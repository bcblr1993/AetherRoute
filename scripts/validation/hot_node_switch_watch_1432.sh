#!/bin/sh
set -eu
umask 077

test "$#" -eq 3 || {
  echo "usage: $0 begin|finish /absolute/evidence-directory A|B" >&2
  exit 64
}
ACTION=$1
OUTPUT=$2
TARGET=$3
case "$OUTPUT" in /*) ;; *) exit 64;; esac
case "$TARGET" in A|B) ;; *) exit 64;; esac

VM=chenxu@192.168.64.4
LOG_A=/Users/chenxu/Downloads/AetherRoute-1429-AutoFailover-Fixtures-v1/logs-1431/fixture-a.stderr.log
LOG_B=/Users/chenxu/Downloads/AetherRoute-1429-AutoFailover-Fixtures-v1/logs-1431/fixture-b.stderr.log
EXPECTED_BUILD=2026081432
EXPECTED_APP_CDHASH=7be9c79f6bb36f317362242db7edf4e879957d2a
EXPECTED_TUN_CDHASH=24374fb39c2256d1df30c465c74d4c09f8999ad2
EXPECTED_TUN_SHA=906f992f210236104449aeec5a4023c2fac4b4663809943a269dd75cef2a5287

case "$ACTION" in
  begin)
    test ! -e "$OUTPUT" || { echo "refusing to overwrite $OUTPUT" >&2; exit 1; }
    mkdir -p "$OUTPUT"
    runtime=$(ssh -o BatchMode=yes "$VM" /bin/zsh -s <<'REMOTE'
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
app=/Applications/AetherRoute.app
pid=$(pgrep -x com.aetherroute.desktop.tunnel | head -1)
provider_path=$(ps -p "$pid" -o command= | sed -E 's/^[[:space:]]+//')
root=$(dirname "$(dirname "$(dirname "$provider_path")")")
printf 'app_build='; defaults read "$app/Contents/Info" CFBundleVersion
printf 'app_cdhash='; codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^CDHash=/{print $2;exit}'
printf 'provider_pid=%s\n' "$pid"
printf 'provider_cdhash='; codesign -dv --verbose=4 "$root" 2>&1 | awk -F= '/^CDHash=/{print $2;exit}'
printf 'provider_sha256='; shasum -a 256 "$provider_path" | awk '{print $1}'
printf 'vpn_status='; scutil --nc status AetherRoute | head -1
REMOTE
)
    test "$(printf '%s\n' "$runtime" | awk -F= '$1=="app_build"{print $2}')" = "$EXPECTED_BUILD"
    test "$(printf '%s\n' "$runtime" | awk -F= '$1=="app_cdhash"{print $2}')" = "$EXPECTED_APP_CDHASH"
    test "$(printf '%s\n' "$runtime" | awk -F= '$1=="provider_cdhash"{print $2}')" = "$EXPECTED_TUN_CDHASH"
    test "$(printf '%s\n' "$runtime" | awk -F= '$1=="provider_sha256"{print $2}')" = "$EXPECTED_TUN_SHA"
    test "$(printf '%s\n' "$runtime" | awk -F= '$1=="vpn_status"{print $2}')" = Connected
    {
      printf 'target=%s\n' "$TARGET"
      printf 'remote_log_start=%s\n' "$(ssh -o BatchMode=yes "$VM" "date '+%Y-%m-%d %H:%M:%S'")"
      printf 'fixture_a_offset=%s\n' "$(wc -c <"$LOG_A" | tr -d ' ')"
      printf 'fixture_b_offset=%s\n' "$(wc -c <"$LOG_B" | tr -d ' ')"
      printf '%s\n' "$runtime"
    } >"$OUTPUT/before.txt"
    cp "$0" "$OUTPUT/hot_node_switch_watch_1432.sh"
    chmod 400 "$OUTPUT/hot_node_switch_watch_1432.sh"
    echo "hot node watcher armed: target=$TARGET output=$OUTPUT"
    ;;
  finish)
    test -f "$OUTPUT/before.txt" && test ! -e "$OUTPUT/result.txt"
    test "$(awk -F= '$1=="target"{print $2}' "$OUTPUT/before.txt")" = "$TARGET"
    offset_a=$(awk -F= '$1=="fixture_a_offset"{print $2}' "$OUTPUT/before.txt")
    offset_b=$(awk -F= '$1=="fixture_b_offset"{print $2}' "$OUTPUT/before.txt")
    start=$(awk -F= '$1=="remote_log_start"{print $2}' "$OUTPUT/before.txt")
    tail -c +$((offset_a + 1)) "$LOG_A" >"$OUTPUT/fixture-a-delta.log"
    tail -c +$((offset_b + 1)) "$LOG_B" >"$OUTPUT/fixture-b-delta.log"
    ssh -o BatchMode=yes "$VM" /bin/sh -s <<'REMOTE' >"$OUTPUT/runtime-after.txt"
set -eu
pid=$(pgrep -x com.aetherroute.desktop.tunnel | head -1)
printf 'provider_pid=%s\n' "$pid"
printf 'vpn_status='; scutil --nc status AetherRoute | head -1
printf 'google_v4='; curl -4 --noproxy '*' -sS -o /dev/null -w '%{http_code}:%{exitcode}\n' --connect-timeout 3 --max-time 8 https://www.google.com/generate_204
printf 'google_v6='; curl -6 --noproxy '*' -sS -o /dev/null -w '%{http_code}:%{exitcode}\n' --connect-timeout 3 --max-time 8 https://www.google.com/generate_204
REMOTE
    ssh -o BatchMode=yes "$VM" "/usr/bin/log show --style compact --start '$start' --info --debug --predicate 'process == \"AetherRoute\"'" >"$OUTPUT/app-log.txt" 2>&1 || true
    a_inbound=$(grep -c 'inbound connection from 192\.168\.64\.4' "$OUTPUT/fixture-a-delta.log" || true)
    b_inbound=$(grep -c 'inbound connection from 192\.168\.64\.4' "$OUTPUT/fixture-b-delta.log" || true)
    expected_inbound=$a_inbound
    test "$TARGET" = A || expected_inbound=$b_inbound
    before_pid=$(awk -F= '$1=="provider_pid"{print $2}' "$OUTPUT/before.txt")
    after_pid=$(awk -F= '$1=="provider_pid"{print $2}' "$OUTPUT/runtime-after.txt")
    selection_logs=$(grep -c 'stage=proxySelection success' "$OUTPUT/app-log.txt" || true)
    ui_evidence=no
    test -s "$OUTPUT/ui-target.jpeg" && ui_evidence=yes
    gate=failed
    if test "$before_pid" = "$after_pid" \
      && test "$(awk -F= '$1=="vpn_status"{print $2}' "$OUTPUT/runtime-after.txt")" = Connected \
      && test "$(awk -F= '$1=="google_v4"{print $2}' "$OUTPUT/runtime-after.txt")" = 204:0 \
      && test "$(awk -F= '$1=="google_v6"{print $2}' "$OUTPUT/runtime-after.txt")" = 204:0 \
      && test "$expected_inbound" -gt 0 \
      && test "$ui_evidence" = yes; then gate=passed; fi
    {
      printf 'schema=1\ntarget=%s\nprovider_pid_stable=%s\n' "$TARGET" "$(test "$before_pid" = "$after_pid" && echo yes || echo no)"
      printf 'fixture_a_new_inbound=%s\nfixture_b_new_inbound=%s\n' "$a_inbound" "$b_inbound"
      printf 'proxy_selection_success_logs=%s\n' "$selection_logs"
      printf 'ui_evidence_present=%s\n' "$ui_evidence"
      sed -n '/^vpn_status=/p;/^google_v[46]=/p' "$OUTPUT/runtime-after.txt"
      printf 'release_gate=%s\n' "$gate"
    } >"$OUTPUT/result.txt"
    (cd "$OUTPUT" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print | LC_ALL=C sort | while IFS= read -r path; do shasum -a 256 "${path#./}"; done >SHA256SUMS)
    test "$gate" = passed || { echo "hot node switch rejected: $OUTPUT" >&2; exit 1; }
    echo "hot node switch passed: target=$TARGET output=$OUTPUT"
    ;;
  *) exit 64;;
esac
