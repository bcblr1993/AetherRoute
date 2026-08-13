#!/bin/sh
set -eu

# This helper is deliberately read-only. The parent signed Network Extension
# gate owns the narrowly scoped disconnect action if this process reports a
# control-path failure or timeout.
CONTROL_PEER=${1:-}
BASELINE_INTERFACE=${2:-}
MAGIC_DNS_ADDRESS=${3:-}
BASELINE_MAGIC_DNS_INTERFACE=${4:-}
STOP_FILE=${5:-}
HARD_TIMEOUT_SECONDS=${6:-}
ROUTE_COMMAND=${7:-}
TAILSCALE_CLI=${8:-}
INTERVAL_SECONDS=${9:-2}
FAILURE_LIMIT=${10:-5}

usage() {
  echo "usage: $0 control-peer-ipv4 baseline-interface magic-dns-ipv4 baseline-magic-dns-interface /absolute/stop-file hard-timeout-seconds /absolute/route /absolute/tailscale [interval-seconds] [failure-limit]" >&2
}

valid_ipv4_address() {
  printf '%s\n' "$1" | awk -F '[.]' '
    NF != 4 { exit 1 }
    {
      for (octet_index = 1; octet_index <= 4; octet_index++) {
        if ($octet_index !~ /^[0-9]+$/ || $octet_index < 0 || $octet_index > 255) exit 1
      }
    }
  '
}

if ! valid_ipv4_address "$CONTROL_PEER" \
  || ! valid_ipv4_address "$MAGIC_DNS_ADDRESS"; then
  usage
  exit 64
fi
case "$BASELINE_INTERFACE" in
  utun[0-9]*) ;;
  *) usage; exit 64 ;;
esac
case "$BASELINE_MAGIC_DNS_INTERFACE" in
  utun[0-9]*) ;;
  *) usage; exit 64 ;;
esac
case "$STOP_FILE" in
  /*) ;;
  *) usage; exit 64 ;;
esac
for command_path in "$ROUTE_COMMAND" "$TAILSCALE_CLI"; do
  case "$command_path" in
    /*) ;;
    *) usage; exit 64 ;;
  esac
  if [ ! -x "$command_path" ]; then
    echo "control-peer watchdog requires executable read-only probes" >&2
    exit 64
  fi
done
for numeric_value in "$HARD_TIMEOUT_SECONDS" "$INTERVAL_SECONDS" "$FAILURE_LIMIT"; do
  case "$numeric_value" in
    ''|*[!0-9]*) usage; exit 64 ;;
  esac
done
if [ "$HARD_TIMEOUT_SECONDS" -lt 1 ] \
  || [ "$HARD_TIMEOUT_SECONDS" -gt 3600 ] \
  || [ "$INTERVAL_SECONDS" -lt 1 ] \
  || [ "$INTERVAL_SECONDS" -gt 60 ] \
  || [ "$FAILURE_LIMIT" -lt 1 ] \
  || [ "$FAILURE_LIMIT" -gt 20 ]; then
  usage
  exit 64
fi

started_at=$(date +%s)
consecutive_failures=0
checks=0
tailscale_direct_ping() {
  direct_ping_output=$("$TAILSCALE_CLI" ping \
    --c 1 --timeout 2s --until-direct=true "$CONTROL_PEER" 2>/dev/null) \
    || return 1
  printf '%s\n' "$direct_ping_output" | grep -Eq \
    ' via ([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+( |$)| via \[[0-9A-Fa-f:]+\]:[0-9]+( |$)'
}
while :; do
  if [ -e "$STOP_FILE" ]; then
    printf 'control-peer watchdog stopped: checks=%s\n' "$checks"
    exit 0
  fi
  check_started_at=$(date +%s)
  if [ $((check_started_at - started_at)) -ge "$HARD_TIMEOUT_SECONDS" ]; then
    echo "control-peer watchdog reached its hard timeout" >&2
    exit 124
  fi

  current_interface=$("$ROUTE_COMMAND" -n get "$CONTROL_PEER" 2>/dev/null \
    | awk '$1 == "interface:" {print $2; exit}' || true)
  current_magic_dns_interface=$("$ROUTE_COMMAND" -n get \
    "$MAGIC_DNS_ADDRESS" 2>/dev/null \
    | awk '$1 == "interface:" {print $2; exit}' || true)
  route_is_unchanged=0
  magic_dns_route_is_unchanged=0
  tailscale_ping_passed=0
  if [ "$current_interface" = "$BASELINE_INTERFACE" ]; then
    route_is_unchanged=1
  fi
  if [ "$current_magic_dns_interface" = "$BASELINE_MAGIC_DNS_INTERFACE" ]; then
    magic_dns_route_is_unchanged=1
  fi
  if tailscale_direct_ping; then
    tailscale_ping_passed=1
  fi
  checks=$((checks + 1))

  if [ "$route_is_unchanged" -eq 1 ] \
    && [ "$magic_dns_route_is_unchanged" -eq 1 ] \
    && [ "$tailscale_ping_passed" -eq 1 ]; then
    consecutive_failures=0
  else
    consecutive_failures=$((consecutive_failures + 1))
    printf 'control-peer watchdog check failed: consecutive=%s/%s\n' \
      "$consecutive_failures" "$FAILURE_LIMIT" >&2
    if [ "$consecutive_failures" -ge "$FAILURE_LIMIT" ]; then
      echo "control-peer watchdog exhausted its failure allowance" >&2
      exit 70
    fi
  fi

  check_finished_at=$(date +%s)
  check_duration=$((check_finished_at - check_started_at))
  remaining_interval=$((INTERVAL_SECONDS - check_duration))
  if [ "$remaining_interval" -gt 0 ]; then
    sleep "$remaining_interval"
  fi
done
