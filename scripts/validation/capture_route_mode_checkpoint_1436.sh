#!/bin/sh
set -eu
umask 077

usage() {
  echo "usage: $0 output rule|global|direct expected-provider-pid pass|fail tun|transparent expected-build expected-app-cdhash expected-provider-cdhash expected-provider-sha256" >&2
  exit 64
}
test "$#" -eq 9 || usage
OUTPUT=$1
EXPECTED_MODE=$2
EXPECTED_PID=$3
EXPECTED_GOOGLE=$4
EXPECTED_ENGINE=$5
EXPECTED_BUILD=$6
EXPECTED_APP_CDHASH=$7
EXPECTED_PROVIDER_CDHASH=$8
EXPECTED_PROVIDER_SHA256=$9
case "$OUTPUT" in /*) ;; *) usage;; esac
case "$EXPECTED_MODE" in rule|global|direct) ;; *) usage;; esac
case "$EXPECTED_PID" in ''|*[!0-9]*) usage;; esac
case "$EXPECTED_GOOGLE" in pass|fail) ;; *) usage;; esac
case "$EXPECTED_ENGINE" in tun|transparent) ;; *) usage;; esac
printf '%s\n' "$EXPECTED_BUILD" | grep -Eq '^[1-9][0-9]*$' || usage
printf '%s\n' "$EXPECTED_APP_CDHASH:$EXPECTED_PROVIDER_CDHASH:$EXPECTED_PROVIDER_SHA256" \
  | grep -Eq '^[0-9a-f]{40}:[0-9a-f]{40}:[0-9a-f]{64}$' || usage
test ! -e "$OUTPUT" || { echo "refusing to overwrite $OUTPUT" >&2; exit 1; }

APP=/Applications/AetherRoute.app
case "$EXPECTED_ENGINE" in
  tun)
    PROVIDER=com.aetherroute.desktop.tunnel
    ;;
  transparent)
    PROVIDER=com.aetherroute.desktop.transparent-proxy
    ;;
esac
SERVICE_UUID=$(scutil --nc list \
  | grep -E '"AetherRoute"' \
  | grep -Eo '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' \
  | sed -n '1p')
printf '%s\n' "$SERVICE_UUID" \
  | grep -Eq '^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$' || {
    echo 'AetherRoute service UUID was not found' >&2
    exit 1
  }
FIXTURE_HOST=192.168.64.1
case "$EXPECTED_ENGINE" in
  tun) DNS_SERVER=198.18.0.2;;
  transparent) DNS_SERVER=192.168.64.1;;
esac

mkdir -p "$OUTPUT"
ditto "$0" "$OUTPUT/capture.sh"
chmod 400 "$OUTPUT/capture.sh"

cdhash() { codesign -dv --verbose=4 "$1" 2>&1 | awk -F= '/^CDHash=/{print $2;exit}' || true; }
app_build=$(defaults read "$APP/Contents/Info" CFBundleVersion 2>/dev/null || true)
app_cdhash=$(cdhash "$APP")
provider_pids=$(pgrep -x "$PROVIDER" 2>/dev/null || true)
provider_pid_count=$(printf '%s\n' "$provider_pids" | awk 'NF{n++}END{print n+0}')
provider_pid=$(printf '%s\n' "$provider_pids" | awk 'NF{print;exit}')
provider_path=
provider_build=
provider_cdhash=
provider_sha=
if test -n "$provider_pid"; then
  provider_path=$(ps -p "$provider_pid" -o command= | sed -E 's/^[[:space:]]+//')
  if test -f "$provider_path"; then
    provider_root=$(dirname "$(dirname "$(dirname "$provider_path")")")
    provider_build=$(defaults read "$provider_root/Contents/Info" CFBundleVersion 2>/dev/null || true)
    provider_cdhash=$(cdhash "$provider_root")
    provider_sha=$(shasum -a 256 "$provider_path" | awk '{print $1}')
  fi
fi

service_show=$(scutil --nc show "$SERVICE_UUID" 2>/dev/null || true)
persisted_launch_mode=$(printf '%s\n' "$service_show" | awk '$1=="routingMode"&&$2==":"{print $3;exit}')
vpn_status=$(scutil --nc status "$SERVICE_UUID" 2>/dev/null | head -1 || true)
default_if=$(route -n get default 2>/dev/null | awk '/interface:/{print $2;exit}')
stub_if=$(route -n get 198.18.0.2 2>/dev/null | awk '/interface:/{print $2;exit}')
host_if=$(route -n get "$FIXTURE_HOST" 2>/dev/null | awk '/interface:/{print $2;exit}')
proxy_sha=$(scutil --proxy | shasum -a 256 | awk '{print $1}')

fixture_a=failed
fixture_b=failed
nc -z "$FIXTURE_HOST" 59103 >/dev/null 2>&1 && fixture_a=passed
nc -z "$FIXTURE_HOST" 59104 >/dev/null 2>&1 && fixture_b=passed

google_v4=failed
google_v6=failed
curl -4 -sS --max-time 8 -o /dev/null -w '%{http_code}' \
  https://www.google.com/generate_204 >"$OUTPUT/google-v4.txt" 2>&1 \
  && test "$(tail -c 3 "$OUTPUT/google-v4.txt")" = 204 && google_v4=passed || true
curl -6 -sS --max-time 8 -o /dev/null -w '%{http_code}' \
  https://www.google.com/generate_204 >"$OUTPUT/google-v6.txt" 2>&1 \
  && test "$(tail -c 3 "$OUTPUT/google-v6.txt")" = 204 && google_v6=passed || true
google_result=failed
test "$google_v4" = passed && test "$google_v6" = passed && google_result=passed

apple_direct=failed
curl -4 -sS --max-time 8 --connect-timeout 5 -o /dev/null \
  https://captive.apple.com/hotspot-detect.html && apple_direct=passed || true

dns_udp=failed
dns_tcp=failed
nonce="mode-$(uuidgen | tr A-Z a-z).example.com"
dig -4 @"$DNS_SERVER" "$nonce" A +time=5 +tries=1 +retry=0 +noall +comments +stats \
  >"$OUTPUT/dns-udp.txt" 2>&1 \
  && grep -Eq 'status: (NOERROR|NXDOMAIN)' "$OUTPUT/dns-udp.txt" && dns_udp=passed || true
dig -4 @"$DNS_SERVER" "tcp-$nonce" A +tcp +time=5 +tries=1 +retry=0 +noall +comments +stats \
  >"$OUTPUT/dns-tcp.txt" 2>&1 \
  && grep -Eq 'status: (NOERROR|NXDOMAIN)' "$OUTPUT/dns-tcp.txt" && dns_tcp=passed || true

recent_crash_count=0
crash_dir="$HOME/Library/Logs/DiagnosticReports"
if test -d "$crash_dir"; then
  recent_crash_count=$(find "$crash_dir" -type f -mmin -10 \
    \( -iname 'AetherRoute*' -o -iname 'com.aetherroute*' \) 2>/dev/null \
    | awk 'NF{n++}END{print n+0}')
fi

{
  printf 'service_begin\n'; printf '%s\n' "$service_show"; printf 'service_end\n'
  printf 'network_begin\n'; scutil --nc list; scutil --proxy; scutil --dns; \
    route -n get default; route -n get 198.18.0.2; route -n get "$FIXTURE_HOST"; printf 'network_end\n'
  printf 'processes_begin\n'; ps -axo pid=,ppid=,rss=,command= | grep -E 'AetherRoute|com\.aetherroute' | grep -v grep || true; printf 'processes_end\n'
} >"$OUTPUT/runtime.txt"

google_expectation=failed
case "$EXPECTED_GOOGLE:$google_result" in
  pass:passed|fail:failed) google_expectation=matched;;
esac
result=passed
test "$app_build" = "$EXPECTED_BUILD" || result=failed
test "$app_cdhash" = "$EXPECTED_APP_CDHASH" || result=failed
test "$provider_pid_count" -eq 1 || result=failed
test "$provider_pid" = "$EXPECTED_PID" || result=failed
test "$provider_build" = "$EXPECTED_BUILD" || result=failed
test "$provider_cdhash" = "$EXPECTED_PROVIDER_CDHASH" || result=failed
test "$provider_sha" = "$EXPECTED_PROVIDER_SHA256" || result=failed
# Connected route-mode changes are acknowledged by the running provider and
# deliberately do not rewrite the persisted launch snapshot. Keeping the
# launch value at rule also proves the manager was not restarted during the
# hot switch; the expected runtime mode is bound to the reviewed UI snapshot.
test "$persisted_launch_mode" = rule || result=failed
case "$EXPECTED_ENGINE" in
  tun)
    test "$vpn_status" = Connected || result=failed
    case "$default_if" in utun[0-9]*) ;; *) result=failed;; esac
    test "$stub_if" = "$default_if" || result=failed
    test "$host_if" = en0 || result=failed
    test "$proxy_sha" = 309309dd60b8263c4dbbcfc5194716c3cb542b1a64aca05ab55d659ffd46a218 || result=failed
    ;;
  transparent)
    test "$vpn_status" = Disconnected || result=failed
    test "$default_if" = en0 || result=failed
    test "$stub_if" = en0 || result=failed
    test "$host_if" = en0 || result=failed
    test "$proxy_sha" = 07127fc2dd861e8f49d521909edcb06e899995b7fb17599e753a150718727293 || result=failed
    ;;
esac
test "$fixture_a" = passed || result=failed
test "$fixture_b" = passed || result=failed
test "$apple_direct" = passed || result=failed
test "$dns_udp" = passed || result=failed
test "$dns_tcp" = passed || result=failed
test "$google_expectation" = matched || result=failed
test "$recent_crash_count" -eq 0 || result=failed

{
  printf 'schema=1\n'
  printf 'completed_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'engine=%s\n' "$EXPECTED_ENGINE"
  printf 'expected_runtime_mode=%s\n' "$EXPECTED_MODE"
  printf 'runtime_mode_evidence=provider-acknowledged-ui\n'
  printf 'persisted_launch_mode=%s\n' "$persisted_launch_mode"
  printf 'expected_provider_pid=%s\n' "$EXPECTED_PID"
  printf 'provider_pid_count=%s\n' "$provider_pid_count"
  printf 'provider_pid=%s\n' "$provider_pid"
  printf 'provider_build=%s\n' "$provider_build"
  printf 'provider_cdhash=%s\n' "$provider_cdhash"
  printf 'provider_sha256=%s\n' "$provider_sha"
  printf 'app_build=%s\n' "$app_build"
  printf 'app_cdhash=%s\n' "$app_cdhash"
  printf 'vpn_status=%s\n' "$vpn_status"
  printf 'default_interface=%s\n' "$default_if"
  printf 'synthetic_stub_interface=%s\n' "$stub_if"
  printf 'fixture_host_interface=%s\n' "$host_if"
  printf 'system_proxy_sha256=%s\n' "$proxy_sha"
  printf 'fixture_a=%s\n' "$fixture_a"
  printf 'fixture_b=%s\n' "$fixture_b"
  printf 'dns_udp=%s\n' "$dns_udp"
  printf 'dns_tcp=%s\n' "$dns_tcp"
  printf 'apple_direct=%s\n' "$apple_direct"
  printf 'expected_google=%s\n' "$EXPECTED_GOOGLE"
  printf 'google_ipv4=%s\n' "$google_v4"
  printf 'google_ipv6=%s\n' "$google_v6"
  printf 'google_result=%s\n' "$google_result"
  printf 'google_expectation=%s\n' "$google_expectation"
  printf 'recent_crash_count=%s\n' "$recent_crash_count"
  printf 'result=%s\n' "$result"
} >"$OUTPUT/result.txt"

(cd "$OUTPUT" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print \
  | LC_ALL=C sort | while IFS= read -r path; do shasum -a 256 "${path#./}"; done >SHA256SUMS)
test "$result" = passed || { echo "route-mode checkpoint failed" >&2; exit 1; }
echo "route-mode checkpoint passed: runtime=$EXPECTED_MODE launch=$persisted_launch_mode pid=$provider_pid google=$google_result"
