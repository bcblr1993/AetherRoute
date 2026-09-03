#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -x "$SCRIPT_DIR/verify_network_failure_diagnostic_1434.sh" ]; then
  VERIFIER="$SCRIPT_DIR/verify_network_failure_diagnostic_1434.sh"
else
  ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
  VERIFIER="$ROOT/scripts/validation/verify_network_failure_diagnostic_1434.sh"
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-network-verifier-test.XXXXXX")

cleanup() {
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

seal() {
  evidence=$1
  (
    cd "$evidence"
    find . -type f ! -name SHA256SUMS -print \
      | LC_ALL=C sort \
      | while IFS= read -r path; do
          shasum -a 256 "$path"
        done >SHA256SUMS
  )
}

write_common() {
  evidence=$1
  failure_samples=$2
  failure_windows=$3
  status=$4
  mkdir -m 700 "$evidence"
  printf 'test runner\n' >"$evidence/runner.sh"
  runner_sha=$(sha256 "$evidence/runner.sh")
  {
    printf 'schema=1\n'
    printf 'build=2026081434\n'
    printf 'installed_tun_sha256=%s\n' \
      aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    printf 'runner_sha256=%s\n' "$runner_sha"
    printf 'started_utc=2026-08-25T00:00:00Z\n'
    printf 'duration_seconds=10\n'
    printf 'interval_seconds=5\n'
    printf 'network_state_mutation=none\n'
  } >"$evidence/metadata.txt"
  {
    printf 'schema=1\n'
    printf 'status=%s\n' "$status"
    printf 'samples=1\n'
    printf 'failure_samples=%s\n' "$failure_samples"
    printf 'failure_windows=%s\n' "$failure_windows"
    printf 'started_utc=2026-08-25T00:00:00Z\n'
    printf 'ended_utc=2026-08-25T00:00:10Z\n'
  } >"$evidence/result.txt"
  printf 'aether_flow stage=tcp_route_selected value=1\n' \
    >"$evidence/safe-stage-stream.txt"
  printf '%s\n' 'sample	utc	app_pid	app_rss_kb	app_fds	tun_pid	tun_rss_kb	tun_fds	vpn_status	stub_interface	default_interface	google_v4_exit	google_v4_http	google_v4_remote	google_v4_dns_s	google_v4_connect_s	google_v4_tls_s	google_v4_total_s	google_v6_exit	google_v6_http	google_v6_remote	google_v6_dns_s	google_v6_connect_s	google_v6_tls_s	google_v6_total_s	cloudflare_v4_exit	cloudflare_v4_http	cloudflare_v6_exit	cloudflare_v6_http	dns_udp_exit	dns_udp_answers	dns_tcp_exit	dns_tcp_answers	profile_catalog_sha256	active_profile_sha256	selection_store_sha256' \
    | awk '{gsub(/\\t/, "\t"); print}' >"$evidence/samples.tsv"
}

EXTERNAL="$WORK/external-target-failure"
write_common "$EXTERNAL" 1 1 failed
printf '%s\n' '1	2026-08-25T00:00:00Z	10	100	20	11	101	21	Connected	utun4	en0	28	000	-	0.001	0.000	0.000	8.000	0	204	2001:db8::1	0.001	0.010	0.020	0.030	0	204	0	204	0	1	0	1	aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa	bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb	cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
  | awk '{gsub(/\\t/, "\t"); print}' >>"$EXTERNAL/samples.tsv"
FAILURE_DIR="$EXTERNAL/failure-1"
mkdir -m 700 "$FAILURE_DIR"
for name in captured-utc.txt processes.txt vpn-status.txt scutil-dns.txt \
  route-default.txt route-google-v4.txt route-google-v6.txt \
  route-fake-ip.txt netstat-inet.txt netstat-inet6.txt ifconfig.txt \
  safe-stage-log.txt burst-1-google-v4.result \
  burst-1-google-v6.result burst-1-cloudflare-v4.result \
  burst-1-cloudflare-v6.result burst-1-dns-udp.result \
  burst-1-dns-tcp.result burst-12-google-v4.result \
  burst-12-google-v6.result burst-12-cloudflare-v4.result \
  burst-12-cloudflare-v6.result burst-12-dns-udp.result \
  burst-12-dns-tcp.result; do
  printf 'fixture\n' >"$FAILURE_DIR/$name"
done
seal "$EXTERNAL"
RUNNER_SHA=$(sha256 "$EXTERNAL/runner.sh")
OUTPUT=$(
  "$VERIFIER" "$EXTERNAL" "$RUNNER_SHA" 2026081434 \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 10 5
)
printf '%s\n' "$OUTPUT" | grep -Fx 'network_status=failed' >/dev/null
printf '%s\n' "$OUTPUT" | grep -Fx 'core_failure_stage=not-observed' >/dev/null

CORE="$WORK/core-failure"
cp -R "$EXTERNAL" "$CORE"
printf 'aether_flow stage=tcp_outbound_connect_failed value=60\n' \
  >>"$CORE/failure-1/safe-stage-log.txt"
seal "$CORE"
OUTPUT=$(
  "$VERIFIER" "$CORE" "$RUNNER_SHA" 2026081434 \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 10 5
)
printf '%s\n' "$OUTPUT" | grep -Fx 'core_failure_stage=observed' >/dev/null

printf 'tampered\n' >>"$CORE/samples.tsv"
if "$VERIFIER" "$CORE" "$RUNNER_SHA" 2026081434 \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  10 5 >/dev/null 2>&1; then
  echo 'verifier accepted tampered evidence' >&2
  exit 1
fi

echo 'network diagnostic verifier self-test passed'
