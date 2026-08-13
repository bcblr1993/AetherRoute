#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROBE="$ROOT/scripts/signed_ne_dns_probe.sh"
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-dns-probe.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

sh -n "$PROBE"

BASELINE_FIXTURE="$TEMP/baseline.txt"
EQUIVALENT_BASELINE_FIXTURE="$TEMP/equivalent-baseline.txt"
CHANGED_FIXTURE="$TEMP/changed.txt"
TUN_FIXTURE="$TEMP/tun.txt"
SCOPED_ONLY_FIXTURE="$TEMP/scoped-only.txt"
printf '%s\n' \
  'DNS configuration' \
  '' \
  'resolver #1' \
  '  nameserver[0] : 192.0.2.53' \
  '  if_index : 9 (en0)' \
  '  flags    : Request A records' \
  '  reach    : 0x00000002 (Reachable)' \
  '  order    : 200000' \
  '' \
  'DNS configuration (for scoped queries)' \
  '' \
  'resolver #1' \
  '  nameserver[0] : 192.0.2.54' \
  '  if_index : 9 (en0)' \
  '  flags    : Scoped, Request A records' \
  '  order    : 200000' >"$BASELINE_FIXTURE"
printf '%s\n' \
  'DNS configuration' \
  '' \
  'resolver #7' \
  '  nameserver[0] : 192.0.2.53' \
  '  if_index : 9 (en0)' \
  '  flags    : Request A records' \
  '  reach    : 0x00000000 (Not Reachable)' \
  '  order    : 200000' \
  '' \
  'DNS configuration (for scoped queries)' \
  '' \
  'resolver #4' \
  '  nameserver[0] : 192.0.2.54' \
  '  if_index : 9 (en0)' \
  '  flags    : Scoped, Request A records' \
  '  reach    : 0x00000002 (Reachable)' \
  '  order    : 200000' >"$EQUIVALENT_BASELINE_FIXTURE"
printf '%s\n' \
  'DNS configuration' \
  '' \
  'resolver #1' \
  '  nameserver[0] : 192.0.2.99' \
  '  if_index : 9 (en0)' \
  '  flags    : Request A records' \
  '  order    : 200000' >"$CHANGED_FIXTURE"
printf '%s\n' \
  'DNS configuration' \
  '' \
  'resolver #1' \
  '  nameserver[0] : 198.18.0.2' \
  '  if_index : 42 (utun42)' \
  '  flags    : Request A records' \
  '  order    : 100000' \
  '' \
  'resolver #2' \
  '  nameserver[0] : 192.0.2.53' \
  '  if_index : 9 (en0)' \
  '  flags    : Request A records' \
  '  order    : 200000' \
  '' \
  'DNS configuration (for scoped queries)' \
  '' \
  'resolver #1' \
  '  nameserver[0] : 192.0.2.54' \
  '  if_index : 9 (en0)' \
  '  flags    : Scoped, Request A records' \
  '  order    : 200000' >"$TUN_FIXTURE"
printf '%s\n' \
  'DNS configuration' \
  '' \
  'resolver #1' \
  '  nameserver[0] : 192.0.2.53' \
  '  if_index : 9 (en0)' \
  '  flags    : Request A records' \
  '  order    : 200000' \
  '' \
  'DNS configuration (for scoped queries)' \
  '' \
  'resolver #1' \
  '  nameserver[0] : 198.18.0.2' \
  '  if_index : 42 (utun42)' \
  '  flags    : Scoped, Request A records' \
  '  order    : 100000' >"$SCOPED_ONLY_FIXTURE"

FAKE_SCUTIL="$TEMP/scutil"
FAKE_ROUTE="$TEMP/route"
FAKE_IFCONFIG="$TEMP/ifconfig"
FAKE_DIG="$TEMP/dig"
FAKE_UUIDGEN="$TEMP/uuidgen"
DIG_CALL_LOG="$TEMP/dig-calls.log"
printf '%s\n' \
  '#!/bin/sh' \
  'test "${1:-}" = "--dns" || exit 64' \
  '/bin/cat "${AETHERROUTE_DNS_TEST_FIXTURE:?}"' >"$FAKE_SCUTIL"
printf '%s\n' \
  '#!/bin/sh' \
  'test "${1:-}" = "-n" || exit 64' \
  'test "${2:-}" = "get" || exit 64' \
  'printf "    interface: %s\n" "${AETHERROUTE_DNS_TEST_ROUTE_INTERFACE:-utun42}"' \
  >"$FAKE_ROUTE"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500\n" "${1:-utun42}"' \
  'printf "\tinet %s --> 198.18.0.2 netmask 0xffffffff\n" "${AETHERROUTE_DNS_TEST_INTERFACE_ADDRESS:-198.18.0.1}"' \
  >"$FAKE_IFCONFIG"
