#!/bin/sh
set -eu
umask 077

# Negative controls for the runtime evidence gate. No app, Network Extension,
# network request, elevated command, or VM is started by this test.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-acceptance-regressions.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
MOCK_BIN="$TEMP/bin"
MOCK_ROOT="$TEMP/fixture"
mkdir -p "$MOCK_BIN" "$MOCK_ROOT/live" "$MOCK_ROOT/home/Library/Logs/DiagnosticReports"
APP="$MOCK_ROOT/AetherRoute.app"
PREF_DIR="$MOCK_ROOT/home/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences"
mkdir -p "$APP/Contents" "$PREF_DIR"
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleVersion</key><string>2026081470</string></dict></plist>
PLIST
for ext in tunnel transparent-proxy; do
  provider="com.aetherroute.desktop.$ext"
  bundle="$APP/Contents/Library/SystemExtensions/$provider.systemextension"
  mkdir -p "$bundle/Contents/MacOS"
  cp "$APP/Contents/Info.plist" "$bundle/Contents/Info.plist"
  printf 'candidate-%s\n' "$provider" >"$bundle/Contents/MacOS/$provider"
  cp "$bundle/Contents/MacOS/$provider" "$MOCK_ROOT/live/$provider"
done
proxy_data=$(printf '%s' '{"version":1,"isEnabled":true,"httpPort":7890,"socksPort":7891}' | base64 | tr -d '\n')
cat >"$PREF_DIR/com.aetherroute.desktop.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>AetherRoute.LocalProxySettings</key><data>$proxy_data</data></dict></plist>
PLIST

