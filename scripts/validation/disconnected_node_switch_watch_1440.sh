#!/bin/sh
set -eu
umask 077

APP=/Applications/AetherRoute.app
TUN_BUNDLE=com.aetherroute.desktop.tunnel
STORE=${SELECTION_STORE:-"$HOME/Library/Group Containers/group.com.aetherroute.desktop/Library/Application Support/AetherRoute/proxy-selections.v1.json"}
EXPECTED_BUILD=${EXPECTED_BUILD:-2026081440}
EXPECTED_APP_CDHASH=${EXPECTED_APP_CDHASH:-63863012b396e5479b67f6535ccbd468e2da30aa}

fail() { echo "disconnected node switch evidence failed: $*" >&2; exit 1; }
field() {
  awk -F= -v k="$1" '$1==k{n++;v=substr($0,index($0,"=")+1)}END{if(n!=1)exit 1;print v}' "$2" \
    || fail "$1 must occur exactly once in $2"
}
cdhash() { codesign -dv --verbose=4 "$1" 2>&1 | awk -F= '/^CDHash=/{print $2;exit}'; }
app_pid() { pgrep -x AetherRoute | awk 'NF{n++;p=$1}END{if(n==1)print p}'; }
tun_pid() { pgrep -x "$TUN_BUNDLE" 2>/dev/null | awk 'NF{n++;p=$1}END{if(n==1)print p}'; }
vpn_status() { scutil --nc status AetherRoute 2>/dev/null | head -1; }
hash_store() { test -f "$STORE" && test ! -L "$STORE" || fail "selection store missing"; shasum -a 256 "$STORE" | awk '{print $1}'; }
check_png() {
  case "$1" in /*.png) ;; *) fail "UI evidence path must be an absolute PNG";; esac
  test -f "$1" && test ! -L "$1" || fail "UI evidence missing"
  test "$(sips -g format "$1" 2>/dev/null | awk '/format:/{print $2;exit}')" = png || fail "invalid PNG"
}
capture() {
  prefix=$1
  file=$2
  {
    printf 'checkpoint=%s\n' "$prefix"
    printf 'utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'app_build=%s\n' "$(defaults read "$APP/Contents/Info" CFBundleVersion)"
    printf 'app_cdhash=%s\n' "$(cdhash "$APP")"
    printf 'app_pid=%s\n' "$(app_pid)"
    printf 'vpn_status=%s\n' "$(vpn_status)"
    printf 'tun_pid=%s\n' "$(tun_pid)"
    printf 'selection_sha256=%s\n' "$(hash_store)"
    printf 'system_proxy_sha256=%s\n' "$(scutil --proxy | shasum -a 256 | awk '{print $1}')"
  } >"$file"
  chmod 400 "$file"
}

case "${1:-}" in
  begin)
    test "$#" -eq 5 || fail "usage: begin evidence before-node after-node before.png"
    out=$2; before_node=$3; after_node=$4; ui=$5
    case "$out" in /*) ;; *) fail "evidence path must be absolute";; esac
    test ! -e "$out" || fail "refusing to overwrite evidence"
    test -n "$before_node" && test -n "$after_node" && test "$before_node" != "$after_node" || fail "invalid nodes"
    check_png "$ui"
    test "$(defaults read "$APP/Contents/Info" CFBundleVersion)" = "$EXPECTED_BUILD" || fail "build mismatch"
    test "$(cdhash "$APP")" = "$EXPECTED_APP_CDHASH" || fail "App CDHash mismatch"
    test "$(vpn_status)" = Disconnected || fail "VPN must be disconnected"
    mkdir -p "$out"
    ditto "$0" "$out/disconnected_node_switch_watch_1440.sh"
    ditto "$ui" "$out/ui-before.png"
    capture before "$out/before.txt"
    {
      printf 'schema=1\nstarted_utc=%s\ncandidate_build=%s\nbefore_node=%s\nafter_node=%s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$EXPECTED_BUILD" "$before_node" "$after_node"
    } >"$out/metadata.txt"
    chmod 400 "$out"/*
    echo "disconnected node switch evidence armed"
    ;;
  finish)
    test "$#" -eq 3 || fail "usage: finish evidence after.png"
    out=$2; ui=$3
    test -d "$out" && test ! -e "$out/result.txt" || fail "invalid or finalized evidence"
    check_png "$ui"
    ditto "$ui" "$out/ui-after.png"
    capture after "$out/after.txt"
    app_stable=no; test "$(field app_pid "$out/before.txt")" = "$(field app_pid "$out/after.txt")" && app_stable=yes
    tun_stable=no; test "$(field tun_pid "$out/before.txt")" = "$(field tun_pid "$out/after.txt")" && tun_stable=yes
    selection_changed=no; test "$(field selection_sha256 "$out/before.txt")" != "$(field selection_sha256 "$out/after.txt")" && selection_changed=yes
    result=failed
    test "$(field vpn_status "$out/before.txt")" = Disconnected \
      && test "$(field vpn_status "$out/after.txt")" = Disconnected \
      && test "$app_stable:$tun_stable:$selection_changed" = yes:yes:yes && result=passed
    {
      printf 'schema=1\ncompleted_utc=%s\ncandidate_build=%s\napp_pid_stable=%s\ntun_pid_stable=%s\nselection_changed=%s\nresult=%s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$EXPECTED_BUILD" "$app_stable" "$tun_stable" "$selection_changed" "$result"
    } >"$out/result.txt"
    chmod 400 "$out"/*
    (cd "$out" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "${f#./}"; done >SHA256SUMS)
    chmod 400 "$out/SHA256SUMS"
    test "$result" = passed || fail "result failed"
    echo "disconnected node switch evidence passed"
    ;;
  verify)
    test "$#" -eq 2 || fail "usage: verify evidence"
    out=$2
    (cd "$out" && shasum -a 256 -c SHA256SUMS >/dev/null) || fail "hash closure mismatch"
    test "$(field candidate_build "$out/result.txt")" = "$EXPECTED_BUILD" || fail "candidate mismatch"
    test "$(field result "$out/result.txt")" = passed || fail "result not passed"
    test "$(field app_pid_stable "$out/result.txt")" = yes || fail "App PID changed"
    test "$(field tun_pid_stable "$out/result.txt")" = yes || fail "TUN provider PID changed"
    test "$(field selection_changed "$out/result.txt")" = yes || fail "selection store unchanged"
    test "$(field vpn_status "$out/after.txt")" = Disconnected || fail "VPN started"
    for f in ui-before.png ui-after.png; do check_png "$out/$f"; done
    echo "disconnected node switch evidence verified: build=$EXPECTED_BUILD"
    ;;
  *) fail "usage: begin|finish|verify";;
esac
