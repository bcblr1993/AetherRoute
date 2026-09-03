#!/bin/sh
set -eu
umask 077

usage() {
  echo "usage: $0 output expected-build expected-app-cdhash expected-tun-cdhash expected-tun-sha256 https-probe https-probe-sha256 stun-probe stun-probe-sha256 pass|known-fail" >&2
  exit 64
}

test "$#" -eq 10 || usage
OUTPUT=$1
EXPECTED_BUILD=$2
EXPECTED_APP_CDHASH=$3
EXPECTED_TUN_CDHASH=$4
EXPECTED_TUN_SHA256=$5
HTTPS_PROBE=$6
EXPECTED_HTTPS_PROBE_SHA256=$7
STUN_PROBE=$8
EXPECTED_STUN_PROBE_SHA256=$9
STUN_POLICY=${10}

case "$OUTPUT" in /*) ;; *) usage;; esac
case "$STUN_POLICY" in pass|known-fail) ;; *) usage;; esac
test ! -e "$OUTPUT" || { echo "refusing to overwrite $OUTPUT" >&2; exit 1; }

APP=/Applications/AetherRoute.app
PROVIDER=com.aetherroute.desktop.tunnel
FIXTURE_HOST=192.168.64.1
EXPECTED_PROXY_SHA256=309309dd60b8263c4dbbcfc5194716c3cb542b1a64aca05ab55d659ffd46a218

for value in "$EXPECTED_APP_CDHASH" "$EXPECTED_TUN_CDHASH" "$EXPECTED_TUN_SHA256" \
  "$EXPECTED_HTTPS_PROBE_SHA256" "$EXPECTED_STUN_PROBE_SHA256"; do
  printf '%s\n' "$value" | grep -Eq '^[0-9a-f]{40}$|^[0-9a-f]{64}$' || usage
done

test -f "$HTTPS_PROBE" && test ! -L "$HTTPS_PROBE" && test -x "$HTTPS_PROBE"
test -f "$STUN_PROBE" && test ! -L "$STUN_PROBE" && test -x "$STUN_PROBE"
test "$(shasum -a 256 "$HTTPS_PROBE" | awk '{print $1}')" = "$EXPECTED_HTTPS_PROBE_SHA256"
test "$(shasum -a 256 "$STUN_PROBE" | awk '{print $1}')" = "$EXPECTED_STUN_PROBE_SHA256"

mkdir -p "$OUTPUT"
ditto "$0" "$OUTPUT/capture.sh"
chmod 400 "$OUTPUT/capture.sh"

current_cdhash() {
  codesign -dv --verbose=4 "$1" 2>&1 | awk -F= '/^CDHash=/{print $2;exit}' || true
}

app_build=$(defaults read "$APP/Contents/Info" CFBundleVersion 2>/dev/null || true)
app_cdhash=$(current_cdhash "$APP")
embedded="$APP/Contents/Library/SystemExtensions/$PROVIDER.systemextension"
embedded_build=$(defaults read "$embedded/Contents/Info" CFBundleVersion 2>/dev/null || true)
embedded_cdhash=$(current_cdhash "$embedded")
embedded_binary="$embedded/Contents/MacOS/$PROVIDER"
embedded_sha=$(shasum -a 256 "$embedded_binary" 2>/dev/null | awk '{print $1}' || true)

tun_pids=$(pgrep -x "$PROVIDER" 2>/dev/null || true)
tun_pid_count=$(printf '%s\n' "$tun_pids" | awk 'NF{n++}END{print n+0}')
tun_pid=$(printf '%s\n' "$tun_pids" | awk 'NF{print;exit}')
running_path=
running_build=
running_cdhash=
running_sha=
if test -n "$tun_pid"; then
  running_path=$(ps -p "$tun_pid" -o command= | sed -E 's/^[[:space:]]+//')
  if test -f "$running_path"; then
    running_root=$(dirname "$(dirname "$(dirname "$running_path")")")
    running_build=$(defaults read "$running_root/Contents/Info" CFBundleVersion 2>/dev/null || true)
    running_cdhash=$(current_cdhash "$running_root")
    running_sha=$(shasum -a 256 "$running_path" | awk '{print $1}')
  fi
fi

transparent_pid_count=$(pgrep -x com.aetherroute.desktop.transparent-proxy 2>/dev/null \
  | awk 'NF{n++}END{print n+0}')
service_uuid=
service_matches=0
for uuid in $(scutil --nc list | grep -Eo '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | sort -u); do
  show=$(scutil --nc show "$uuid" 2>/dev/null || true)
  provider_count=$(printf '%s\n' "$show" \
    | awk -v p="$PROVIDER" '$1=="NEProviderBundleIdentifier"&&$2==":"&&$3==p{n++}END{print n+0}')
  connected=no
  printf '%s\n' "$show" | head -1 | grep -F '(Connected)' >/dev/null && connected=yes
  if test "$provider_count" -eq 1 && test "$connected" = yes; then
    service_matches=$((service_matches + 1))
    service_uuid=$uuid
  fi
done

stub_if=$(route -n get 198.18.0.2 2>/dev/null | awk '/interface:/{print $2;exit}')
host_if=$(route -n get "$FIXTURE_HOST" 2>/dev/null | awk '/interface:/{print $2;exit}')
proxy_sha=$(scutil --proxy | shasum -a 256 | awk '{print $1}')
synthetic_address_present=no
case "$stub_if" in
  utun[0-9]*) ifconfig "$stub_if" | grep -F 'inet 198.18.0.1 ' >/dev/null \
    && synthetic_address_present=yes;;
esac
synthetic_resolver_present=no
scutil --dns | grep -F 'nameserver[0] : 198.18.0.2' >/dev/null \
  && synthetic_resolver_present=yes
en0_dns_present=no
scutil --dns | grep -F '192.168.64.1' >/dev/null && en0_dns_present=yes

fixture_a=failed
fixture_b=failed
nc -z "$FIXTURE_HOST" 59003 >/dev/null 2>&1 && fixture_a=passed
nc -z "$FIXTURE_HOST" 59004 >/dev/null 2>&1 && fixture_b=passed

ipv4=failed
ipv6=failed
robots=failed
"$HTTPS_PROBE" ipv4-generate-204 >"$OUTPUT/ipv4-https.txt" 2>&1 && ipv4=passed || true
"$HTTPS_PROBE" ipv6-generate-204 >"$OUTPUT/ipv6-https.txt" 2>&1 && ipv6=passed || true
"$HTTPS_PROBE" ipv4-robots >"$OUTPUT/robots-https.txt" 2>&1 && robots=passed || true

dns_udp=failed
dns_tcp=failed
nonce="checkpoint-$(uuidgen | tr A-Z a-z).example.com"
dig -4 @198.18.0.2 "$nonce" A +time=5 +tries=1 +retry=0 +noall +comments +stats 2>/dev/null \
  | awk '/status: (NOERROR|NXDOMAIN)/{s=1}/SERVER: 198.18.0.2#53/{d=1}END{exit !(s&&d)}' \
  && dns_udp=passed
dig -4 @198.18.0.2 "tcp-$nonce" A +tcp +time=5 +tries=1 +retry=0 +noall +comments +stats 2>/dev/null \
  | awk '/status: (NOERROR|NXDOMAIN)/{s=1}/SERVER: 198.18.0.2#53/{d=1}END{exit !(s&&d)}' \
  && dns_tcp=passed

stun_pattern=
stun_successes=0
attempt=1
while test "$attempt" -le 3; do
  if "$STUN_PROBE" stun.l.google.com 19302 8 >"$OUTPUT/stun-$attempt.txt" 2>&1; then
    stun_pattern="${stun_pattern}P"
    stun_successes=$((stun_successes + 1))
  else
    stun_pattern="${stun_pattern}F"
  fi
  attempt=$((attempt + 1))
done
stun=failed
test "$stun_successes" -ge 2 && stun=passed

{
  printf 'systemextensionsctl_begin\n'; systemextensionsctl list; printf 'systemextensionsctl_end\n'
  printf 'scutil_nc_list_begin\n'; scutil --nc list; printf 'scutil_nc_list_end\n'
  printf 'scutil_nc_show_begin\n'; test -z "$service_uuid" || scutil --nc show "$service_uuid"; printf 'scutil_nc_show_end\n'
  printf 'dns_begin\n'; scutil --dns; printf 'dns_end\n'
  printf 'proxy_begin\n'; scutil --proxy; printf 'proxy_end\n'
  printf 'routes_begin\n'; route -n get default; route -n get 198.18.0.2; route -n get "$FIXTURE_HOST"; printf 'routes_end\n'
  printf 'tun_ifconfig_begin\n'; test -z "$stub_if" || ifconfig "$stub_if"; printf 'tun_ifconfig_end\n'
} >"$OUTPUT/runtime.txt"

baseline=passed
test "$app_build" = "$EXPECTED_BUILD" || baseline=failed
test "$app_cdhash" = "$EXPECTED_APP_CDHASH" || baseline=failed
test "$embedded_build" = "$EXPECTED_BUILD" || baseline=failed
test "$embedded_cdhash" = "$EXPECTED_TUN_CDHASH" || baseline=failed
test "$embedded_sha" = "$EXPECTED_TUN_SHA256" || baseline=failed
test "$tun_pid_count" -eq 1 || baseline=failed
test "$running_build" = "$EXPECTED_BUILD" || baseline=failed
test "$running_cdhash" = "$EXPECTED_TUN_CDHASH" || baseline=failed
test "$running_sha" = "$EXPECTED_TUN_SHA256" || baseline=failed
test "$transparent_pid_count" -eq 0 || baseline=failed
test "$service_matches" -eq 1 || baseline=failed
case "$stub_if" in utun[0-9]*) ;; *) baseline=failed;; esac
test "$host_if" = en0 || baseline=failed
test "$proxy_sha" = "$EXPECTED_PROXY_SHA256" || baseline=failed
test "$synthetic_address_present" = yes || baseline=failed
test "$synthetic_resolver_present" = yes || baseline=failed
test "$en0_dns_present" = yes || baseline=failed
test "$fixture_a" = passed || baseline=failed
test "$fixture_b" = passed || baseline=failed
test "$ipv4" = passed || baseline=failed
test "$ipv6" = passed || baseline=failed
test "$robots" = passed || baseline=failed
test "$dns_udp" = passed || baseline=failed
test "$dns_tcp" = passed || baseline=failed

stun_expectation=failed
case "$STUN_POLICY:$stun" in pass:passed|known-fail:failed) stun_expectation=matched;; esac
release_gate=failed
test "$baseline" = passed && test "$stun" = passed && release_gate=passed
checkpoint_integrity=failed
test "$baseline" = passed && test "$stun_expectation" = matched && checkpoint_integrity=passed

{
  printf 'schema=2\n'
  printf 'completed_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'expected_stun_policy=%s\n' "$STUN_POLICY"
  printf 'app_build=%s\n' "$app_build"
  printf 'app_cdhash=%s\n' "$app_cdhash"
  printf 'embedded_build=%s\n' "$embedded_build"
  printf 'embedded_cdhash=%s\n' "$embedded_cdhash"
  printf 'embedded_sha256=%s\n' "$embedded_sha"
  printf 'tun_pid_count=%s\n' "$tun_pid_count"
  printf 'running_build=%s\n' "$running_build"
  printf 'running_cdhash=%s\n' "$running_cdhash"
  printf 'running_sha256=%s\n' "$running_sha"
  printf 'transparent_pid_count=%s\n' "$transparent_pid_count"
  printf 'connected_service_matches=%s\n' "$service_matches"
  printf 'connected_service_uuid=%s\n' "$service_uuid"
  printf 'synthetic_stub_interface=%s\n' "$stub_if"
  printf 'fixture_host_interface=%s\n' "$host_if"
  printf 'system_proxy_sha256=%s\n' "$proxy_sha"
  printf 'synthetic_address_present=%s\n' "$synthetic_address_present"
  printf 'synthetic_resolver_present=%s\n' "$synthetic_resolver_present"
  printf 'en0_dns_present=%s\n' "$en0_dns_present"
  printf 'fixture_a=%s\n' "$fixture_a"
  printf 'fixture_b=%s\n' "$fixture_b"
  printf 'ipv4_https=%s\n' "$ipv4"
  printf 'ipv6_https=%s\n' "$ipv6"
  printf 'robots_https=%s\n' "$robots"
  printf 'dns_udp=%s\n' "$dns_udp"
  printf 'dns_tcp=%s\n' "$dns_tcp"
  printf 'stun_udp=%s\n' "$stun"
  printf 'stun_attempt_pattern=%s\n' "$stun_pattern"
  printf 'stun_successes=%s\n' "$stun_successes"
  printf 'stun_expectation=%s\n' "$stun_expectation"
  printf 'baseline_result=%s\n' "$baseline"
  printf 'release_gate=%s\n' "$release_gate"
  printf 'checkpoint_integrity=%s\n' "$checkpoint_integrity"
} >"$OUTPUT/result.txt"

(cd "$OUTPUT" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print \
  | LC_ALL=C sort | while IFS= read -r path; do shasum -a 256 "${path#./}"; done >SHA256SUMS)

test "$checkpoint_integrity" = passed || { echo "connected checkpoint failed" >&2; exit 1; }
echo "connected checkpoint captured: baseline=$baseline stun=$stun release_gate=$release_gate"