cat >"$MOCK_BIN/command-fixture" <<'MOCK'
#!/bin/sh
set -eu
command_name=${0##*/}
case "$command_name" in
  codesign) exit 0 ;;
  spctl) printf 'accepted\nsource=Notarized Developer ID\n' ;;
  defaults)
    case "$*" in
      *AetherRoute.NetworkEngineMode) printf '%s\n' "${MOCK_ENGINE:-tun}" ;;
      *defaultRoutingMode) printf '%s\n' "${MOCK_ROUTING:-rule}" ;;
      *) exit 1 ;;
    esac ;;
  systemextensionsctl)
    for ext in tunnel transparent-proxy; do
      version=2026081470
      if [ "$ext" = transparent-proxy ] && [ "${MOCK_OLD_EXTENSION:-NO}" = YES ]; then
        version=2026081467
      fi
      printf '* * TESTTEAM com.aetherroute.desktop.%s (1.1.0/%s) AetherRoute [activated enabled]\n' "$ext" "$version"
    done
    if [ "${MOCK_DUPLICATE_EXTENSION:-NO}" = YES ]; then
      printf '* * TESTTEAM com.aetherroute.desktop.tunnel (1.1.0/2026081470) AetherRoute [activated enabled]\n'
    fi ;;
  pgrep)
    [ "${MOCK_NO_PROVIDER:-NO}" != YES ] || exit 1
    if [ -f "$MOCK_ROOT/pgrep-called" ] && [ "${MOCK_RESTART:-NO}" = YES ]; then
      printf '456\n'
    else
      printf '123\n'
    fi
    touch "$MOCK_ROOT/pgrep-called" ;;
  ps)
    case "$*" in
      *comm=)
        if [ "${MOCK_WRONG_BINARY:-NO}" = YES ]; then
          printf '%s\n' "$MOCK_ROOT/live/other-provider"
        elif [ "${MOCK_ENGINE:-tun}" = transparent ]; then
          printf '%s\n' "$MOCK_ROOT/live/com.aetherroute.desktop.transparent-proxy"
        else
          printf '%s\n' "$MOCK_ROOT/live/com.aetherroute.desktop.tunnel"
        fi ;;
      *lstart=) printf 'Sat Sep  5 10:00:00 2026\n' ;;
      *) exit 1 ;;
    esac ;;
  scutil)
    if [ -f "$MOCK_ROOT/scutil-called" ] && [ "${MOCK_DISCONNECT_DURING_PROBES:-NO}" = YES ]; then
      printf 'Disconnected\n'
    else
      printf '%s\n' "${MOCK_VPN_STATUS:-Connected}"
    fi
    touch "$MOCK_ROOT/scutil-called" ;;
  route)
    if [ "${MOCK_ENGINE:-tun}" = transparent ]; then
      printf 'interface: en0\n'
    else
      printf 'interface: utun9\n'
    fi ;;
  netstat)
    case "$*" in
      *-f*) printf 'default fe80::1 en0\n' ;;
      *)
        if [ "${MOCK_NETSTAT_FORMAT:-none}" = modern ]; then
          printf 'Proto Recv-Q Send-Q Local Address Foreign Address (state) rxbytes txbytes rhiwat shiwat process:pid state options\n'
          for port in 7890 7891; do
            printf 'tcp4 0 0 127.0.0.1.%s *.* LISTEN 0 0 131072 131072 com.aetherroute.:%s 00100 00000006\n' "$port" "${MOCK_NETSTAT_OWNER:-123}"
            # Foreign owners of established connections, a different port, or
            # a non-loopback interface must not contaminate listener identity.
            printf 'tcp4 0 0 127.0.0.1.%s 127.0.0.1.1234 ESTABLISHED 0 0 131072 131072 other:999 00100 00000006\n' "$port"
            printf 'tcp4 0 0 192.0.2.2.%s *.* LISTEN 0 0 131072 131072 other:999 00100 00000006\n' "$port"
          done
          printf 'tcp4 0 0 127.0.0.1.17890 *.* LISTEN 0 0 131072 131072 other:999 00100 00000006\n'
        elif [ "${MOCK_NETSTAT_FORMAT:-none}" = legacy ]; then
          printf 'Proto Recv-Q Send-Q Local Address Foreign Address (state) rhiwat shiwat pid epid state options\n'
          for port in 7890 7891; do
            printf 'tcp4 0 0 *.%s *.* LISTEN 131072 131072 %s 0 00100 00000006\n' "$port" "${MOCK_NETSTAT_OWNER:-123}"
          done
        fi ;;
    esac ;;
  ifconfig) printf 'utun9: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST>\n' ;;
  lsof) [ "${MOCK_OWNER:-123}" != invisible ] || exit 1; printf '%s\n' "${MOCK_OWNER:-123}" ;;
  sudo) printf 'unexpected privileged invocation\n' >&2; exit 98 ;;
  log)
    case "$*" in
      *processIdentifier*)
        [ "${MOCK_NO_LIFECYCLE:-NO}" != YES ] || exit 0
        printf '2026-09-05 10:00:01 Info stage=startProxy success\n'
        if [ "${MOCK_STOPPED:-NO}" = YES ]; then
          printf '2026-09-05 10:00:02 Info stage=stopProxy requested reason=1\n'
        fi ;;
      *) : ;;
    esac ;;
  curl)
    # Any missed variable/rc guard turns an otherwise healthy case red.
    test "$1" = -q || exit 97
    test -z "${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}${NO_PROXY:-}${http_proxy:-}${https_proxy:-}${all_proxy:-}${no_proxy:-}" || exit 97
    if [ "$2" = --noproxy ]; then
      test "$3" = '' || exit 97
      printf 'proxy\n' >>"$MOCK_ROOT/curl-calls"
    elif [ "$2" = --proxy ]; then
      test "$3" = '' || exit 97
      printf 'direct\n' >>"$MOCK_ROOT/curl-calls"
    else
      exit 97
    fi
    case "$*" in
      *api.ipify.org*) printf '198.51.100.9' ;;
      *ipv6.google.com*) printf '0.012345'; exit "${MOCK_IPV6_EXIT:-0}" ;;
      *api.anthropic.com*) printf '401 0.010' ;;
      *baidu.com*) printf '200 0.010' ;;
      *'%{http_code} %{time_total}'*) printf '204 0.010' ;;
      *) printf '204' ;;
    esac ;;
  *) printf 'unexpected mock command: %s\n' "$command_name" >&2; exit 99 ;;
esac
MOCK
chmod +x "$MOCK_BIN/command-fixture"
for command_name in codesign spctl defaults systemextensionsctl pgrep ps scutil route netstat ifconfig lsof sudo log curl; do
  ln -s command-fixture "$MOCK_BIN/$command_name"
done
printf 'not the installed provider\n' >"$MOCK_ROOT/live/other-provider"

