#!/bin/sh
set -eu
umask 077

EVIDENCE=${1:-}
EXPECTED_RUNNER_SHA256=${2:-}
EXPECTED_BUILD=${3:-2026081434}
EXPECTED_TUN_SHA256=${4:-}
MINIMUM_DURATION_SECONDS=${5:-14400}
MAXIMUM_INTERVAL_SECONDS=${6:-5}

usage() {
  echo "usage: $0 /absolute/evidence runner-sha256 build tun-sha256 [minimum-duration-seconds] [maximum-interval-seconds]" >&2
}

case "$EVIDENCE" in
  /*) ;;
  *) usage; exit 64 ;;
esac
for digest in "$EXPECTED_RUNNER_SHA256" "$EXPECTED_TUN_SHA256"; do
  printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$' || {
    usage
    exit 64
  }
done
printf '%s\n' \
  "$EXPECTED_BUILD:$MINIMUM_DURATION_SECONDS:$MAXIMUM_INTERVAL_SECONDS" \
  | grep -Eq '^[1-9][0-9]*:[1-9][0-9]*:[1-9][0-9]*$' || {
    usage
    exit 64
  }
test -d "$EVIDENCE" || {
  echo "evidence directory is missing: $EVIDENCE" >&2
  exit 66
}

METADATA="$EVIDENCE/metadata.txt"
RESULT="$EVIDENCE/result.txt"
SAMPLES="$EVIDENCE/samples.tsv"
RUNNER="$EVIDENCE/runner.sh"
SAFE_STREAM="$EVIDENCE/safe-stage-stream.txt"
SUMS="$EVIDENCE/SHA256SUMS"
for path in "$METADATA" "$RESULT" "$SAMPLES" "$RUNNER" \
  "$SAFE_STREAM" "$SUMS"; do
  test -f "$path" && test ! -L "$path" || {
    echo "required regular evidence file is missing: $path" >&2
    exit 1
  }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-network-verifier.XXXXXX")
cleanup() {
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

field() {
  key=$1
  file=$2
  count=$(grep -Ec "^${key}=" "$file" || true)
  test "$count" -eq 1 || {
    echo "expected one $key field in $file, found $count" >&2
    exit 1
  }
  sed -n "s/^${key}=//p" "$file"
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

while IFS= read -r sum_line; do
  printf '%s\n' "$sum_line" \
    | grep -Eq '^[0-9a-f]{64}  \./[^/].*$' || {
      echo "invalid SHA256SUMS line" >&2
      exit 1
    }
  relative_path=${sum_line#*  ./}
  case "$relative_path" in
    /*|../*|*/../*|*/..|SHA256SUMS)
      echo "unsafe SHA256SUMS path: $relative_path" >&2
      exit 1
      ;;
  esac
  test -f "$EVIDENCE/$relative_path" \
    && test ! -L "$EVIDENCE/$relative_path" || {
      echo "SHA256SUMS path is not a regular file: $relative_path" >&2
      exit 1
    }
done <"$SUMS"

(
  cd "$EVIDENCE"
  find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort \
    >"$WORK/actual-files.txt"
  awk '{sub(/^[0-9a-f]{64}  /, ""); print}' SHA256SUMS \
    | LC_ALL=C sort >"$WORK/summed-files.txt"
  cmp -s "$WORK/actual-files.txt" "$WORK/summed-files.txt" || {
    echo "SHA256SUMS does not bind the exact evidence file set" >&2
    exit 1
  }
  shasum -a 256 -c SHA256SUMS >/dev/null
)

test "$(field schema "$METADATA")" = 1
test "$(field build "$METADATA")" = "$EXPECTED_BUILD"
test "$(field installed_tun_sha256 "$METADATA")" = "$EXPECTED_TUN_SHA256"
test "$(field runner_sha256 "$METADATA")" = "$EXPECTED_RUNNER_SHA256"
test "$(sha256 "$RUNNER")" = "$EXPECTED_RUNNER_SHA256"
test "$(field network_state_mutation "$METADATA")" = none