printf '%s\n' \
  '#!/bin/sh' \
  'transport=udp' \
  'for argument in "$@"; do' \
  '  test "$argument" = "+tcp" && transport=tcp' \
  'done' \
  'printf "%s\n" "$transport" >>"${AETHERROUTE_DNS_TEST_DIG_LOG:?}"' \
  'case "${AETHERROUTE_DNS_TEST_DIG_MODE:-success}:$transport" in' \
  '  unavailable:*) exit 9 ;;' \
  '  udp-only-hijack:tcp) exit 9 ;;' \
  '  tcp-fail:tcp) exit 9 ;;' \
  '  tcp-empty-success:tcp) exit 0 ;;' \
  '  tcp-wrong-server:tcp) server=192.0.2.53 ;;' \
  '  bad-status:*) server=198.18.0.2 ;;' \
  '  *) server=198.18.0.2 ;;' \
  'esac' \
  'status=NXDOMAIN' \
  'test "${AETHERROUTE_DNS_TEST_DIG_MODE:-success}" = udp-only-hijack && status=NOERROR' \
  'test "${AETHERROUTE_DNS_TEST_DIG_MODE:-success}" = bad-status && status=SERVFAIL' \
  'printf ";; ->>HEADER<<- opcode: QUERY, status: %s, id: 1\n" "$status"' \
  'printf ";; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0\n"' \
  'printf ";; SERVER: %s#53(%s) (%s)\n" "$server" "$server" "$transport"' \
  >"$FAKE_DIG"
printf '%s\n' \
  '#!/bin/sh' \
  'echo "00112233-4455-6677-8899-AABBCCDDEEFF"' >"$FAKE_UUIDGEN"
chmod 755 "$FAKE_SCUTIL" "$FAKE_ROUTE" "$FAKE_IFCONFIG" \
  "$FAKE_DIG" "$FAKE_UUIDGEN"

run_probe() {
  test "$#" -ge 5 || exit 64
  test_fixture=$1
  test_route_interface=$2
  test_interface_address=$3
  test_dig_mode=$4
  shift 4
  /usr/bin/env -i \
    LANG=C \
    LC_ALL=C \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    AETHERROUTE_SIGNED_DNS_PROBE_TEST_MODE=YES \
    AETHERROUTE_SIGNED_DNS_PROBE_SCUTIL="$FAKE_SCUTIL" \
    AETHERROUTE_SIGNED_DNS_PROBE_ROUTE="$FAKE_ROUTE" \
    AETHERROUTE_SIGNED_DNS_PROBE_IFCONFIG="$FAKE_IFCONFIG" \
    AETHERROUTE_SIGNED_DNS_PROBE_DIG="$FAKE_DIG" \
    AETHERROUTE_SIGNED_DNS_PROBE_UUIDGEN="$FAKE_UUIDGEN" \
    AETHERROUTE_DNS_TEST_FIXTURE="$test_fixture" \
    AETHERROUTE_DNS_TEST_ROUTE_INTERFACE="$test_route_interface" \
    AETHERROUTE_DNS_TEST_INTERFACE_ADDRESS="$test_interface_address" \
    AETHERROUTE_DNS_TEST_DIG_MODE="$test_dig_mode" \
    AETHERROUTE_DNS_TEST_DIG_LOG="$DIG_CALL_LOG" \
    "$PROBE" "$@"
}

if /usr/bin/env -i \
  AETHERROUTE_SIGNED_DNS_PROBE_SCUTIL="$FAKE_SCUTIL" \
  "$PROBE" baseline >/dev/null 2>&1; then
  echo "production probe accepted a command override" >&2
  exit 1
fi

baseline_output=$(run_probe \
  "$BASELINE_FIXTURE" en0 192.0.2.10 unavailable baseline)
