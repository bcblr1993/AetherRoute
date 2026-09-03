#!/bin/sh
set -eu

test "$#" -eq 10 || {
  echo "usage: $0 evidence rule|global|direct provider-pid pass|fail tun|transparent capture-sha256 expected-build expected-app-cdhash expected-provider-cdhash expected-provider-sha256" >&2
  exit 64
}
EVIDENCE=$1
EXPECTED_MODE=$2
EXPECTED_PID=$3
EXPECTED_GOOGLE=$4
EXPECTED_ENGINE=$5
EXPECTED_CAPTURE_SHA256=$6
EXPECTED_BUILD=$7
EXPECTED_APP_CDHASH=$8
EXPECTED_PROVIDER_CDHASH=$9
EXPECTED_PROVIDER_SHA256=${10}
fail() { echo "route-mode verification failed: $*" >&2; exit 1; }
case "$EVIDENCE" in /*) ;; *) fail "absolute evidence path required";; esac
case "$EXPECTED_MODE" in rule|global|direct) ;; *) fail "invalid mode";; esac
case "$EXPECTED_PID" in ''|*[!0-9]*) fail "invalid PID";; esac
case "$EXPECTED_GOOGLE" in pass|fail) ;; *) fail "invalid Google expectation";; esac
case "$EXPECTED_ENGINE" in tun|transparent) ;; *) fail "invalid engine";; esac
printf '%s\n' "$EXPECTED_CAPTURE_SHA256:$EXPECTED_PROVIDER_SHA256" \
  | grep -Eq '^[0-9a-f]{64}:[0-9a-f]{64}$' || fail "invalid SHA256"
printf '%s\n' "$EXPECTED_APP_CDHASH:$EXPECTED_PROVIDER_CDHASH" \
  | grep -Eq '^[0-9a-f]{40}:[0-9a-f]{40}$' || fail "invalid CDHash"
printf '%s\n' "$EXPECTED_BUILD" | grep -Eq '^[1-9][0-9]*$' \
  || fail "invalid build"
test -d "$EVIDENCE" && test ! -L "$EVIDENCE" || fail "evidence directory invalid"
for name in capture.sh result.txt runtime.txt google-v4.txt google-v6.txt dns-udp.txt dns-tcp.txt SHA256SUMS; do
  test -f "$EVIDENCE/$name" && test ! -L "$EVIDENCE/$name" || fail "$name missing or symlinked"
done
(cd "$EVIDENCE" && shasum -a 256 -c SHA256SUMS >/dev/null) || fail "hash mismatch"
listed=$(awk '{print $2}' "$EVIDENCE/SHA256SUMS" | LC_ALL=C sort)
actual=$(cd "$EVIDENCE" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print \
  | sed 's#^./##' | LC_ALL=C sort)
test "$listed" = "$actual" || fail "file set mismatch"
test "$(shasum -a 256 "$EVIDENCE/capture.sh" | awk '{print $1}')" = "$EXPECTED_CAPTURE_SHA256" \
  || fail "capture hash mismatch"
field() {
  key=$1
  count=$(awk -F= -v k="$key" '$1==k{n++}END{print n+0}' "$EVIDENCE/result.txt")
  test "$count" -eq 1 || fail "$key must occur exactly once"
  awk -F= -v k="$key" '$1==k{print substr($0,index($0,"=")+1)}' "$EVIDENCE/result.txt"
}
test "$(field schema)" = 1 || fail "schema mismatch"
test "$(field engine)" = "$EXPECTED_ENGINE" || fail "engine mismatch"
test "$(field expected_runtime_mode)" = "$EXPECTED_MODE" || fail "expected runtime mode mismatch"
test "$(field runtime_mode_evidence)" = provider-acknowledged-ui || fail "runtime mode evidence mismatch"
test "$(field persisted_launch_mode)" = rule || fail "persisted launch mode changed during hot switch"
test "$(field expected_provider_pid)" = "$EXPECTED_PID" || fail "expected PID mismatch"
test "$(field provider_pid_count)" = 1 || fail "provider count mismatch"
test "$(field provider_pid)" = "$EXPECTED_PID" || fail "provider restarted"
test "$(field provider_build)" = "$EXPECTED_BUILD" || fail "provider build mismatch"
case "$EXPECTED_ENGINE" in
  tun)
    expected_proxy_sha256=309309dd60b8263c4dbbcfc5194716c3cb542b1a64aca05ab55d659ffd46a218
    ;;
  transparent)
    expected_proxy_sha256=07127fc2dd861e8f49d521909edcb06e899995b7fb17599e753a150718727293
    ;;
esac
test "$(field provider_cdhash)" = "$EXPECTED_PROVIDER_CDHASH" || fail "provider CDHash mismatch"
test "$(field provider_sha256)" = "$EXPECTED_PROVIDER_SHA256" || fail "provider SHA mismatch"
test "$(field app_build)" = "$EXPECTED_BUILD" || fail "App build mismatch"
test "$(field app_cdhash)" = "$EXPECTED_APP_CDHASH" || fail "App CDHash mismatch"
default_if=$(field default_interface)
case "$EXPECTED_ENGINE" in
  tun)
    test "$(field vpn_status)" = Connected || fail "TUN VPN service is not connected"
    case "$default_if" in utun[0-9]*) ;; *) fail "default route is not a utun";; esac
    test "$(field synthetic_stub_interface)" = "$default_if" || fail "synthetic route does not match default utun"
    test "$(field fixture_host_interface)" = en0 || fail "fixture route mismatch"
    ;;
  transparent)
    test "$(field vpn_status)" = Disconnected || fail "TUN VPN service is unexpectedly connected"
    test "$default_if" = en0 || fail "default route mismatch"
    test "$(field synthetic_stub_interface)" = en0 || fail "synthetic route mismatch"
    test "$(field fixture_host_interface)" = en0 || fail "fixture route mismatch"
    ;;
esac
test "$(field system_proxy_sha256)" = "$expected_proxy_sha256" || fail "system proxy mismatch"
for key in fixture_a fixture_b dns_udp dns_tcp apple_direct; do
  test "$(field "$key")" = passed || fail "$key failed"
done
test "$(field expected_google)" = "$EXPECTED_GOOGLE" || fail "Google expectation mismatch"
case "$EXPECTED_GOOGLE:$(field google_result)" in
  pass:passed|fail:failed) ;;
  *) fail "Google result mismatch";;
esac
test "$(field google_expectation)" = matched || fail "Google expectation not matched"
test "$(field recent_crash_count)" = 0 || fail "recent crash present"
test "$(field result)" = passed || fail "checkpoint failed"
for marker in service_begin service_end network_begin network_end processes_begin processes_end; do
  test "$(grep -Fxc "$marker" "$EVIDENCE/runtime.txt")" -eq 1 || fail "runtime marker invalid: $marker"
done
echo "route-mode checkpoint verified: engine=$EXPECTED_ENGINE mode=$EXPECTED_MODE pid=$EXPECTED_PID google=$EXPECTED_GOOGLE"