DURATION_SECONDS=$(field duration_seconds "$METADATA")
INTERVAL_SECONDS=$(field interval_seconds "$METADATA")
printf '%s\n' "$DURATION_SECONDS:$INTERVAL_SECONDS" \
  | grep -Eq '^[1-9][0-9]*:[1-9][0-9]*$' || {
    echo "invalid duration or interval" >&2
    exit 1
  }
test "$DURATION_SECONDS" -ge "$MINIMUM_DURATION_SECONDS" || {
  echo "diagnostic duration is below the required minimum" >&2
  exit 1
}
test "$INTERVAL_SECONDS" -le "$MAXIMUM_INTERVAL_SECONDS" || {
  echo "diagnostic interval is above the allowed maximum" >&2
  exit 1
}

STARTED_UTC=$(field started_utc "$METADATA")
RESULT_STARTED_UTC=$(field started_utc "$RESULT")
ENDED_UTC=$(field ended_utc "$RESULT")
test "$RESULT_STARTED_UTC" = "$STARTED_UTC"
for timestamp in "$STARTED_UTC" "$ENDED_UTC"; do
  printf '%s\n' "$timestamp" \
    | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || {
      echo "invalid result timestamp: $timestamp" >&2
      exit 1
    }
done

test "$(field schema "$RESULT")" = 1
STATUS=$(field status "$RESULT")
case "$STATUS" in
  completed|failed) ;;
  *) echo "invalid diagnostic status: $STATUS" >&2; exit 1 ;;
esac
SAMPLE_COUNT=$(field samples "$RESULT")
FAILURE_SAMPLES=$(field failure_samples "$RESULT")
FAILURE_WINDOWS=$(field failure_windows "$RESULT")
printf '%s\n' "$SAMPLE_COUNT:$FAILURE_SAMPLES:$FAILURE_WINDOWS" \
  | grep -Eq '^[1-9][0-9]*:[0-9]+:[0-9]+$' || {
    echo "invalid result counts" >&2
    exit 1
  }
test "$FAILURE_SAMPLES" -le "$SAMPLE_COUNT"
test "$FAILURE_WINDOWS" -le "$FAILURE_SAMPLES"
if [ "$FAILURE_SAMPLES" -eq 0 ]; then
  test "$STATUS" = completed
  test "$FAILURE_WINDOWS" -eq 0
else
  test "$STATUS" = failed
  test "$FAILURE_WINDOWS" -ge 1
fi

EXPECTED_HEADER='sample	utc	app_pid	app_rss_kb	app_fds	tun_pid	tun_rss_kb	tun_fds	vpn_status	stub_interface	default_interface	google_v4_exit	google_v4_http	google_v4_remote	google_v4_dns_s	google_v4_connect_s	google_v4_tls_s	google_v4_total_s	google_v6_exit	google_v6_http	google_v6_remote	google_v6_dns_s	google_v6_connect_s	google_v6_tls_s	google_v6_total_s	cloudflare_v4_exit	cloudflare_v4_http	cloudflare_v6_exit	cloudflare_v6_http	dns_udp_exit	dns_udp_answers	dns_tcp_exit	dns_tcp_answers	profile_catalog_sha256	active_profile_sha256	selection_store_sha256'
test "$(sed -n '1p' "$SAMPLES")" = "$(printf '%b' "$EXPECTED_HEADER")" || {
  echo "unexpected samples.tsv schema" >&2
  exit 1
}
test "$(($(wc -l <"$SAMPLES") - 1))" -eq "$SAMPLE_COUNT"