baseline_hash=${baseline_output#baseline_dns_sha256=}
if ! printf '%s\n' "$baseline_output" \
  | grep -Eq '^baseline_dns_sha256=[0-9a-f]{64}$'; then
  echo "baseline probe did not return a canonical hash" >&2
  exit 1
fi
: >"$DIG_CALL_LOG"
udp_hijack_baseline_output=$(run_probe \
  "$BASELINE_FIXTURE" en0 192.0.2.10 udp-only-hijack baseline)
test "$udp_hijack_baseline_output" = "$baseline_output" || {
  echo "baseline probe rejected a nonlocal UDP-only DNS hijack" >&2
  exit 1
}
for expected_transport in udp tcp; do
  if ! grep -Fx "$expected_transport" "$DIG_CALL_LOG" >/dev/null; then
    echo "UDP-only hijack fixture did not exercise both DNS transports" >&2
    exit 1
  fi
done
if run_probe "$BASELINE_FIXTURE" en0 192.0.2.10 success baseline \
  >/dev/null 2>&1; then
  echo "baseline probe accepted a TCP-reachable synthetic DNS endpoint" >&2
  exit 1
fi
if run_probe "$BASELINE_FIXTURE" en0 192.0.2.10 tcp-empty-success baseline \
  >/dev/null 2>&1; then
  echo "baseline probe accepted a successful empty TCP DNS transaction" >&2
  exit 1
fi
if run_probe "$BASELINE_FIXTURE" utun42 198.18.0.1 success baseline \
  >/dev/null 2>&1; then
  echo "baseline probe accepted a residual synthetic utun and stub" >&2
  exit 1
fi
if run_probe "$BASELINE_FIXTURE" utun42 192.0.2.10 unavailable baseline \
  >/dev/null 2>&1; then
  echo "baseline probe accepted a residual synthetic utun route" >&2
  exit 1
fi
if run_probe "$BASELINE_FIXTURE" en0 198.18.0.1 unavailable baseline \
  >/dev/null 2>&1; then
  echo "baseline probe accepted a residual synthetic client address" >&2
  exit 1
fi

run_probe "$BASELINE_FIXTURE" en0 192.0.2.10 unavailable \
  disconnected "$baseline_hash" >/dev/null
run_probe "$BASELINE_FIXTURE" en0 192.0.2.10 udp-only-hijack \
  disconnected "$baseline_hash" >/dev/null
if run_probe "$BASELINE_FIXTURE" utun42 198.18.0.1 success \
  disconnected "$baseline_hash" >/dev/null 2>&1; then
  echo "disconnected probe accepted a residual synthetic utun and stub" >&2
  exit 1
fi
if run_probe "$CHANGED_FIXTURE" en0 192.0.2.10 unavailable \
  disconnected "$baseline_hash" >/dev/null 2>&1; then
  echo "disconnected probe accepted changed resolver state" >&2
  exit 1
fi

tun_output=$(run_probe \
  "$TUN_FIXTURE" utun42 198.18.0.1 success tun-connected 2>&1)
test "$tun_output" = 'dns_probe=tun-connected:passed' || {
  echo "valid TUN DNS data-plane fixture did not pass" >&2
  exit 1
}
if run_probe "$SCOPED_ONLY_FIXTURE" utun42 198.18.0.1 success \
  tun-connected >/dev/null 2>&1; then
  echo "TUN probe accepted a scoped-only synthetic resolver" >&2
  exit 1
fi
if run_probe "$TUN_FIXTURE" en0 198.18.0.1 success \
  tun-connected >/dev/null 2>&1; then
  echo "TUN probe accepted a non-utun synthetic DNS route" >&2
  exit 1
fi
if run_probe "$TUN_FIXTURE" utun42 198.18.0.9 success \
  tun-connected >/dev/null 2>&1; then
  echo "TUN probe accepted a utun without the synthetic client address" >&2
  exit 1
fi
if run_probe "$TUN_FIXTURE" utun42 198.18.0.1 tcp-wrong-server \
  tun-connected >/dev/null 2>&1; then
  echo "TUN probe accepted an invalid TCP DNS transport result" >&2
  exit 1
fi
if run_probe "$TUN_FIXTURE" utun42 198.18.0.1 bad-status \
  tun-connected >/dev/null 2>&1; then
  echo "TUN probe accepted an invalid DNS response status" >&2
  exit 1
fi

run_probe "$BASELINE_FIXTURE" en0 192.0.2.10 unavailable \
  transparent-connected "$baseline_hash" >/dev/null
run_probe "$EQUIVALENT_BASELINE_FIXTURE" en0 192.0.2.10 unavailable \
  transparent-connected "$baseline_hash" >/dev/null
if run_probe "$CHANGED_FIXTURE" en0 192.0.2.10 unavailable \
  transparent-connected "$baseline_hash" >/dev/null 2>&1; then
  echo "transparent probe accepted changed resolver state" >&2
  exit 1
fi

if run_probe "$BASELINE_FIXTURE" en0 192.0.2.10 unavailable \
  disconnected BAD_HASH >/dev/null 2>&1; then
  echo "probe accepted an invalid resolver hash" >&2
  exit 1
fi
if /usr/bin/env -i \
  AETHERROUTE_SIGNED_DNS_PROBE_TEST_MODE=YES \
  AETHERROUTE_SIGNED_DNS_PROBE_SCUTIL=relative/scutil \
  "$PROBE" baseline >/dev/null 2>&1; then
  echo "probe accepted a relative command path" >&2
  exit 1
fi
if run_probe "$BASELINE_FIXTURE" en0 192.0.2.10 unavailable \
  unsupported-mode >/dev/null 2>&1; then
  echo "probe accepted an unsupported mode" >&2
  exit 1
fi

combined_success_output=$(printf '%s\n%s\n' "$baseline_output" "$tun_output")
if printf '%s\n' "$combined_success_output" \
  | grep -Eq 'ar-|example\.com'; then
  echo "probe retained an ephemeral DNS query name in evidence" >&2
  exit 1
fi

echo "Signed Network Extension DNS probe tests passed."
