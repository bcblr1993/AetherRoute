#!/bin/sh
set -eu
umask 077

test "$#" -eq 1 || {
  echo "usage: $0 /absolute/nonexistent/output-directory" >&2
  exit 64
}
OUTPUT=$1
case "$OUTPUT" in /*) ;; *) exit 64;; esac
test ! -e "$OUTPUT" || { echo "refusing to overwrite $OUTPUT" >&2; exit 1; }

APP=/Applications/AetherRoute.app
APP_BINARY="$APP/Contents/MacOS/AetherRoute"
TUN_PROVIDER=com.aetherroute.desktop.tunnel
SERVICE_UUID=6E6C4D00-2281-4DB0-9B1F-B5D0C4140D7D
EXPECTED_BUILD=2026081433
EXPECTED_APP_CDHASH=dea4071a7b86cf34e38dc7e67a6eaa68571e2fc2
EXPECTED_TUN_CDHASH=27171b8bdffa28b88460ef2ad00c0ef76d712609
EXPECTED_TUN_SHA256=c5f36d53b24d8ba0bb0823dcdb2c72a9b75cd8d4e6fbba40a086e9d76d20830b

mkdir -m 700 "$OUTPUT"
ditto "$0" "$OUTPUT/run_app_quit_cleanup_1433.sh"
chmod 400 "$OUTPUT/run_app_quit_cleanup_1433.sh"

cdhash() {
  codesign -dv --verbose=4 "$1" 2>&1 | awk -F= '/^CDHash=/{print $2;exit}'
}

https_gate() {
  family=$1
  attempt=1
  successes=0
  pattern=
  while test "$attempt" -le 3; do
    code=$(curl "$family" -sS -o /dev/null -w '%{http_code}' --max-time 8 \
      https://www.google.com/generate_204 2>/dev/null || true)
    if test "$code" = 204; then
      successes=$((successes + 1))
      pattern="${pattern}P"
    else
      pattern="${pattern}F${code:-000}"
    fi
    attempt=$((attempt + 1))
  done
  test "$successes" -ge 2
  printf '%s' "$pattern"
}

app_build=$(defaults read "$APP/Contents/Info" CFBundleVersion)
app_cdhash=$(cdhash "$APP")
test "$app_build" = "$EXPECTED_BUILD"
test "$app_cdhash" = "$EXPECTED_APP_CDHASH"
app_pid=$(pgrep -x AetherRoute | awk 'NR==1{print}')
test -n "$app_pid"
test "$(ps -p "$app_pid" -o command= | sed -E 's/^[[:space:]]+//')" = "$APP_BINARY"

tun_pid=$(pgrep -x "$TUN_PROVIDER" | awk 'NR==1{print}')
test -n "$tun_pid"
tun_binary=$(ps -p "$tun_pid" -o command= | sed -E 's/^[[:space:]]+//')
test -f "$tun_binary"
tun_root=$(dirname "$(dirname "$(dirname "$tun_binary")")")
tun_cdhash=$(cdhash "$tun_root")
tun_sha=$(shasum -a 256 "$tun_binary" | awk '{print $1}')
test "$tun_cdhash" = "$EXPECTED_TUN_CDHASH"
test "$tun_sha" = "$EXPECTED_TUN_SHA256"
test "$(scutil --nc status "$SERVICE_UUID" | head -1)" = Connected
case "$(route -n get default | awk '/interface:/{print $2;exit}')" in utun[0-9]*) ;; *) exit 1;; esac

baseline_v4=$(https_gate -4)
baseline_v6=$(https_gate -6)

quit_started=$(date +%s)
osascript -e 'tell application "AetherRoute" to quit'
i=0
while kill -0 "$app_pid" 2>/dev/null; do
  i=$((i + 1))
  test "$i" -le 35
  sleep 1
done
test -z "$(pgrep -x AetherRoute 2>/dev/null || true)"

i=0
while test "$(scutil --nc status "$SERVICE_UUID" 2>/dev/null | head -1 || true)" != Disconnected; do
  i=$((i + 1))
  test "$i" -le 35
  sleep 1
done
quit_completed=$(date +%s)
quit_seconds=$((quit_completed - quit_started))
test "$quit_seconds" -le 35

# macOS may keep an activated system extension process resident after its VPN
# session has stopped. That idle process is not a live tunnel: the authoritative
# cleanup gates are the disconnected NE session plus restored routes, address,
# and DNS state below. Record the resident PID, but do not misclassify it as an
# active connection.
tun_pid_after_quit=$(pgrep -x "$TUN_PROVIDER" 2>/dev/null || true)

test "$(route -n get default | awk '/interface:/{print $2;exit}')" = en0
test "$(route -n get 198.18.0.2 | awk '/interface:/{print $2;exit}')" = en0
! ifconfig -a | grep -F 'inet 198.18.0.1 ' >/dev/null
! scutil --dns | grep -F 'nameserver[0] : 198.18.0.2' >/dev/null
apple_after_quit=$(curl -4 --noproxy '*' -sS -o /dev/null -w '%{http_code}' \
  --max-time 8 https://www.apple.com/)
test "$apple_after_quit" = 200

nonce="quit-$(uuidgen | tr A-Z a-z).example.com"
dig -4 @192.168.64.1 "$nonce" A +time=5 +tries=1 +retry=0 +noall +comments +stats \
  >"$OUTPUT/dns-udp.txt" 2>&1
grep -Eq 'status: (NOERROR|NXDOMAIN)' "$OUTPUT/dns-udp.txt"
dig -4 @192.168.64.1 "tcp-$nonce" A +tcp +time=5 +tries=1 +retry=0 +noall +comments +stats \
  >"$OUTPUT/dns-tcp.txt" 2>&1
grep -Eq 'status: (NOERROR|NXDOMAIN)' "$OUTPUT/dns-tcp.txt"

/usr/bin/open "$APP"
i=0
new_app_pid=
while test -z "$new_app_pid"; do
  i=$((i + 1))
  test "$i" -le 30
  sleep 1
  new_app_pid=$(pgrep -x AetherRoute | awk 'NR==1{print}')
done
test "$new_app_pid" -ne "$app_pid"
sleep 5
test "$(scutil --nc status "$SERVICE_UUID" | head -1)" = Disconnected
tun_pid_after_relaunch=$(pgrep -x "$TUN_PROVIDER" 2>/dev/null || true)
test "$(route -n get default | awk '/interface:/{print $2;exit}')" = en0
! ifconfig -a | grep -F 'inet 198.18.0.1 ' >/dev/null
! scutil --dns | grep -F 'nameserver[0] : 198.18.0.2' >/dev/null
apple_after_relaunch=$(curl -4 --noproxy '*' -sS -o /dev/null -w '%{http_code}' \
  --max-time 8 https://www.apple.com/)
test "$apple_after_relaunch" = 200

{
  printf 'schema=2\n'
  printf 'completed_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'build=%s\n' "$app_build"
  printf 'app_cdhash=%s\n' "$app_cdhash"
  printf 'old_app_pid=%s\n' "$app_pid"
  printf 'new_app_pid=%s\n' "$new_app_pid"
  printf 'tun_pid_before=%s\n' "$tun_pid"
  printf 'tun_pid_after_quit=%s\n' "${tun_pid_after_quit:-absent}"
  printf 'tun_pid_after_relaunch=%s\n' "${tun_pid_after_relaunch:-absent}"
  printf 'tun_cdhash=%s\n' "$tun_cdhash"
  printf 'tun_sha256=%s\n' "$tun_sha"
  printf 'baseline_google_ipv4=%s\n' "$baseline_v4"
  printf 'baseline_google_ipv6=%s\n' "$baseline_v6"
  printf 'normal_quit_seconds=%s\n' "$quit_seconds"
  printf 'app_quit_apple_https=%s\n' "$apple_after_quit"
  printf 'relaunch_apple_https=%s\n' "$apple_after_relaunch"
  printf 'dns_udp=passed\n'
  printf 'dns_tcp=passed\n'
  printf 'quit_trigger=appkit-normal-quit-apple-event\n'
  printf 'provider_process_policy=resident-idle-permitted-after-session-cleanup\n'
  printf 'quit_behavior=disconnect-and-restore-system-network\n'
  printf 'relaunch_behavior=remain-disconnected-until-user-connects\n'
  printf 'result=passed\n'
} >"$OUTPUT/result.txt"

(cd "$OUTPUT" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print \
  | LC_ALL=C sort | while IFS= read -r item; do shasum -a 256 "${item#./}"; done >SHA256SUMS)
echo "TUN normal app-quit cleanup passed: old_app=$app_pid new_app=$new_app_pid old_tun=$tun_pid seconds=$quit_seconds"