CASES=0
run_case() {
  name=$1
  expected=$2
  marker=$3
  shift 3
  rm -f "$MOCK_ROOT/pgrep-called" "$MOCK_ROOT/scutil-called" "$MOCK_ROOT/curl-calls"
  status=0
  env PATH="$MOCK_BIN:$PATH" HOME="$MOCK_ROOT/home" MOCK_ROOT="$MOCK_ROOT" \
    AETHERROUTE_APP_PATH="$APP" AETHERROUTE_ACCEPTANCE_PRIVILEGED_OBSERVATION=NO \
    HTTP_PROXY=http://invalid HTTPS_PROXY=http://invalid ALL_PROXY=http://invalid NO_PROXY='*' \
    http_proxy=http://invalid https_proxy=http://invalid all_proxy=http://invalid no_proxy='*' \
    "$@" sh "$ROOT/scripts/test_runtime_acceptance.sh" 2026081470 \
    >"$TEMP/$name.txt" 2>&1 || status=$?
  if { [ "$expected" = pass ] && [ "$status" -ne 0 ]; } \
    || { [ "$expected" = fail ] && [ "$status" -eq 0 ]; } \
    || ! grep -F "$marker" "$TEMP/$name.txt" >/dev/null; then
    cat "$TEMP/$name.txt" >&2
    printf 'FAIL: %s (exit %s; expected %s; missing marker %s)\n' "$name" "$status" "$expected" "$marker" >&2
    exit 1
  fi
  if [ "$name" = foreign-listener ] || [ "$name" = invisible-listener ] \
    || [ "$name" = disconnected ]; then
    if grep -qx proxy "$MOCK_ROOT/curl-calls" 2>/dev/null; then
      echo "FAIL: $name attempted proxy probes without candidate ownership" >&2
      exit 1
    fi
  fi
  CASES=$((CASES + 1))
  printf 'PASS: %s\n' "$name"
}

run_case healthy-tun pass '0 failed'
run_case stale-extension fail '2026081467, expected installed build 2026081470' MOCK_OLD_EXTENSION=YES
run_case duplicate-extension fail '2 registrations; expected exactly one' MOCK_DUPLICATE_EXTENSION=YES
run_case disconnected fail 'candidate is not connected' MOCK_VPN_STATUS=Disconnected
run_case foreign-listener fail 'listener is not exclusively owned' MOCK_OWNER=999
run_case invisible-listener fail 'listener ownership unavailable' MOCK_OWNER=invisible
run_case modern-netstat-root-listener pass '0 failed' MOCK_OWNER=invisible MOCK_NETSTAT_FORMAT=modern
run_case legacy-netstat-root-listener pass '0 failed' MOCK_OWNER=invisible MOCK_NETSTAT_FORMAT=legacy
run_case netstat-foreign-listener fail 'listener is not exclusively owned' MOCK_OWNER=invisible MOCK_NETSTAT_FORMAT=modern MOCK_NETSTAT_OWNER=999
run_case netstat-unobservable-listener fail 'listener ownership unavailable' MOCK_NETSTAT_FORMAT=modern MOCK_NETSTAT_OWNER=0
run_case absent-provider fail '0 processes; expected exactly one' MOCK_NO_PROVIDER=YES
run_case wrong-provider fail 'executable differs or cannot be verified' MOCK_WRONG_BINARY=YES
run_case healthy-transparent pass 'current provider completed startup' MOCK_ENGINE=transparent
run_case stopped-transparent fail 'current startup success cannot be verified' MOCK_ENGINE=transparent MOCK_STOPPED=YES
run_case invisible-transparent-state fail 'current startup success cannot be verified' MOCK_ENGINE=transparent MOCK_NO_LIFECYCLE=YES
run_case provider-restarted fail '[FAIL] provider survived all probes' MOCK_RESTART=YES
run_case tunnel-disconnected-after-probes fail '[FAIL] provider survived all probes' MOCK_DISCONNECT_DURING_PROBES=YES
run_case fast-ipv6-unavailable pass '0.012345s (curl exit 7)' MOCK_IPV6_EXIT=7
run_case ipv6-tls-error fail '0.012345s (curl exit 60)' MOCK_IPV6_EXIT=60
printf 'Runtime acceptance regressions passed: %s cases\n' "$CASES"
