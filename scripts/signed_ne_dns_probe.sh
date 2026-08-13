#!/bin/sh
set -eu

# Public best-effort DNS gate for the signed macOS Network Extension test.
# It proves resolver installation/restoration and direct UDP/TCP reachability
# of the synthetic TUN DNS stub. It deliberately makes no upstream-resolver or
# DNS no-leak claim; those require an owner-controlled authoritative canary.

MODE=${1:-}
SYNTHETIC_DNS=198.18.0.2
SYNTHETIC_INTERFACE_ADDRESS=198.18.0.1

TEST_MODE=${AETHERROUTE_SIGNED_DNS_PROBE_TEST_MODE:-NO}
SCUTIL_OVERRIDE=${AETHERROUTE_SIGNED_DNS_PROBE_SCUTIL:-}
ROUTE_OVERRIDE=${AETHERROUTE_SIGNED_DNS_PROBE_ROUTE:-}
IFCONFIG_OVERRIDE=${AETHERROUTE_SIGNED_DNS_PROBE_IFCONFIG:-}
DIG_OVERRIDE=${AETHERROUTE_SIGNED_DNS_PROBE_DIG:-}
UUIDGEN_OVERRIDE=${AETHERROUTE_SIGNED_DNS_PROBE_UUIDGEN:-}
SHASUM_OVERRIDE=${AETHERROUTE_SIGNED_DNS_PROBE_SHASUM:-}
AWK_OVERRIDE=${AETHERROUTE_SIGNED_DNS_PROBE_AWK:-}
SORT_OVERRIDE=${AETHERROUTE_SIGNED_DNS_PROBE_SORT:-}
GREP_OVERRIDE=${AETHERROUTE_SIGNED_DNS_PROBE_GREP:-}
TR_OVERRIDE=${AETHERROUTE_SIGNED_DNS_PROBE_TR:-}

fail() {
  printf 'signed_ne_dns_probe: %s\n' "$1" >&2
  exit 70
}

usage() {
  echo "signed_ne_dns_probe: invalid invocation" >&2
  exit 64
}

case "$TEST_MODE" in
  YES|NO) ;;
  *) fail "invalid test-mode setting" ;;
esac

if [ "$TEST_MODE" != YES ] \
  && { [ -n "$SCUTIL_OVERRIDE" ] \
    || [ -n "$ROUTE_OVERRIDE" ] \
    || [ -n "$IFCONFIG_OVERRIDE" ] \
    || [ -n "$DIG_OVERRIDE" ] \
    || [ -n "$UUIDGEN_OVERRIDE" ] \
    || [ -n "$SHASUM_OVERRIDE" ] \
    || [ -n "$AWK_OVERRIDE" ] \
    || [ -n "$SORT_OVERRIDE" ] \
    || [ -n "$GREP_OVERRIDE" ] \
    || [ -n "$TR_OVERRIDE" ]; }; then
  fail "command overrides are restricted to self-test mode"
fi

SCUTIL=${SCUTIL_OVERRIDE:-/usr/sbin/scutil}
ROUTE=${ROUTE_OVERRIDE:-/sbin/route}
IFCONFIG=${IFCONFIG_OVERRIDE:-/sbin/ifconfig}
DIG=${DIG_OVERRIDE:-/usr/bin/dig}
UUIDGEN=${UUIDGEN_OVERRIDE:-/usr/bin/uuidgen}
SHASUM=${SHASUM_OVERRIDE:-/usr/bin/shasum}
AWK=${AWK_OVERRIDE:-/usr/bin/awk}
SORT=${SORT_OVERRIDE:-/usr/bin/sort}
GREP=${GREP_OVERRIDE:-/usr/bin/grep}
TR=${TR_OVERRIDE:-/usr/bin/tr}

