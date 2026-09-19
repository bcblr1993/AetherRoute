#!/bin/sh
set -eu
umask 077

OUTPUT=${1:-}
EXPECTED_BUILD=${2:-2026081434}
EXPECTED_TUN_SHA256=${3:-}
DURATION_SECONDS=${4:-14400}
INTERVAL_SECONDS=${5:-5}

usage() {
  echo "usage: $0 /absolute/new-evidence-directory build tun-sha256 [duration-seconds] [interval-seconds]" >&2
}

case "$OUTPUT" in
  /*) ;;
  *) usage; exit 64 ;;
esac
printf '%s\n' "$EXPECTED_BUILD" | grep -Eq '^[1-9][0-9]*$' || {
  usage
  exit 64
}
printf '%s\n' "$EXPECTED_TUN_SHA256" | grep -Eq '^[0-9a-f]{64}$' || {
  usage
  exit 64
}
printf '%s\n' "$DURATION_SECONDS:$INTERVAL_SECONDS" \
  | grep -Eq '^[1-9][0-9]*:[1-9][0-9]*$' || {
    usage
    exit 64
  }
test "$INTERVAL_SECONDS" -le 60 || {
  echo "interval must be at most 60 seconds" >&2
  exit 64
}
test ! -e "$OUTPUT" || {
  echo "refusing to overwrite evidence: $OUTPUT" >&2
  exit 1
}
PARENT=$(dirname -- "$OUTPUT")
test -d "$PARENT" || {
  echo "evidence parent does not exist: $PARENT" >&2
  exit 66
}

APP=/Applications/AetherRoute.app
TUN="$APP/Contents/Library/SystemExtensions/com.aetherroute.desktop.tunnel.systemextension"
TUN_EXECUTABLE="$TUN/Contents/MacOS/com.aetherroute.desktop.tunnel"
STORE_ROOT="$HOME/Library/Group Containers/group.com.aetherroute.desktop/Library/Application Support/AetherRoute"
PROFILE_CATALOG="$STORE_ROOT/profile-catalog.v1.json"
ACTIVE_PROFILE="$STORE_ROOT/active-profile.v2.json"
SELECTION_STORE="$STORE_ROOT/proxy-selections.v1.json"
for path in "$APP" "$TUN" "$TUN_EXECUTABLE"; do
  test -e "$path" || {
    echo "required candidate component is missing: $path" >&2
    exit 66
  }
done

BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$APP/Contents/Info.plist")
test "$BUILD" = "$EXPECTED_BUILD" || {
  echo "installed build mismatch: expected $EXPECTED_BUILD, found $BUILD" >&2
  exit 1
}
TUN_SHA256=$(shasum -a 256 "$TUN_EXECUTABLE" | awk '{print $1}')
test "$TUN_SHA256" = "$EXPECTED_TUN_SHA256" || {
  echo "installed TUN hash mismatch" >&2
  exit 1
}

VPN_STATUS=$(scutil --nc status AetherRoute 2>/dev/null | sed -n '1p')
test "$VPN_STATUS" = Connected || {
  echo "AetherRoute must already be Connected; this diagnostic never changes network state" >&2
  exit 1
}

mkdir -m 700 -- "$OUTPUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-network-diagnostic.XXXXXX")
cleanup() {
  if [ -n "${LOG_STREAM_PID:-}" ]; then
    kill "$LOG_STREAM_PID" 2>/dev/null || true
    wait "$LOG_STREAM_PID" 2>/dev/null || true
  fi
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

field_or_dash() {
  value=$1
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' '-'
  fi
}

sha256_or_dash() {
  if [ -f "$1" ] && [ ! -L "$1" ]; then
    sha256 "$1"
  else
    printf '-'
  fi
}

process_pid() {
  executable=$1
  pgrep -f "$executable" 2>/dev/null | sed -n '1p'
}

process_rss() {
  pid=$1
  if [ -n "$pid" ]; then
    ps -o rss= -p "$pid" 2>/dev/null | awk '{$1=$1; print; exit}'
  fi
}

process_fds() {
  pid=$1
  if [ -n "$pid" ]; then
    lsof -n -p "$pid" 2>/dev/null | awk 'END {print NR+0}'
  fi
}

probe_https() {
  family=$1
  url=$2
  destination=$3
  set +e
  output=$(curl "$family" --silent --show-error --output /dev/null \
    --connect-timeout 3 --max-time 8 \
    --write-out '%{http_code}|%{remote_ip}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_total}' \
    "$url" 2>"$destination.stderr")
  status=$?
  set -e
  printf '%s|%s\n' "$status" "$output" >"$destination.result"
}

probe_dns() {
  transport=$1
  destination=$2
  tcp_flag=
  if [ "$transport" = tcp ]; then
    tcp_flag=+tcp
  fi
  set +e
  output=$(/usr/bin/dig $tcp_flag +time=2 +tries=1 \
    www.google.com A 2>"$destination.stderr")
  status=$?
  set -e
  answers=$(printf '%s\n' "$output" \
    | awk '$4 == "A" {count++} END {print count+0}')
  printf '%s|%s\n' "$status" "$answers" >"$destination.result"
}

capture_failure_window() {
  sample=$1
  failure_dir="$OUTPUT/failure-$sample"
  mkdir -m 700 -- "$failure_dir"

  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$failure_dir/captured-utc.txt"
  ps -axo pid=,ppid=,rss=,%cpu=,command= \
    | grep -E '[A]etherRoute|com\.aetherroute\.desktop\.(tunnel|transparent-proxy)' \
    >"$failure_dir/processes.txt" || true
  (scutil --nc status AetherRoute) >"$failure_dir/vpn-status.txt" 2>&1 || true
  scutil --dns >"$failure_dir/scutil-dns.txt" 2>&1 || true
  route -n get default >"$failure_dir/route-default.txt" 2>&1 || true
  route -n get 8.8.8.8 >"$failure_dir/route-google-v4.txt" 2>&1 || true
  route -n get 2001:4860:4860::8888 \
    >"$failure_dir/route-google-v6.txt" 2>&1 || true
  route -n get 198.18.0.1 >"$failure_dir/route-fake-ip.txt" 2>&1 || true
  netstat -rn -f inet >"$failure_dir/netstat-inet.txt" 2>&1 || true
  netstat -rn -f inet6 >"$failure_dir/netstat-inet6.txt" 2>&1 || true
  ifconfig >"$failure_dir/ifconfig.txt" 2>&1 || true

  log show --last 3m --style compact \
    --predicate '(process == "AetherRoute" OR process == "com.aetherroute.desktop.tunnel" OR eventMessage CONTAINS "aether_flow stage=") AND (eventMessage CONTAINS "aether_flow stage=" OR eventMessage CONTAINS "automaticRouteHealth" OR eventMessage CONTAINS "automaticRouteSelection" OR eventMessage CONTAINS "connectionReadiness")' \
    >"$failure_dir/safe-stage-log.txt" 2>&1 || true

  attempt=1
  while [ "$attempt" -le 12 ]; do
    probe_https -4 https://www.google.com/generate_204 \
      "$failure_dir/burst-$attempt-google-v4" &
    probe_pid_1=$!
    probe_https -6 https://www.google.com/generate_204 \
      "$failure_dir/burst-$attempt-google-v6" &
    probe_pid_2=$!
    probe_https -4 https://cp.cloudflare.com/generate_204 \
      "$failure_dir/burst-$attempt-cloudflare-v4" &
    probe_pid_3=$!
    probe_https -6 https://cp.cloudflare.com/generate_204 \
      "$failure_dir/burst-$attempt-cloudflare-v6" &
    probe_pid_4=$!
    probe_dns udp "$failure_dir/burst-$attempt-dns-udp" &
    probe_pid_5=$!
    probe_dns tcp "$failure_dir/burst-$attempt-dns-tcp" &
    probe_pid_6=$!
    wait "$probe_pid_1"
    wait "$probe_pid_2"
    wait "$probe_pid_3"
    wait "$probe_pid_4"
    wait "$probe_pid_5"
    wait "$probe_pid_6"
    sleep 1
    attempt=$((attempt + 1))
  done

  app_pid=$(process_pid '/Applications/AetherRoute.app/Contents/MacOS/AetherRoute')
  tun_pid=$(process_pid 'com.aetherroute.desktop.tunnel.systemextension/Contents/MacOS/com.aetherroute.desktop.tunnel')
  if [ -n "$app_pid" ]; then
    sample "$app_pid" 3 1 -file "$failure_dir/app-sample.txt" \
      >/dev/null 2>&1 || true
    vmmap -summary "$app_pid" >"$failure_dir/app-vmmap.txt" 2>&1 || true
  fi
  if [ -n "$tun_pid" ]; then
    sample "$tun_pid" 3 1 -file "$failure_dir/tun-sample.txt" \
      >/dev/null 2>&1 || true
    vmmap -summary "$tun_pid" >"$failure_dir/tun-vmmap.txt" 2>&1 || true
  fi
}

cp "$0" "$OUTPUT/runner.sh"
chmod 400 "$OUTPUT/runner.sh"
START_EPOCH=$(date +%s)
START_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
END_EPOCH=$((START_EPOCH + DURATION_SECONDS))
{
  printf 'schema=1\n'
  printf 'build=%s\n' "$EXPECTED_BUILD"
  printf 'installed_tun_sha256=%s\n' "$TUN_SHA256"
  printf 'runner_sha256=%s\n' "$(sha256 "$OUTPUT/runner.sh")"
  printf 'started_utc=%s\n' "$START_UTC"
  printf 'duration_seconds=%s\n' "$DURATION_SECONDS"
  printf 'interval_seconds=%s\n' "$INTERVAL_SECONDS"
  printf 'network_state_mutation=none\n'
} >"$OUTPUT/metadata.txt"

printf 'sample\tutc\tapp_pid\tapp_rss_kb\tapp_fds\ttun_pid\ttun_rss_kb\ttun_fds\tvpn_status\tstub_interface\tdefault_interface\tgoogle_v4_exit\tgoogle_v4_http\tgoogle_v4_remote\tgoogle_v4_dns_s\tgoogle_v4_connect_s\tgoogle_v4_tls_s\tgoogle_v4_total_s\tgoogle_v6_exit\tgoogle_v6_http\tgoogle_v6_remote\tgoogle_v6_dns_s\tgoogle_v6_connect_s\tgoogle_v6_tls_s\tgoogle_v6_total_s\tcloudflare_v4_exit\tcloudflare_v4_http\tcloudflare_v6_exit\tcloudflare_v6_http\tdns_udp_exit\tdns_udp_answers\tdns_tcp_exit\tdns_tcp_answers\tprofile_catalog_sha256\tactive_profile_sha256\tselection_store_sha256\n' \
  >"$OUTPUT/samples.tsv"

log stream --style compact --level info \
  --predicate '(process == "AetherRoute" OR process == "com.aetherroute.desktop.tunnel" OR eventMessage CONTAINS "aether_flow stage=") AND (eventMessage CONTAINS "aether_flow stage=" OR eventMessage CONTAINS "automaticRouteHealth" OR eventMessage CONTAINS "automaticRouteSelection" OR eventMessage CONTAINS "connectionReadiness")' \
  >"$OUTPUT/safe-stage-stream.txt" 2>&1 &
LOG_STREAM_PID=$!

sample_number=0
failure_samples=0
failure_windows=0
previous_sample_failed=0
while [ "$(date +%s)" -lt "$END_EPOCH" ]; do
  sample_number=$((sample_number + 1))
  sample_work="$WORK/sample-$sample_number"
  mkdir -- "$sample_work"
  utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  app_pid=$(process_pid '/Applications/AetherRoute.app/Contents/MacOS/AetherRoute')
  tun_pid=$(process_pid 'com.aetherroute.desktop.tunnel.systemextension/Contents/MacOS/com.aetherroute.desktop.tunnel')
  app_rss=$(process_rss "$app_pid")
  tun_rss=$(process_rss "$tun_pid")
  app_fds=$(process_fds "$app_pid")
  tun_fds=$(process_fds "$tun_pid")
  vpn_status=$(scutil --nc status AetherRoute 2>/dev/null | sed -n '1p')
  stub_interface=$(route -n get 198.18.0.1 2>/dev/null \
    | awk '$1 == "interface:" {print $2; exit}')
  default_interface=$(route -n get default 2>/dev/null \
    | awk '$1 == "interface:" {print $2; exit}')

  probe_https -4 https://www.google.com/generate_204 "$sample_work/google-v4" &
  probe_pid_1=$!
  probe_https -6 https://www.google.com/generate_204 "$sample_work/google-v6" &
  probe_pid_2=$!
  probe_https -4 https://cp.cloudflare.com/generate_204 "$sample_work/cloudflare-v4" &
  probe_pid_3=$!
  probe_https -6 https://cp.cloudflare.com/generate_204 "$sample_work/cloudflare-v6" &
  probe_pid_4=$!
  probe_dns udp "$sample_work/dns-udp" &
  probe_pid_5=$!
  probe_dns tcp "$sample_work/dns-tcp" &
  probe_pid_6=$!
  wait "$probe_pid_1"
  wait "$probe_pid_2"
  wait "$probe_pid_3"
  wait "$probe_pid_4"
  wait "$probe_pid_5"
  wait "$probe_pid_6"

  IFS='|' read -r google_v4_exit google_v4_http google_v4_remote \
    google_v4_dns google_v4_connect google_v4_tls google_v4_total \
    <"$sample_work/google-v4.result"
  IFS='|' read -r google_v6_exit google_v6_http google_v6_remote \
    google_v6_dns google_v6_connect google_v6_tls google_v6_total \
    <"$sample_work/google-v6.result"
  IFS='|' read -r cloudflare_v4_exit cloudflare_v4_http _ \
    <"$sample_work/cloudflare-v4.result"
  IFS='|' read -r cloudflare_v6_exit cloudflare_v6_http _ \
    <"$sample_work/cloudflare-v6.result"
  IFS='|' read -r dns_udp_exit dns_udp_answers \
    <"$sample_work/dns-udp.result"
  IFS='|' read -r dns_tcp_exit dns_tcp_answers \
    <"$sample_work/dns-tcp.result"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sample_number" "$utc" \
    "$(field_or_dash "$app_pid")" "$(field_or_dash "$app_rss")" \
    "$(field_or_dash "$app_fds")" "$(field_or_dash "$tun_pid")" \
    "$(field_or_dash "$tun_rss")" "$(field_or_dash "$tun_fds")" \
    "$(field_or_dash "$vpn_status")" "$(field_or_dash "$stub_interface")" \
    "$(field_or_dash "$default_interface")" \
    "$google_v4_exit" "$(field_or_dash "$google_v4_http")" \
    "$(field_or_dash "$google_v4_remote")" \
    "$(field_or_dash "$google_v4_dns")" \
    "$(field_or_dash "$google_v4_connect")" \
    "$(field_or_dash "$google_v4_tls")" \
    "$(field_or_dash "$google_v4_total")" \
    "$google_v6_exit" "$(field_or_dash "$google_v6_http")" \
    "$(field_or_dash "$google_v6_remote")" \
    "$(field_or_dash "$google_v6_dns")" \
    "$(field_or_dash "$google_v6_connect")" \
    "$(field_or_dash "$google_v6_tls")" \
    "$(field_or_dash "$google_v6_total")" \
    "$cloudflare_v4_exit" "$(field_or_dash "$cloudflare_v4_http")" \
    "$cloudflare_v6_exit" "$(field_or_dash "$cloudflare_v6_http")" \
    "$dns_udp_exit" "$dns_udp_answers" "$dns_tcp_exit" "$dns_tcp_answers" \
    "$(sha256_or_dash "$PROFILE_CATALOG")" \
    "$(sha256_or_dash "$ACTIVE_PROFILE")" \
    "$(sha256_or_dash "$SELECTION_STORE")" \
    >>"$OUTPUT/samples.tsv"

  failed=0
  for status in "$google_v4_exit" "$google_v6_exit" \
    "$cloudflare_v4_exit" "$cloudflare_v6_exit" "$dns_udp_exit" "$dns_tcp_exit"; do
    if [ "$status" -ne 0 ]; then
      failed=1
    fi
  done
  for code in "$google_v4_http" "$google_v6_http" \
    "$cloudflare_v4_http" "$cloudflare_v6_http"; do
    if [ "$code" != 204 ]; then
      failed=1
    fi
  done
  if [ "$vpn_status" != Connected ] || [ -z "$app_pid" ] \
    || [ -z "$tun_pid" ] || [ -z "$stub_interface" ]; then
    failed=1
  fi
  if [ "$failed" -eq 1 ]; then
    failure_samples=$((failure_samples + 1))
    if [ "$previous_sample_failed" -eq 0 ]; then
      failure_windows=$((failure_windows + 1))
      capture_failure_window "$sample_number"
    fi
    previous_sample_failed=1
  else
    previous_sample_failed=0
  fi

  find "$sample_work" -depth -delete
  sleep "$INTERVAL_SECONDS"
done

kill "$LOG_STREAM_PID" 2>/dev/null || true
wait "$LOG_STREAM_PID" 2>/dev/null || true
LOG_STREAM_PID=
END_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
{
  printf 'schema=1\n'
  printf 'status=%s\n' "$(test "$failure_samples" -eq 0 && echo completed || echo failed)"
  printf 'samples=%s\n' "$sample_number"
  printf 'failure_samples=%s\n' "$failure_samples"
  printf 'failure_windows=%s\n' "$failure_windows"
  printf 'started_utc=%s\n' "$START_UTC"
  printf 'ended_utc=%s\n' "$END_UTC"
} >"$OUTPUT/result.txt"

(
  cd "$OUTPUT"
  find . -type f ! -name SHA256SUMS -print \
    | LC_ALL=C sort \
    | while IFS= read -r path; do
        shasum -a 256 "$path"
      done >SHA256SUMS
)

if [ "$failure_samples" -ne 0 ]; then
  echo "network diagnostic captured $failure_samples failure samples at $OUTPUT" >&2
  exit 2
fi
echo "network diagnostic completed without a captured failure: $OUTPUT"
