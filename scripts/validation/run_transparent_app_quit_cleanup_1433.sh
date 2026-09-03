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
PROVIDER=com.aetherroute.desktop.transparent-proxy
EXPECTED_BUILD=2026081433
EXPECTED_APP_CDHASH=dea4071a7b86cf34e38dc7e67a6eaa68571e2fc2
EXPECTED_PROVIDER_CDHASH=b3ad5a61db0cba929b3eb129c8b5372de15ab399
EXPECTED_PROVIDER_SHA256=40ef7f35aaf8f80e55480b7bff34b9fd896cef8d94fbfc8a7b7241206f7a3f57

mkdir -m 700 "$OUTPUT"
ditto "$0" "$OUTPUT/run_transparent_app_quit_cleanup_1433.sh"
chmod 400 "$OUTPUT/run_transparent_app_quit_cleanup_1433.sh"

cdhash() {
  codesign -dv --verbose=4 "$1" 2>&1 | awk -F= '/^CDHash=/{print $2;exit}'
}

google_gate() {
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

direct_google_code() {
  curl "$1" -sS -o /dev/null -w '%{http_code}' --max-time 8 \
    https://www.google.com/generate_204 2>/dev/null || true
}

app_build=$(defaults read "$APP/Contents/Info" CFBundleVersion)
app_cdhash=$(cdhash "$APP")
test "$app_build" = "$EXPECTED_BUILD"
test "$app_cdhash" = "$EXPECTED_APP_CDHASH"
test "$(defaults read com.aetherroute.desktop AetherRoute.NetworkEngineMode)" = transparent
app_pid=$(pgrep -x AetherRoute | awk 'NR==1{print}')
test -n "$app_pid"
test "$(ps -p "$app_pid" -o command= | sed -E 's/^[[:space:]]+//')" = "$APP_BINARY"

provider_pid=$(pgrep -x "$PROVIDER" | awk 'NR==1{print}')
test -n "$provider_pid"
provider_binary=$(ps -p "$provider_pid" -o command= | sed -E 's/^[[:space:]]+//')
test -f "$provider_binary"
provider_root=$(dirname "$(dirname "$(dirname "$provider_binary")")")
provider_cdhash=$(cdhash "$provider_root")
provider_sha=$(shasum -a 256 "$provider_binary" | awk '{print $1}')
test "$provider_cdhash" = "$EXPECTED_PROVIDER_CDHASH"
test "$provider_sha" = "$EXPECTED_PROVIDER_SHA256"
test "$(route -n get default | awk '/interface:/{print $2;exit}')" = en0
! scutil --dns | grep -F 'nameserver[0] : 198.18.0.2' >/dev/null

baseline_v4=$(google_gate -4)
baseline_v6=$(google_gate -6)
nc -z 192.168.64.1 59103
nc -z 192.168.64.1 59104

quit_started=$(date +%s)
osascript -e 'tell application "AetherRoute" to quit'
i=0
while kill -0 "$app_pid" 2>/dev/null; do
  i=$((i + 1))
  test "$i" -le 35
  sleep 1
done
quit_completed=$(date +%s)
quit_seconds=$((quit_completed - quit_started))
test "$quit_seconds" -le 35
test -z "$(pgrep -x AetherRoute 2>/dev/null || true)"
provider_pid_after_quit=$(pgrep -x "$PROVIDER" 2>/dev/null || true)
test "$(route -n get default | awk '/interface:/{print $2;exit}')" = en0
! scutil --dns | grep -F 'nameserver[0] : 198.18.0.2' >/dev/null
google_v4_after_quit=$(direct_google_code -4)
google_v6_after_quit=$(direct_google_code -6)
test "$google_v4_after_quit" != 204
test "$google_v6_after_quit" != 204
apple_after_quit=$(curl -4 --noproxy '*' -sS -o /dev/null -w '%{http_code}' \
  --max-time 8 https://www.apple.com/)
test "$apple_after_quit" = 200
nc -z 192.168.64.1 59103
nc -z 192.168.64.1 59104

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
provider_pid_after_relaunch=$(pgrep -x "$PROVIDER" 2>/dev/null || true)
test "$(route -n get default | awk '/interface:/{print $2;exit}')" = en0
! scutil --dns | grep -F 'nameserver[0] : 198.18.0.2' >/dev/null
google_v4_after_relaunch=$(direct_google_code -4)
test "$google_v4_after_relaunch" != 204

{
  printf 'schema=1\n'
  printf 'completed_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'build=%s\n' "$app_build"
  printf 'app_cdhash=%s\n' "$app_cdhash"
  printf 'old_app_pid=%s\n' "$app_pid"
  printf 'new_app_pid=%s\n' "$new_app_pid"
  printf 'provider_pid_before=%s\n' "$provider_pid"
  printf 'provider_pid_after_quit=%s\n' "${provider_pid_after_quit:-absent}"
  printf 'provider_pid_after_relaunch=%s\n' "${provider_pid_after_relaunch:-absent}"
  printf 'provider_cdhash=%s\n' "$provider_cdhash"
  printf 'provider_sha256=%s\n' "$provider_sha"
  printf 'baseline_google_ipv4=%s\n' "$baseline_v4"
  printf 'baseline_google_ipv6=%s\n' "$baseline_v6"
  printf 'google_ipv4_after_quit=%s\n' "${google_v4_after_quit:-000}"
  printf 'google_ipv6_after_quit=%s\n' "${google_v6_after_quit:-000}"
  printf 'google_ipv4_after_relaunch=%s\n' "${google_v4_after_relaunch:-000}"
  printf 'normal_quit_seconds=%s\n' "$quit_seconds"
  printf 'app_quit_apple_https=%s\n' "$apple_after_quit"
  printf 'provider_process_policy=resident-idle-permitted-after-flow-interception-stops\n'
  printf 'quit_trigger=appkit-normal-quit-apple-event\n'
  printf 'quit_behavior=transparent-interception-stopped-and-base-network-restored\n'
  printf 'relaunch_behavior=remain-disconnected-until-user-connects\n'
  printf 'result=passed\n'
} >"$OUTPUT/result.txt"

(cd "$OUTPUT" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print \
  | LC_ALL=C sort | while IFS= read -r item; do shasum -a 256 "${item#./}"; done >SHA256SUMS)
echo "Transparent normal app-quit cleanup passed: old_app=$app_pid new_app=$new_app_pid provider=$provider_pid seconds=$quit_seconds"