COMPUTED_FAILURES=$(awk -F '\t' '
  NR == 1 { next }
  NF != 36 { print "invalid-field-count:" NR > "/dev/stderr"; exit 2 }
  $1 != NR - 1 { print "invalid-sequence:" NR > "/dev/stderr"; exit 2 }
  $2 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ {
    print "invalid-timestamp:" NR > "/dev/stderr"; exit 2
  }
  $3 !~ /^([0-9]+|-)$/ || $4 !~ /^([0-9]+|-)$/ \
    || $5 !~ /^([0-9]+|-)$/ || $6 !~ /^([0-9]+|-)$/ \
    || $7 !~ /^([0-9]+|-)$/ || $8 !~ /^([0-9]+|-)$/ {
    print "invalid-process-field:" NR > "/dev/stderr"; exit 2
  }
  $12 !~ /^[0-9]+$/ || $19 !~ /^[0-9]+$/ \
    || $26 !~ /^[0-9]+$/ || $28 !~ /^[0-9]+$/ \
    || $30 !~ /^[0-9]+$/ || $32 !~ /^[0-9]+$/ {
    print "invalid-exit-field:" NR > "/dev/stderr"; exit 2
  }
  $13 !~ /^[0-9]{3}$/ || $20 !~ /^[0-9]{3}$/ \
    || $27 !~ /^[0-9]{3}$/ || $29 !~ /^[0-9]{3}$/ {
    print "invalid-http-field:" NR > "/dev/stderr"; exit 2
  }
  $31 !~ /^[0-9]+$/ || $33 !~ /^[0-9]+$/ {
    print "invalid-dns-field:" NR > "/dev/stderr"; exit 2
  }
  $34 !~ /^([0-9a-f]{64}|-)$/ || $35 !~ /^([0-9a-f]{64}|-)$/ \
    || $36 !~ /^([0-9a-f]{64}|-)$/ {
    print "invalid-store-hash:" NR > "/dev/stderr"; exit 2
  }
  {
    failed = ($3 == "-" || $6 == "-" || $9 != "Connected" \
      || $10 !~ /^utun[0-9]+$/ \
      || $12 != 0 || $13 != 204 || $19 != 0 || $20 != 204 \
      || $26 != 0 || $27 != 204 || $28 != 0 || $29 != 204 \
      || $30 != 0 || $31 < 1 || $32 != 0 || $33 < 1)
    if (failed) failures++
  }
  END { print failures + 0 }
' "$SAMPLES") || {
  echo "samples.tsv invariant verification failed" >&2
  exit 1
}
test "$COMPUTED_FAILURES" -eq "$FAILURE_SAMPLES" || {
  echo "result failure count does not match samples.tsv" >&2
  exit 1
}

ACTUAL_FAILURE_WINDOWS=$(find "$EVIDENCE" -mindepth 1 -maxdepth 1 \
  -type d -name 'failure-*' -print | wc -l | awk '{$1=$1; print}')
test "$ACTUAL_FAILURE_WINDOWS" -eq "$FAILURE_WINDOWS" || {
  echo "failure window directory count mismatch" >&2
  exit 1
}
for failure_dir in "$EVIDENCE"/failure-*; do
  if [ "$FAILURE_WINDOWS" -eq 0 ]; then
    break
  fi
  test -d "$failure_dir" && test ! -L "$failure_dir"
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
    test -f "$failure_dir/$name" && test ! -L "$failure_dir/$name" || {
      echo "incomplete failure window: $failure_dir/$name" >&2
      exit 1
    }
  done
done

grep -F 'aether_flow stage=' "$SAFE_STREAM" >/dev/null || {
  echo "1434 diagnostic stream contains no core flow stages" >&2
  exit 1
}
CORE_FAILURE_STAGE=not-observed
if [ "$FAILURE_SAMPLES" -gt 0 ] \
  && grep -Eh 'aether_flow stage=.*(_failed|_error|_empty|_missing|_too_large|_exhausted|_rejected|_timeout|_timed_out)' \
    "$SAFE_STREAM" "$EVIDENCE"/failure-*/safe-stage-log.txt >/dev/null; then
  CORE_FAILURE_STAGE=observed
fi

printf 'diagnostic_evidence=verified\n'
printf 'network_status=%s\n' "$STATUS"
printf 'samples=%s\n' "$SAMPLE_COUNT"
printf 'failure_samples=%s\n' "$FAILURE_SAMPLES"
printf 'failure_windows=%s\n' "$FAILURE_WINDOWS"
printf 'core_failure_stage=%s\n' "$CORE_FAILURE_STAGE"
