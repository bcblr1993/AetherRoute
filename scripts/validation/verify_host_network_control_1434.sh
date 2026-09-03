#!/bin/sh
set -eu
umask 077

EVIDENCE=${1:-}
EXPECTED_RUNNER_SHA256=${2:-}
MINIMUM_DURATION_SECONDS=${3:-50400}
MAXIMUM_INTERVAL_SECONDS=${4:-30}

usage() {
  echo "usage: $0 /absolute/evidence runner-sha256 [minimum-duration-seconds] [maximum-interval-seconds]" >&2
}

case "$EVIDENCE" in /*) ;; *) usage; exit 64 ;; esac
printf '%s\n' "$EXPECTED_RUNNER_SHA256" \
  | grep -Eq '^[0-9a-f]{64}$' || { usage; exit 64; }
printf '%s\n' "$MINIMUM_DURATION_SECONDS:$MAXIMUM_INTERVAL_SECONDS" \
  | grep -Eq '^[1-9][0-9]*:[1-9][0-9]*$' || { usage; exit 64; }
test -d "$EVIDENCE" || { echo 'evidence directory is missing' >&2; exit 66; }

METADATA="$EVIDENCE/metadata.txt"
RESULT="$EVIDENCE/result.txt"
SAMPLES="$EVIDENCE/samples.tsv"
RUNNER="$EVIDENCE/runner.sh"
SUMS="$EVIDENCE/SHA256SUMS"
for path in "$METADATA" "$RESULT" "$SAMPLES" "$RUNNER" "$SUMS" \
  "$EVIDENCE/system-proxy-at-start.txt" \
  "$EVIDENCE/default-route-at-start.txt" "$EVIDENCE/dns-at-start.txt"; do
  test -f "$path" && test ! -L "$path" || {
    echo "required regular evidence file is missing: $path" >&2
    exit 1
  }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-host-control-verifier.XXXXXX")
cleanup() { find "$WORK" -depth -delete 2>/dev/null || true; }
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

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

while IFS= read -r sum_line; do
  printf '%s\n' "$sum_line" | grep -Eq '^[0-9a-f]{64}  \./[^/].*$' || {
    echo 'invalid SHA256SUMS line' >&2
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
      echo "invalid summed file: $relative_path" >&2
      exit 1
    }
done <"$SUMS"
(
  cd "$EVIDENCE"
  find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort \
    >"$WORK/actual.txt"
  awk '{sub(/^[0-9a-f]{64}  /, ""); print}' SHA256SUMS | LC_ALL=C sort \
    >"$WORK/summed.txt"
  cmp -s "$WORK/actual.txt" "$WORK/summed.txt" || {
    echo 'SHA256SUMS does not bind the exact evidence file set' >&2
    exit 1
  }
  shasum -a 256 -c SHA256SUMS >/dev/null
)

test "$(field schema "$METADATA")" = 1
test "$(field purpose "$METADATA")" = host-concurrent-target-availability-control
test "$(field runner_sha256 "$METADATA")" = "$EXPECTED_RUNNER_SHA256"
test "$(sha256 "$RUNNER")" = "$EXPECTED_RUNNER_SHA256"
test "$(field network_state_mutation "$METADATA")" = none
test "$(field curl_proxy_environment "$METADATA")" = preserved
DURATION_SECONDS=$(field duration_seconds "$METADATA")
INTERVAL_SECONDS=$(field interval_seconds "$METADATA")
printf '%s\n' "$DURATION_SECONDS:$INTERVAL_SECONDS" \
  | grep -Eq '^[1-9][0-9]*:[1-9][0-9]*$' || {
    echo 'invalid duration or interval' >&2
    exit 1
  }
test "$DURATION_SECONDS" -ge "$MINIMUM_DURATION_SECONDS"
test "$INTERVAL_SECONDS" -le "$MAXIMUM_INTERVAL_SECONDS"

test "$(field schema "$RESULT")" = 1
test "$(field status "$RESULT")" = completed
test "$(field started_utc "$RESULT")" = "$(field started_utc "$METADATA")"
for timestamp in "$(field started_utc "$RESULT")" "$(field ended_utc "$RESULT")"; do
  printf '%s\n' "$timestamp" \
    | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || {
      echo "invalid timestamp: $timestamp" >&2
      exit 1
    }
done
SAMPLE_COUNT=$(field samples "$RESULT")
FAILURE_SAMPLES=$(field failure_samples "$RESULT")
printf '%s\n' "$SAMPLE_COUNT:$FAILURE_SAMPLES" \
  | grep -Eq '^[1-9][0-9]*:[0-9]+$' || {
    echo 'invalid sample counts' >&2
    exit 1
  }
test "$FAILURE_SAMPLES" -le "$SAMPLE_COUNT"

EXPECTED_HEADER='sample	utc	default_interface	google_v4_exit	google_v4_http	google_v4_remote	google_v4_dns_s	google_v4_connect_s	google_v4_tls_s	google_v4_total_s	google_v6_exit	google_v6_http	google_v6_remote	google_v6_dns_s	google_v6_connect_s	google_v6_tls_s	google_v6_total_s	cloudflare_v4_exit	cloudflare_v4_http	cloudflare_v6_exit	cloudflare_v6_http	dns_udp_exit	dns_udp_answers	dns_tcp_exit	dns_tcp_answers'
test "$(sed -n '1p' "$SAMPLES")" = "$(printf '%b' "$EXPECTED_HEADER")" || {
  echo 'unexpected samples.tsv schema' >&2
  exit 1
}
test "$(($(wc -l <"$SAMPLES") - 1))" -eq "$SAMPLE_COUNT"

COMPUTED_FAILURES=$(awk -F '\t' '
  NR == 1 { next }
  NF != 25 { print "invalid-field-count:" NR > "/dev/stderr"; exit 2 }
  $1 != NR - 1 { print "invalid-sequence:" NR > "/dev/stderr"; exit 2 }
  $2 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ {
    print "invalid-timestamp:" NR > "/dev/stderr"; exit 2
  }
  $3 == "" { print "missing-interface:" NR > "/dev/stderr"; exit 2 }
  $4 !~ /^[0-9]+$/ || $11 !~ /^[0-9]+$/ \
    || $18 !~ /^[0-9]+$/ || $20 !~ /^[0-9]+$/ \
    || $22 !~ /^[0-9]+$/ || $24 !~ /^[0-9]+$/ {
    print "invalid-exit-field:" NR > "/dev/stderr"; exit 2
  }
  $5 !~ /^[0-9]{3}$/ || $12 !~ /^[0-9]{3}$/ \
    || $19 !~ /^[0-9]{3}$/ || $21 !~ /^[0-9]{3}$/ {
    print "invalid-http-field:" NR > "/dev/stderr"; exit 2
  }
  $23 !~ /^[0-9]+$/ || $25 !~ /^[0-9]+$/ {
    print "invalid-dns-field:" NR > "/dev/stderr"; exit 2
  }
  {
    failed = ($4 != 0 || $5 != 204 || $11 != 0 || $12 != 204 \
      || $18 != 0 || $19 != 204 || $20 != 0 || $21 != 204 \
      || $22 != 0 || $23 < 1 || $24 != 0 || $25 < 1)
    if (failed) failures++
  }
  END { print failures + 0 }
' "$SAMPLES") || {
  echo 'samples.tsv invariant verification failed' >&2
  exit 1
}
test "$COMPUTED_FAILURES" -eq "$FAILURE_SAMPLES" || {
  echo 'result failure count does not match samples.tsv' >&2
  exit 1
}

printf 'host_control_evidence=verified\n'
printf 'samples=%s\n' "$SAMPLE_COUNT"
printf 'failure_samples=%s\n' "$FAILURE_SAMPLES"
