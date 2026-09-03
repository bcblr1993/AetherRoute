#!/bin/sh
set -eu
umask 077

OUTPUT=${1:-}
DURATION_SECONDS=${2:-50400}
INTERVAL_SECONDS=${3:-30}

usage() {
  echo "usage: $0 /absolute/new-evidence-directory [duration-seconds] [interval-seconds]" >&2
}

case "$OUTPUT" in
  /*) ;;
  *) usage; exit 64 ;;
esac
printf '%s\n' "$DURATION_SECONDS:$INTERVAL_SECONDS" \
  | grep -Eq '^[1-9][0-9]*:[1-9][0-9]*$' || {
    usage
    exit 64
  }
test "$INTERVAL_SECONDS" -le 60 || {
  echo 'interval must be at most 60 seconds' >&2
  exit 64
}
test ! -e "$OUTPUT" || {
  echo "refusing to overwrite evidence: $OUTPUT" >&2
  exit 1
}
test -d "$(dirname -- "$OUTPUT")" || {
  echo 'evidence parent is missing' >&2
  exit 66
}

mkdir -m 700 -- "$OUTPUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-host-network-control.XXXXXX")
cleanup() {
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

field_or_dash() {
  if [ -n "$1" ]; then printf '%s' "$1"; else printf '%s' '-'; fi
}

probe_https() {
  family=$1
  url=$2
  destination=$3
  set +e
  value=$(curl "$family" --silent --show-error --output /dev/null \
    --connect-timeout 3 --max-time 8 \
    --write-out '%{http_code}|%{remote_ip}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_total}' \
    "$url" 2>"$destination.stderr")
  status=$?
  set -e
  printf '%s|%s\n' "$status" "$value" >"$destination.result"
}

probe_dns() {
  transport=$1
  destination=$2
  tcp_flag=
  test "$transport" != tcp || tcp_flag=+tcp
  set +e
  value=$(/usr/bin/dig $tcp_flag +time=2 +tries=1 www.google.com A \
    2>"$destination.stderr")
  status=$?
  set -e
  answers=$(printf '%s\n' "$value" \
    | awk '$4 == "A" {count++} END {print count+0}')
  printf '%s|%s\n' "$status" "$answers" >"$destination.result"
}

cp "$0" "$OUTPUT/runner.sh"
chmod 400 "$OUTPUT/runner.sh"
START_EPOCH=$(date +%s)
STARTED_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
END_EPOCH=$((START_EPOCH + DURATION_SECONDS))
{
  printf 'schema=1\n'
  printf 'purpose=host-concurrent-target-availability-control\n'
  printf 'started_utc=%s\n' "$STARTED_UTC"
  printf 'duration_seconds=%s\n' "$DURATION_SECONDS"
  printf 'interval_seconds=%s\n' "$INTERVAL_SECONDS"
  printf 'runner_sha256=%s\n' "$(sha256 "$OUTPUT/runner.sh")"
  printf 'network_state_mutation=none\n'
  printf 'curl_proxy_environment=preserved\n'
} >"$OUTPUT/metadata.txt"
scutil --proxy >"$OUTPUT/system-proxy-at-start.txt"
route -n get default >"$OUTPUT/default-route-at-start.txt" 2>&1 || true
scutil --dns >"$OUTPUT/dns-at-start.txt" 2>&1 || true

printf 'sample\tutc\tdefault_interface\tgoogle_v4_exit\tgoogle_v4_http\tgoogle_v4_remote\tgoogle_v4_dns_s\tgoogle_v4_connect_s\tgoogle_v4_tls_s\tgoogle_v4_total_s\tgoogle_v6_exit\tgoogle_v6_http\tgoogle_v6_remote\tgoogle_v6_dns_s\tgoogle_v6_connect_s\tgoogle_v6_tls_s\tgoogle_v6_total_s\tcloudflare_v4_exit\tcloudflare_v4_http\tcloudflare_v6_exit\tcloudflare_v6_http\tdns_udp_exit\tdns_udp_answers\tdns_tcp_exit\tdns_tcp_answers\n' \
  >"$OUTPUT/samples.tsv"

sample_number=0
failure_samples=0
while [ "$(date +%s)" -lt "$END_EPOCH" ]; do
  sample_number=$((sample_number + 1))
  sample_work="$WORK/sample-$sample_number"
  mkdir -- "$sample_work"

  probe_https -4 https://www.google.com/generate_204 "$sample_work/google-v4" &
  p1=$!
  probe_https -6 https://www.google.com/generate_204 "$sample_work/google-v6" &
  p2=$!
  probe_https -4 https://cp.cloudflare.com/generate_204 "$sample_work/cloudflare-v4" &
  p3=$!
  probe_https -6 https://cp.cloudflare.com/generate_204 "$sample_work/cloudflare-v6" &
  p4=$!
  probe_dns udp "$sample_work/dns-udp" &
  p5=$!
  probe_dns tcp "$sample_work/dns-tcp" &
  p6=$!
  wait "$p1"; wait "$p2"; wait "$p3"; wait "$p4"; wait "$p5"; wait "$p6"

  IFS='|' read -r g4e g4h g4r g4d g4c g4t g4a <"$sample_work/google-v4.result"
  IFS='|' read -r g6e g6h g6r g6d g6c g6t g6a <"$sample_work/google-v6.result"
  IFS='|' read -r c4e c4h _ <"$sample_work/cloudflare-v4.result"
  IFS='|' read -r c6e c6h _ <"$sample_work/cloudflare-v6.result"
  IFS='|' read -r due dua <"$sample_work/dns-udp.result"
  IFS='|' read -r dte dta <"$sample_work/dns-tcp.result"
  default_interface=$(route -n get default 2>/dev/null \
    | awk '$1 == "interface:" {print $2; exit}')

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sample_number" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$(field_or_dash "$default_interface")" \
    "$g4e" "$(field_or_dash "$g4h")" "$(field_or_dash "$g4r")" \
    "$(field_or_dash "$g4d")" "$(field_or_dash "$g4c")" \
    "$(field_or_dash "$g4t")" "$(field_or_dash "$g4a")" \
    "$g6e" "$(field_or_dash "$g6h")" "$(field_or_dash "$g6r")" \
    "$(field_or_dash "$g6d")" "$(field_or_dash "$g6c")" \
    "$(field_or_dash "$g6t")" "$(field_or_dash "$g6a")" \
    "$c4e" "$(field_or_dash "$c4h")" "$c6e" "$(field_or_dash "$c6h")" \
    "$due" "$dua" "$dte" "$dta" >>"$OUTPUT/samples.tsv"

  if [ "$g4e" -ne 0 ] || [ "$g4h" != 204 ] \
    || [ "$g6e" -ne 0 ] || [ "$g6h" != 204 ] \
    || [ "$c4e" -ne 0 ] || [ "$c4h" != 204 ] \
    || [ "$c6e" -ne 0 ] || [ "$c6h" != 204 ] \
    || [ "$due" -ne 0 ] || [ "$dua" -lt 1 ] \
    || [ "$dte" -ne 0 ] || [ "$dta" -lt 1 ]; then
    failure_samples=$((failure_samples + 1))
  fi
  find "$sample_work" -depth -delete
  sleep "$INTERVAL_SECONDS"
done

{
  printf 'schema=1\n'
  printf 'status=completed\n'
  printf 'samples=%s\n' "$sample_number"
  printf 'failure_samples=%s\n' "$failure_samples"
  printf 'started_utc=%s\n' "$STARTED_UTC"
  printf 'ended_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} >"$OUTPUT/result.txt"
(
  cd "$OUTPUT"
  find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort \
    | while IFS= read -r path; do shasum -a 256 "$path"; done \
    >SHA256SUMS
)
echo "host network control completed: $OUTPUT"
