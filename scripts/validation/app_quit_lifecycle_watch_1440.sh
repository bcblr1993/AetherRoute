#!/bin/sh
set -eu
umask 077

APP=/Applications/AetherRoute.app
PROVIDER=com.aetherroute.desktop.transparent-proxy
EXPECTED_BUILD=${EXPECTED_BUILD:-2026081440}
EXPECTED_APP_CDHASH=${EXPECTED_APP_CDHASH:-63863012b396e5479b67f6535ccbd468e2da30aa}
TRANSPARENT_PROXY_SHA=07127fc2dd861e8f49d521909edcb06e899995b7fb17599e753a150718727293

fail() { echo "app quit lifecycle evidence failed: $*" >&2; exit 1; }
field() { awk -F= -v k="$1" '$1==k{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "$2" || fail "$1 missing"; }
cdhash() { codesign -dv --verbose=4 "$1" 2>&1 | awk -F= '/^CDHash=/{print $2;exit}'; }
app_pid() { pgrep -x AetherRoute 2>/dev/null | awk 'NF{n++;p=$1}END{if(n==1)print p}'; }
provider_pid() { pgrep -x "$PROVIDER" 2>/dev/null | awk 'NF{n++;p=$1}END{if(n==1)print p}'; }
proxy_sha() { scutil --proxy | shasum -a 256 | awk '{print $1}'; }
google_code() { curl "$1" --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 https://www.google.com/generate_204 2>/dev/null || true; }
apple_code() { curl -4 --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 https://www.apple.com/ 2>/dev/null || true; }
capture() {
  stage=$1; file=$2
  {
    printf 'stage=%s\nutc=%s\n' "$stage" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'app_pid=%s\nprovider_pid=%s\n' "$(app_pid)" "$(provider_pid)"
    printf 'proxy_sha256=%s\ndefault_interface=%s\nstub_interface=%s\n' "$(proxy_sha)" \
      "$(route -n get default | awk '/interface:/{print $2;exit}')" \
      "$(route -n get 198.18.0.2 | awk '/interface:/{print $2;exit}')"
    printf 'google_ipv4=%s\ngoogle_ipv6=%s\napple_ipv4=%s\n' "$(google_code -4)" "$(google_code -6)" "$(apple_code)"
  } >"$file"
  chmod 400 "$file"
}

case "${1:-}" in
  begin)
    test "$#" -eq 2 || fail "usage: begin evidence"
    out=$2; case "$out" in /*) ;; *) fail "absolute evidence path required";; esac
    test ! -e "$out" || fail "refusing to overwrite evidence"
    test "$(defaults read "$APP/Contents/Info" CFBundleVersion)" = "$EXPECTED_BUILD" || fail "build mismatch"
    test "$(cdhash "$APP")" = "$EXPECTED_APP_CDHASH" || fail "CDHash mismatch"
    test -n "$(app_pid)" && test -n "$(provider_pid)" || fail "App/provider missing"
    test "$(proxy_sha)" = "$TRANSPARENT_PROXY_SHA" || fail "unexpected proxy baseline"
    mkdir -p "$out"; ditto "$0" "$out/app_quit_lifecycle_watch_1440.sh"; chmod 400 "$out/app_quit_lifecycle_watch_1440.sh"
    capture before "$out/before.txt"
    printf 'schema=1\nstarted_utc=%s\ncandidate_build=%s\nold_app_pid=%s\nprovider_pid_before=%s\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$EXPECTED_BUILD" "$(field app_pid "$out/before.txt")" "$(field provider_pid "$out/before.txt")" >"$out/metadata.txt"
    chmod 400 "$out/metadata.txt"
    echo "app quit lifecycle evidence armed"
    ;;
  after-quit)
    test "$#" -eq 2 || fail "usage: after-quit evidence"
    out=$2; test -d "$out" && test ! -e "$out/after-quit.txt" || fail "invalid evidence"
    i=0; while test -n "$(app_pid)" && test "$i" -lt 40; do sleep 0.5; i=$((i+1)); done
    test -z "$(app_pid)" || fail "App did not quit"
    capture after-quit "$out/after-quit.txt"
    test "$(field proxy_sha256 "$out/after-quit.txt")" = "$TRANSPARENT_PROXY_SHA" || fail "system proxy baseline changed"
    test "$(field default_interface "$out/after-quit.txt")" = en0 || fail "default route not restored"
    test "$(field stub_interface "$out/after-quit.txt")" = en0 || fail "stub route not restored"
    test "$(field apple_ipv4 "$out/after-quit.txt")" = 200 || fail "base network unavailable"
    echo "app quit cleanup checkpoint passed"
    ;;
  after-relaunch)
    test "$#" -eq 2 || fail "usage: after-relaunch evidence"
    out=$2; test -f "$out/after-quit.txt" && test ! -e "$out/result.txt" || fail "invalid evidence"
    i=0; while test -z "$(app_pid)" && test "$i" -lt 40; do sleep 0.5; i=$((i+1)); done
    new_pid=$(app_pid); test -n "$new_pid" || fail "App did not relaunch"
    test "$new_pid" != "$(field old_app_pid "$out/metadata.txt")" || fail "App PID unchanged"
    capture after-relaunch "$out/after-relaunch.txt"
    test "$(field proxy_sha256 "$out/after-relaunch.txt")" = "$TRANSPARENT_PROXY_SHA" || fail "relaunch changed proxy baseline"
    test "$(field default_interface "$out/after-relaunch.txt")" = en0 || fail "relaunch route changed"
    test "$(field apple_ipv4 "$out/after-relaunch.txt")" = 200 || fail "base network unavailable after relaunch"
    {
      printf 'schema=1\ncompleted_utc=%s\ncandidate_build=%s\nold_app_pid=%s\nnew_app_pid=%s\nprovider_process_policy=resident-idle-permitted\nquit_cleanup=passed\nrelaunch_stays_disconnected=passed\nresult=passed\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$EXPECTED_BUILD" "$(field old_app_pid "$out/metadata.txt")" "$new_pid"
    } >"$out/result.txt"
    chmod 400 "$out/result.txt"
    (cd "$out" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "${f#./}"; done >SHA256SUMS)
    chmod 400 "$out/SHA256SUMS"
    echo "app quit lifecycle evidence passed"
    ;;
  verify)
    test "$#" -eq 2 || fail "usage: verify evidence"
    out=$2; (cd "$out" && shasum -a 256 -c SHA256SUMS >/dev/null) || fail "hash closure mismatch"
    test "$(field candidate_build "$out/result.txt")" = "$EXPECTED_BUILD" || fail "build mismatch"
    test "$(field result "$out/result.txt")" = passed || fail "result failed"
    test "$(field quit_cleanup "$out/result.txt")" = passed || fail "cleanup failed"
    test "$(field relaunch_stays_disconnected "$out/result.txt")" = passed || fail "relaunch policy failed"
    echo "app quit lifecycle evidence verified: build=$EXPECTED_BUILD"
    ;;
  *) fail "usage: begin|after-quit|after-relaunch|verify";;
esac