validate_command_path() {
  case "$1" in
    /*) ;;
    *) fail "probe command paths must be absolute" ;;
  esac
  if [ ! -f "$1" ] || [ ! -x "$1" ]; then
    fail "a required probe command is unavailable"
  fi
}

for command_path in \
  "$SCUTIL" "$ROUTE" "$IFCONFIG" "$DIG" "$UUIDGEN" \
  "$SHASUM" "$AWK" "$SORT" "$GREP" "$TR"; do
  validate_command_path "$command_path"
done

capture_dns_configuration() {
  DNS_CONFIGURATION=$($SCUTIL --dns 2>/dev/null) \
    || fail "could not read resolver control-plane state"
  if [ -z "$DNS_CONFIGURATION" ]; then
    fail "resolver control-plane state was empty"
  fi
}

canonicalize_dns_configuration() {
  printf '%s\n' "$DNS_CONFIGURATION" | "$AWK" '
    function flush_resolver(  field_index, record) {
      if (!inside_resolver) return
      record = "section=" section
      for (field_index = 1; field_index <= field_count; field_index++) {
        record = record "|" fields[field_index]
      }
      print record
      delete fields
      field_count = 0
      inside_resolver = 0
    }
    /^DNS configuration/ {
      flush_resolver()
      section = $0
      gsub(/[[:space:]]+/, " ", section)
      next
    }
    /^[[:space:]]*resolver #[0-9]+[[:space:]]*$/ {
      flush_resolver()
      inside_resolver = 1
      next
    }
    inside_resolver {
      field = $0
      sub(/^[[:space:]]+/, "", field)
      sub(/[[:space:]]+$/, "", field)
      gsub(/[[:space:]]+/, " ", field)
      if (field ~ /^(search domain\[[0-9]+\]|nameserver\[[0-9]+\]|domain|options|if_index|flags|order|timeout)[[:space:]]*:/) {
        fields[++field_count] = field
      }
    }
    END { flush_resolver() }
  ' | "$SORT"
}

resolver_hash() {
  canonical_dns=$(canonicalize_dns_configuration) \
    || fail "could not canonicalize resolver control-plane state"
  if [ -z "$canonical_dns" ]; then
    fail "resolver control-plane state had no canonical records"
  fi
  dns_hash=$(printf '%s\n' "$canonical_dns" \
    | "$SHASUM" -a 256 \
    | "$AWK" '{print $1; exit}') \
    || fail "could not hash resolver control-plane state"
  if ! printf '%s\n' "$dns_hash" \
    | "$GREP" -Eq '^[0-9a-f]{64}$'; then
    fail "resolver control-plane hash was invalid"
  fi
  printf '%s\n' "$dns_hash"
}

new_query_name() {
  random_value=$($UUIDGEN 2>/dev/null \
    | "$TR" '[:upper:]' '[:lower:]' \
    | "$TR" -d '-') \
    || fail "could not generate an ephemeral DNS query"
  if ! printf '%s\n' "$random_value" \
    | "$GREP" -Eq '^[0-9a-f]{32}$'; then
    unset random_value
    fail "ephemeral DNS query generation failed"
  fi
  QUERY_NAME="ar-${random_value}.example.com."
  unset random_value
}

run_dig() {
  transport=$1
  new_query_name
  if [ "$transport" = tcp ]; then
    if DIG_OUTPUT=$($DIG -4 "@$SYNTHETIC_DNS" "$QUERY_NAME" A IN \
      +tcp +time=2 +tries=1 +retry=0 +noall +comments +stats \
      2>/dev/null); then
      DIG_EXITED_SUCCESSFULLY=YES
    else
      DIG_OUTPUT=
      DIG_EXITED_SUCCESSFULLY=NO
    fi
  else
    if DIG_OUTPUT=$($DIG -4 "@$SYNTHETIC_DNS" "$QUERY_NAME" A IN \
      +time=2 +tries=1 +retry=0 +noall +comments +stats \
      2>/dev/null); then
      DIG_EXITED_SUCCESSFULLY=YES
    else
      DIG_OUTPUT=
      DIG_EXITED_SUCCESSFULLY=NO
    fi
  fi
  unset QUERY_NAME
}

dig_received_response() {
  [ "$DIG_EXITED_SUCCESSFULLY" = YES ] \
    && printf '%s\n' "$DIG_OUTPUT" \
      | "$GREP" -Eq '^;; ->>HEADER<<-.* status: [A-Z0-9]+,' \
    && printf '%s\n' "$DIG_OUTPUT" \
      | "$GREP" -Eq '^;; flags: [^;]*qr([ ;]|$)' \
    && printf '%s\n' "$DIG_OUTPUT" \
      | "$GREP" -Eq '^;; SERVER: 198\.18\.0\.2#53([[:space:](]|$)'
}

assert_local_stub_absent() {
  route_output=$($ROUTE -n get "$SYNTHETIC_DNS" 2>/dev/null) \
    || fail "the disconnected synthetic DNS route could not be inspected"
  route_interface=$(printf '%s\n' "$route_output" \
    | "$AWK" '$1 == "interface:" {print $2; exit}')
  unset route_output
  if ! printf '%s\n' "$route_interface" \
    | "$GREP" -Eq '^[A-Za-z][A-Za-z0-9._-]{0,31}$'; then
    unset route_interface
    fail "the disconnected synthetic DNS route had no valid interface"
  fi
  if printf '%s\n' "$route_interface" \
    | "$GREP" -Eq '^utun'; then
    unset route_interface
    fail "a synthetic DNS utun route remained while disconnected"
  fi
  unset route_interface

  all_interfaces=$($IFCONFIG -a 2>/dev/null) \
    || fail "local interface addresses could not be inspected"
  if printf '%s\n' "$all_interfaces" \
    | "$GREP" -Eq "^[[:space:]]*inet[[:space:]]+$SYNTHETIC_INTERFACE_ADDRESS([[:space:]/]|$)"; then
    unset all_interfaces
    fail "the synthetic client address remained while disconnected"
  fi
  unset all_interfaces

  # Some gateways transparently answer outbound UDP/53 even though the route
  # leaves through a physical interface. Exercise that path, but do not treat
  # such an answer as proof of a local synthetic stub. A TCP answer remains a
  # hard failure, alongside the route and local-address checks above.
  run_dig udp
  unset DIG_OUTPUT DIG_EXITED_SUCCESSFULLY
  run_dig tcp
  if [ "$DIG_EXITED_SUCCESSFULLY" = YES ]; then
    unset DIG_OUTPUT DIG_EXITED_SUCCESSFULLY
    fail "a TCP DNS query completed while disconnected"
  fi
  unset DIG_OUTPUT DIG_EXITED_SUCCESSFULLY
}

assert_valid_stub_response() {
  for transport in udp tcp; do
    run_dig "$transport"
    if ! dig_received_response \
      || ! printf '%s\n' "$DIG_OUTPUT" \
        | "$GREP" -Eq '^;; ->>HEADER<<-.* status: (NOERROR|NXDOMAIN),'; then
      unset DIG_OUTPUT DIG_EXITED_SUCCESSFULLY
      fail "synthetic DNS stub did not return a valid response"
    fi
    unset DIG_OUTPUT DIG_EXITED_SUCCESSFULLY
  done
}

validate_expected_hash() {
  if ! printf '%s\n' "$1" | "$GREP" -Eq '^[0-9a-f]{64}$'; then
    usage
  fi
}

assert_default_resolver_uses_stub() {
  if ! printf '%s\n' "$DNS_CONFIGURATION" | "$AWK" '
    $0 == "DNS configuration" { in_global = 1; next }
    in_global && /^DNS configuration/ { exit }
    in_global && /^[[:space:]]*resolver #[0-9]+[[:space:]]*$/ {
      if (saw_resolver) exit
      saw_resolver = 1
      next
    }
    in_global && saw_resolver {
      field = $0
      sub(/^[[:space:]]+/, "", field)
      sub(/[[:space:]]+$/, "", field)
      if (field ~ /^nameserver\[[0-9]+\][[:space:]]*:[[:space:]]*198\.18\.0\.2$/) found = 1
    }
    END { exit found ? 0 : 1 }
  '; then
    fail "the default resolver does not contain the synthetic DNS stub"
  fi
}

assert_stub_route_and_interface() {
  route_output=$($ROUTE -n get "$SYNTHETIC_DNS" 2>/dev/null) \
    || fail "the synthetic DNS route could not be inspected"
  route_interface=$(printf '%s\n' "$route_output" \
    | "$AWK" '$1 == "interface:" {print $2; exit}')
  unset route_output
  if ! printf '%s\n' "$route_interface" \
    | "$GREP" -Eq '^utun[0-9]+$'; then
    unset route_interface
    fail "the synthetic DNS route is not attached to a utun interface"
  fi
  interface_output=$($IFCONFIG "$route_interface" 2>/dev/null) \
    || fail "the synthetic DNS interface could not be inspected"
  unset route_interface
  if ! printf '%s\n' "$interface_output" \
    | "$GREP" -Eq "^[[:space:]]*inet[[:space:]]+$SYNTHETIC_INTERFACE_ADDRESS([[:space:]/]|$)"; then
    unset interface_output
    fail "the utun interface does not own the synthetic client address"
  fi
  unset interface_output
}

case "$MODE" in
  baseline)
    [ "$#" -eq 1 ] || usage
    capture_dns_configuration
    baseline_hash=$(resolver_hash)
    assert_local_stub_absent
    printf 'baseline_dns_sha256=%s\n' "$baseline_hash"
    ;;
  disconnected)
    [ "$#" -eq 2 ] || usage
    validate_expected_hash "$2"
    capture_dns_configuration
    [ "$(resolver_hash)" = "$2" ] \
      || fail "resolver control-plane state was not restored"
    assert_local_stub_absent
    echo "dns_probe=disconnected:passed"
    ;;
  tun-connected)
    [ "$#" -eq 1 ] || usage
    capture_dns_configuration
    assert_default_resolver_uses_stub
    assert_stub_route_and_interface
    assert_valid_stub_response
    echo "dns_probe=tun-connected:passed"
    ;;
  transparent-connected)
    [ "$#" -eq 2 ] || usage
    validate_expected_hash "$2"
    capture_dns_configuration
    [ "$(resolver_hash)" = "$2" ] \
      || fail "transparent mode changed resolver control-plane state"
    echo "dns_probe=transparent-connected:passed"
    ;;
  *) usage ;;
esac
