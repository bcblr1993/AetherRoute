#!/bin/sh
set -eu

usage() {
  echo "usage: $0 evidence expected-build expected-app-cdhash expected-tun-cdhash expected-tun-sha256 pass|known-fail" >&2
  exit 64
}

test "$#" -eq 6 || usage
EVIDENCE=$1
EXPECTED_BUILD=$2
EXPECTED_APP_CDHASH=$3
EXPECTED_TUN_CDHASH=$4
EXPECTED_TUN_SHA256=$5
EXPECTED_STUN_POLICY=$6
case "$EVIDENCE" in /*) ;; *) usage;; esac
case "$EXPECTED_STUN_POLICY" in pass|known-fail) ;; *) usage;; esac

fail() { echo "connected checkpoint verification failed: $*" >&2; exit 1; }
test -d "$EVIDENCE" && test ! -L "$EVIDENCE" || fail "evidence directory invalid"
for name in capture.sh result.txt runtime.txt ipv4-https.txt ipv6-https.txt robots-https.txt \
  stun-1.txt stun-2.txt stun-3.txt SHA256SUMS; do
  test -f "$EVIDENCE/$name" && test ! -L "$EVIDENCE/$name" || fail "$name missing or symlinked"
done
(cd "$EVIDENCE" && shasum -a 256 -c SHA256SUMS >/dev/null) || fail "hash mismatch"
listed=$(awk '{print $2}' "$EVIDENCE/SHA256SUMS" | LC_ALL=C sort)
actual=$(cd "$EVIDENCE" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print \
  | sed 's#^./##' | LC_ALL=C sort)
test "$listed" = "$actual" || fail "file set mismatch"

field() {
  key=$1
  count=$(awk -F= -v k="$key" '$1==k{n++}END{print n+0}' "$EVIDENCE/result.txt")
  test "$count" -eq 1 || fail "$key must occur exactly once"
  awk -F= -v k="$key" '$1==k{print substr($0,index($0,"=")+1)}' "$EVIDENCE/result.txt"
}

test "$(field schema)" = 2 || fail "schema mismatch"
test "$(field expected_stun_policy)" = "$EXPECTED_STUN_POLICY" || fail "STUN policy mismatch"
test "$(field app_build)" = "$EXPECTED_BUILD" || fail "App build mismatch"
test "$(field app_cdhash)" = "$EXPECTED_APP_CDHASH" || fail "App CDHash mismatch"
test "$(field embedded_build)" = "$EXPECTED_BUILD" || fail "embedded build mismatch"
test "$(field embedded_cdhash)" = "$EXPECTED_TUN_CDHASH" || fail "embedded CDHash mismatch"
test "$(field embedded_sha256)" = "$EXPECTED_TUN_SHA256" || fail "embedded SHA256 mismatch"
test "$(field running_build)" = "$EXPECTED_BUILD" || fail "running build mismatch"
test "$(field running_cdhash)" = "$EXPECTED_TUN_CDHASH" || fail "running CDHash mismatch"
test "$(field running_sha256)" = "$EXPECTED_TUN_SHA256" || fail "running SHA256 mismatch"
test "$(field tun_pid_count)" = 1 || fail "TUN process count mismatch"
test "$(field transparent_pid_count)" = 0 || fail "transparent provider was running"
test "$(field connected_service_matches)" = 1 || fail "connected service count mismatch"
printf '%s\n' "$(field connected_service_uuid)" \
  | grep -Eq '^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$' || fail "service UUID invalid"
printf '%s\n' "$(field synthetic_stub_interface)" | grep -Eq '^utun[0-9]+$' \
  || fail "synthetic route not on TUN"
test "$(field fixture_host_interface)" = en0 || fail "host bypass route mismatch"
test "$(field system_proxy_sha256)" = 309309dd60b8263c4dbbcfc5194716c3cb542b1a64aca05ab55d659ffd46a218 \
  || fail "system proxy state changed"
for key in synthetic_address_present synthetic_resolver_present en0_dns_present; do
  test "$(field "$key")" = yes || fail "$key missing"
done
for key in fixture_a fixture_b ipv4_https ipv6_https robots_https dns_udp dns_tcp; do
  test "$(field "$key")" = passed || fail "$key did not pass"
done
test "$(field baseline_result)" = passed || fail "baseline did not pass"
test "$(field stun_expectation)" = matched || fail "STUN expectation mismatch"
test "$(field checkpoint_integrity)" = passed || fail "checkpoint integrity did not pass"

pattern=$(field stun_attempt_pattern)
successes=$(field stun_successes)
printf '%s\n' "$pattern" | grep -Eq '^[PF]{3}$' || fail "STUN pattern invalid"
case "$successes" in ''|*[!0-9]*) fail "STUN successes invalid";; esac
test "$successes" -eq "$(printf '%s' "$pattern" | tr -cd P | wc -c | tr -d ' ')" \
  || fail "STUN pattern count mismatch"

case "$EXPECTED_STUN_POLICY" in
  pass)
    test "$(field stun_udp)" = passed || fail "STUN did not pass"
    test "$successes" -ge 2 || fail "insufficient STUN successes"
    test "$(field release_gate)" = passed || fail "release gate did not pass"
    ;;
  known-fail)
    test "$(field stun_udp)" = failed || fail "known-fail checkpoint unexpectedly passed STUN"
    test "$successes" -lt 2 || fail "known-fail STUN count invalid"
    test "$(field release_gate)" = failed || fail "known failure was hidden"
    ;;
esac

for marker in systemextensionsctl_begin systemextensionsctl_end scutil_nc_list_begin \
  scutil_nc_list_end scutil_nc_show_begin scutil_nc_show_end dns_begin dns_end \
  proxy_begin proxy_end routes_begin routes_end tun_ifconfig_begin tun_ifconfig_end; do
  test "$(grep -Fxc "$marker" "$EVIDENCE/runtime.txt")" -eq 1 || fail "runtime marker invalid: $marker"
done

echo "connected checkpoint verified: baseline=passed stun=$(field stun_udp) release_gate=$(field release_gate)"
