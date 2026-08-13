#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WATCHDOG="$ROOT/scripts/signed_ne_control_watchdog.sh"
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-control-watchdog.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

sh -n "$WATCHDOG"
if grep -E 'scutil|networksetup|(^|[[:space:]])(kill|pkill|defaults)([[:space:]]|$)|route[[:space:]]+(add|change|delete)' \
  "$WATCHDOG" >/dev/null; then
  echo "control-peer watchdog must remain read-only" >&2
  exit 1
fi

ROUTE_OK="$TEMP/route-ok"
ROUTE_CHANGED="$TEMP/route-changed"
ROUTE_MAGIC_DNS_CHANGED="$TEMP/route-magic-dns-changed"
TAILSCALE_DIRECT="$TEMP/tailscale-direct"
TAILSCALE_DERP="$TEMP/tailscale-derp"
CONTROL_PEER=100.64.0.1
MAGIC_DNS_ADDRESS=100.100.100.100
BASELINE_INTERFACE=utun7
printf '%s\n' \
  '#!/bin/sh' \
  "printf '    interface: utun7\\n'" >"$ROUTE_OK"
printf '%s\n' \
  '#!/bin/sh' \
  "printf '    interface: utun8\\n'" >"$ROUTE_CHANGED"
printf '%s\n' \
  '#!/bin/sh' \
  "if [ \"\${3:-}\" = \"$MAGIC_DNS_ADDRESS\" ]; then" \
  "  printf '    interface: utun8\\n'" \
  'else' \
  "  printf '    interface: $BASELINE_INTERFACE\\n'" \
  'fi' >"$ROUTE_MAGIC_DNS_CHANGED"
printf '%s\n' \
  '#!/bin/sh' \
  "printf 'pong from test-peer via 192.0.2.10:41641 in 1ms\\n'" \
  >"$TAILSCALE_DIRECT"
printf '%s\n' \
  '#!/bin/sh' \
  "printf 'pong from test-peer via DERP(test-region) in 20ms\\n'" \
  >"$TAILSCALE_DERP"
chmod 755 \
  "$ROUTE_OK" "$ROUTE_CHANGED" "$ROUTE_MAGIC_DNS_CHANGED" \
  "$TAILSCALE_DIRECT" "$TAILSCALE_DERP"

STOP_FILE="$TEMP/stop"
SUCCESS_LOG="$TEMP/success.log"
"$WATCHDOG" \
  "$CONTROL_PEER" "$BASELINE_INTERFACE" \
  "$MAGIC_DNS_ADDRESS" "$BASELINE_INTERFACE" "$STOP_FILE" 10 \
  "$ROUTE_OK" "$TAILSCALE_DIRECT" 1 5 >"$SUCCESS_LOG" 2>&1 &
watchdog_pid=$!
sleep 0.5
: >"$STOP_FILE"
wait "$watchdog_pid"
success_checks=$(awk -F= \
  '$1 == "control-peer watchdog stopped: checks" {print $2; exit}' \
  "$SUCCESS_LOG")
case "$success_checks" in
  ''|*[!0-9]*|0)
    echo "control-peer watchdog did not perform a successful probe" >&2
    exit 1
    ;;
esac

ROUTE_FAILURE_LOG="$TEMP/route-failure.log"
route_failure_exit=0
if "$WATCHDOG" \
  "$CONTROL_PEER" "$BASELINE_INTERFACE" \
  "$MAGIC_DNS_ADDRESS" "$BASELINE_INTERFACE" "$TEMP/no-route-stop" 10 \
  "$ROUTE_CHANGED" "$TAILSCALE_DIRECT" 1 2 >"$ROUTE_FAILURE_LOG" 2>&1; then
  echo "control-peer watchdog accepted a changed route interface" >&2
  exit 1
else
  route_failure_exit=$?
fi
test "$route_failure_exit" -eq 70 || {
  echo "control-peer route failures did not exhaust the failure allowance" >&2
  exit 1
}

MAGIC_DNS_FAILURE_LOG="$TEMP/magic-dns-failure.log"
magic_dns_failure_exit=0
if "$WATCHDOG" \
  "$CONTROL_PEER" "$BASELINE_INTERFACE" \
  "$MAGIC_DNS_ADDRESS" "$BASELINE_INTERFACE" \
  "$TEMP/no-magic-dns-stop" 10 \
  "$ROUTE_MAGIC_DNS_CHANGED" "$TAILSCALE_DIRECT" 1 2 \
  >"$MAGIC_DNS_FAILURE_LOG" 2>&1; then
  echo "control-peer watchdog accepted a changed MagicDNS route interface" >&2
  exit 1
else
  magic_dns_failure_exit=$?
fi
test "$magic_dns_failure_exit" -eq 70 || {
  echo "MagicDNS route failures did not exhaust the failure allowance" >&2
  exit 1
}

PING_FAILURE_LOG="$TEMP/ping-failure.log"
ping_failure_exit=0
if "$WATCHDOG" \
  "$CONTROL_PEER" "$BASELINE_INTERFACE" \
  "$MAGIC_DNS_ADDRESS" "$BASELINE_INTERFACE" "$TEMP/no-ping-stop" 10 \
  "$ROUTE_OK" /usr/bin/false 1 2 >"$PING_FAILURE_LOG" 2>&1; then
  echo "control-peer watchdog accepted failed Tailscale pings" >&2
  exit 1
else
  ping_failure_exit=$?
fi
test "$ping_failure_exit" -eq 70 || {
  echo "Tailscale ping failures did not exhaust the failure allowance" >&2
  exit 1
}

DERP_FAILURE_LOG="$TEMP/derp-failure.log"
derp_failure_exit=0
if "$WATCHDOG" \
  "$CONTROL_PEER" "$BASELINE_INTERFACE" \
  "$MAGIC_DNS_ADDRESS" "$BASELINE_INTERFACE" "$TEMP/no-derp-stop" 10 \
  "$ROUTE_OK" "$TAILSCALE_DERP" 1 2 >"$DERP_FAILURE_LOG" 2>&1; then
  echo "control-peer watchdog treated a DERP relay as a direct path" >&2
  exit 1
else
  derp_failure_exit=$?
fi
test "$derp_failure_exit" -eq 70 || {
  echo "DERP-only pings did not exhaust the direct-path failure allowance" >&2
  exit 1
}

TIMEOUT_LOG="$TEMP/timeout.log"
timeout_exit=0
if "$WATCHDOG" \
  "$CONTROL_PEER" "$BASELINE_INTERFACE" \
  "$MAGIC_DNS_ADDRESS" "$BASELINE_INTERFACE" "$TEMP/no-timeout-stop" 1 \
  "$ROUTE_OK" "$TAILSCALE_DIRECT" 1 5 >"$TIMEOUT_LOG" 2>&1; then
  echo "control-peer watchdog ignored its hard timeout" >&2
  exit 1
else
  timeout_exit=$?
fi
test "$timeout_exit" -eq 124 || {
  echo "control-peer watchdog returned the wrong hard-timeout status" >&2
  exit 1
}

for private_address in "$CONTROL_PEER" "$MAGIC_DNS_ADDRESS"; do
  if grep -F "$private_address" \
    "$SUCCESS_LOG" "$ROUTE_FAILURE_LOG" "$MAGIC_DNS_FAILURE_LOG" \
    "$PING_FAILURE_LOG" "$DERP_FAILURE_LOG" "$TIMEOUT_LOG" \
    >/dev/null; then
    echo "control-peer watchdog leaked a protected address into logs" >&2
    exit 1
  fi
done

echo "Signed Network Extension control-peer watchdog tests passed."
