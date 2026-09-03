#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CORRELATOR="$SCRIPT_DIR/correlate_vm_host_network_1434.rb"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-correlation-test.XXXXXX")
cleanup() { find "$WORK" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

host_header='sample\tutc\tdefault_interface\tgoogle_v4_exit\tgoogle_v4_http\tgoogle_v4_remote\tgoogle_v4_dns_s\tgoogle_v4_connect_s\tgoogle_v4_tls_s\tgoogle_v4_total_s\tgoogle_v6_exit\tgoogle_v6_http\tgoogle_v6_remote\tgoogle_v6_dns_s\tgoogle_v6_connect_s\tgoogle_v6_tls_s\tgoogle_v6_total_s\tcloudflare_v4_exit\tcloudflare_v4_http\tcloudflare_v6_exit\tcloudflare_v6_http\tdns_udp_exit\tdns_udp_answers\tdns_tcp_exit\tdns_tcp_answers'
printf '%s\n' "$host_header" | awk '{gsub(/\\t/, "\t"); print}' >"$WORK/host.tsv"
printf '%s\n' '1\t2026-08-25T03:00:20Z\ten11\t0\t204\t127.0.0.1\t0\t0\t0\t1\t0\t204\t::1\t0\t0\t0\t1\t0\t204\t0\t204\t0\t1\t0\t1' | awk '{gsub(/\\t/, "\t"); print}' >>"$WORK/host.tsv"
printf '%s\n' '2\t2026-08-25T03:01:00Z\ten11\t28\t000\t127.0.0.1\t0\t0\t0\t3\t0\t204\t::1\t0\t0\t0\t1\t0\t204\t0\t204\t0\t1\t0\t1' | awk '{gsub(/\\t/, "\t"); print}' >>"$WORK/host.tsv"

legacy_header='sample\tutc\tapp_pid\tapp_rss_kb\tapp_fds\tapp_cpu_pct\ttun_pid\ttun_rss_kb\ttun_fds\ttun_cpu_pct\tvpn_status\tstub_interface\thost_interface\tfixture_a\tfixture_b\tipv4_https\tipv4_attempt_pattern\tipv4_successes\tipv4_transaction_failures\tipv6_https\tipv6_attempt_pattern\tipv6_successes\tipv6_transaction_failures\tdns_udp\tdns_tcp\tstun_udp\tstun_attempt_pattern\tstun_successes\tstun_datagram_failures\tstun_min_response_bytes\tstun_max_latency_ms\trobots_https\trobots_attempt_pattern\trobots_successes\trobots_transaction_failures\trunning_tun_sha256'
printf '%s\n' "$legacy_header" | awk '{gsub(/\\t/, "\t"); print}' >"$WORK/legacy-vm.tsv"
printf '%s\n' '1\t2026-08-25T03:00:55Z\t10\t100\t20\t0\t11\t101\t-\t0\tConnected\tutun4\ten0\tpassed\tpassed\tfailed\tFFF\t0\t3\tpassed\tPPP\t3\t0\tpassed\tpassed\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-' | awk '{gsub(/\\t/, "\t"); print}' >>"$WORK/legacy-vm.tsv"
if ! "$CORRELATOR" "$WORK/legacy-vm.tsv" "$WORK/host.tsv" \
  >"$WORK/legacy-result.tsv" 2>"$WORK/legacy-summary.txt"; then
  cat "$WORK/legacy-summary.txt" >&2
  exit 1
fi
awk -F '\t' 'NR == 2 { exit !($1 == 1 && $3 == "legacy-v1" && $19 == 2 && $21 == 5 && $22 == "in-window" && $23 == "failed" && $26 == "shared-target-failure") }' "$WORK/legacy-result.tsv"
grep -Fx 'vm_failure_rows=1' "$WORK/legacy-summary.txt" >/dev/null
grep -Fx 'shared_target_failure=1' "$WORK/legacy-summary.txt" >/dev/null

raw_header='sample\tutc\tapp_pid\tapp_rss_kb\tapp_fds\ttun_pid\ttun_rss_kb\ttun_fds\tvpn_status\tstub_interface\tdefault_interface\tgoogle_v4_exit\tgoogle_v4_http\tgoogle_v4_remote\tgoogle_v4_dns_s\tgoogle_v4_connect_s\tgoogle_v4_tls_s\tgoogle_v4_total_s\tgoogle_v6_exit\tgoogle_v6_http\tgoogle_v6_remote\tgoogle_v6_dns_s\tgoogle_v6_connect_s\tgoogle_v6_tls_s\tgoogle_v6_total_s\tcloudflare_v4_exit\tcloudflare_v4_http\tcloudflare_v6_exit\tcloudflare_v6_http\tdns_udp_exit\tdns_udp_answers\tdns_tcp_exit\tdns_tcp_answers\tprofile_catalog_sha256\tactive_profile_sha256\tselection_store_sha256'
printf '%s\n' "$raw_header" | awk '{gsub(/\\t/, "\t"); print}' >"$WORK/raw-vm.tsv"
printf '%s\n' '1\t2026-08-25T03:00:55Z\t10\t100\t20\t11\t101\t0\tConnected\tutun4\tutun4\t28\t000\t198.18.0.1\t0\t0\t0\t3\t0\t204\t::ffff:198.18.0.1\t0\t0\t0\t1\t0\t204\t0\t204\t0\t1\t0\t1\ta\tb\tc' | awk '{gsub(/\\t/, "\t"); print}' >>"$WORK/raw-vm.tsv"
if ! "$CORRELATOR" "$WORK/raw-vm.tsv" "$WORK/host.tsv" \
  >"$WORK/raw-result.tsv" 2>"$WORK/raw-summary.txt"; then
  cat "$WORK/raw-summary.txt" >&2
  exit 1
fi
awk -F '\t' 'NR == 2 { exit !($1 == 1 && $3 == "raw-v1" && $4 == "google-v4" && $19 == 2 && $21 == 5 && $22 == "in-window" && $23 == "failed" && $24 == "google-v4" && $25 == "google-v4" && $26 == "shared-target-failure") }' "$WORK/raw-result.tsv"
grep -Fx 'vm_schema=raw-v1' "$WORK/raw-summary.txt" >/dev/null
grep -Fx 'shared_target_failure=1' "$WORK/raw-summary.txt" >/dev/null

printf 'broken\n' >>"$WORK/raw-vm.tsv"
if "$CORRELATOR" "$WORK/raw-vm.tsv" "$WORK/host.tsv" >/dev/null 2>&1; then
  echo 'correlator accepted malformed VM evidence' >&2
  exit 1
fi
echo 'VM/host network correlator self-test passed for legacy and raw schema'
