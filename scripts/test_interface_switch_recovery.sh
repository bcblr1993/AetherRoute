#!/bin/sh
set -eu

# Release gate: traffic must come back on its own after the Mac moves to a
# different network interface and the old one goes away.
#
# Run on a Mac with two working physical uplinks (the Mac mini: Ethernet en0
# and Wi-Fi en1), with AetherRoute connected in the mode under test. Each
# cycle switches off the interface that carries traffic, so the Mac moves to
# the other one, and waits for a proxied probe to answer again; then it
# brings that interface back, switches off the other, and waits again. Every
# move must recover within RECOVERY_DEADLINE_SECONDS without anyone touching
# the app. Run it once with the TUN engine and once with the transparent
# proxy.
#
# Why: until 1.7.1 the transparent proxy bound every outbound socket to the
# interface it started on. After a Mac woke onto wired Ethernet with Wi-Fi
# gone (en0 -> en11) it carried nothing until the user reconnected by hand.
# The old interface has to really go away: merely reordering services keeps
# it up with its address and route, sockets bound to it keep working, and the
# broken 1.7.0 build passes. A move between networks on one interface (an
# address alias on en0, as earlier switch tests did) never showed it either.
#
# Only one interface is ever off, and it comes back before the other goes, so
# the Mac stays reachable. Connections on the moving interface drop, SSH
# included: start this detached (scripts/test_remote_interface_switch.sh
# does) and read RESULT_FILE. Every service is switched back on, in its
# original order, on every exit path.
#
# Exit status: 0 every move recovered, 1 a move did not recover, 2
# inconclusive (no second uplink, a switch did not take effect, or the probe
# failed before any switch).

PROBE_URL=${AETHERROUTE_SWITCH_PROBE_URL:-https://www.google.com/generate_204}
CYCLES=${AETHERROUTE_SWITCH_CYCLES:-3}
RECOVERY_DEADLINE_SECONDS=${AETHERROUTE_SWITCH_RECOVERY_DEADLINE_SECONDS:-15}
LINK_DEADLINE_SECONDS=${AETHERROUTE_SWITCH_LINK_DEADLINE_SECONDS:-45}
SETTLE_SECONDS=${AETHERROUTE_SWITCH_SETTLE_SECONDS:-10}
RESULT_FILE=${AETHERROUTE_SWITCH_RESULT_FILE:-$HOME/aetherroute-interface-switch.txt}
ALTERNATE_SERVICE=${AETHERROUTE_SWITCH_ALTERNATE_SERVICE:-}

for value in "$CYCLES" "$RECOVERY_DEADLINE_SECONDS" "$LINK_DEADLINE_SECONDS" "$SETTLE_SECONDS"; do
  case "$value" in
    ''|*[!0-9]*) echo "cycle and second counts must be positive integers" >&2; exit 64 ;;
  esac
done
case "$PROBE_URL" in
  https://*) ;;
  *) echo "probe URL must be https" >&2; exit 64 ;;
esac

: > "$RESULT_FILE"
report() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$RESULT_FILE"; }

ORIGINAL_ORDER=$(networksetup -listnetworkserviceorder \
  | sed -n 's/^([0-9*]*) //p')
ORIGINAL_SERVICE=
ALTERNATE=
restore_services() {
  for service in "$ORIGINAL_SERVICE" "$ALTERNATE"; do
    test -n "$service" || continue
    networksetup -setnetworkserviceenabled "$service" on >/dev/null 2>&1 || true
  done
  test -n "$ORIGINAL_ORDER" || return 0
  printf '%s\n' "$ORIGINAL_ORDER" | tr '\n' '\0' \
    | xargs -0 networksetup -ordernetworkservices >/dev/null 2>&1 || true
}
trap restore_services EXIT HUP INT TERM

current_order() {
  networksetup -listnetworkserviceorder | sed -n 's/^([0-9*]*) //p'
}

# The physical interface macOS sends traffic through: the first ordered
# service on an addressed en* interface. Under TUN the system's primary
# interface is the tunnel, so it cannot be read from State:/Network/Global.
primary_interface() {
  current_order | while IFS= read -r service; do
    device=$(service_device "$service")
    case "$device" in
      en[0-9]*) ;;
      *) continue ;;
    esac
    has_ipv4 "$device" || continue
    printf '%s\n' "$device"
    break
  done
}

service_device() {
  networksetup -listnetworkserviceorder | awk -v service="$1" '
    $0 ~ "^\\([0-9*]+\\) " {
      name = $0; sub(/^\([0-9*]+\) /, "", name)
      current = name
    }
    /Device: / && current == service {
      device = $0; sub(/.*Device: /, "", device); sub(/\).*/, "", device)
      print device; exit
    }'
}

has_ipv4() {
  ifconfig "$1" 2>/dev/null | grep -q 'status: active' \
    && ifconfig "$1" 2>/dev/null | grep -q 'inet '
}

service_for_device() {
  printf '%s\n' "$ORIGINAL_ORDER" | while IFS= read -r service; do
    test "$(service_device "$service")" = "$1" || continue
    printf '%s\n' "$service"
    break
  done
}

# The first ordered service on another active physical interface.
pick_alternate() {
  printf '%s\n' "$ORIGINAL_ORDER" | while IFS= read -r service; do
    device=$(service_device "$service")
    case "$device" in
      en[0-9]*) ;;
      *) continue ;;
    esac
    test "$device" != "$1" || continue
    has_ipv4 "$device" || continue
    printf '%s\n' "$service"
    break
  done
}

probe() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$PROBE_URL" 2>/dev/null || true
}

# Waits until DEVICE carries traffic for the Mac: up, addressed and primary.
wait_for_uplink() {
  waited=0
  while [ "$waited" -lt "$LINK_DEADLINE_SECONDS" ]; do
    if has_ipv4 "$1" && [ "$(primary_interface)" = "$1" ]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

wait_for_address() {
  waited=0
  while [ "$waited" -lt "$LINK_DEADLINE_SECONDS" ]; do
    has_ipv4 "$1" && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# Echoes the seconds until the probe answered, or fails at the deadline.
wait_for_recovery() {
  started=$(date +%s)
  while :; do
    if [ "$(probe)" = 204 ]; then
      echo $(($(date +%s) - started))
      return 0
    fi
    elapsed=$(($(date +%s) - started))
    test "$elapsed" -lt "$RECOVERY_DEADLINE_SECONDS" || return 1
    sleep 1
  done
}

# Puts SERVICE first and keeps the rest in their original order.
promote() {
  {
    printf '%s\n' "$1"
    printf '%s\n' "$ORIGINAL_ORDER" | grep -Fxv "$1"
  } | tr '\n' '\0' | xargs -0 networksetup -ordernetworkservices
}

# Moves the Mac from FROM to TO by switching FROM off, then checks recovery.
# FROM is made primary first, so it is what carries traffic when it goes.
move() {
  from_service=$1
  to_service=$2
  from_device=$(service_device "$from_service")
  to_device=$(service_device "$to_service")
  promote "$from_service"
  if ! wait_for_uplink "$from_device" || ! wait_for_recovery >/dev/null; then
    report "INCONCLUSIVE: cycle $cycle: no working path on $from_device before switching it off"
    exit 2
  fi
  sleep "$SETTLE_SECONDS"
  networksetup -setnetworkserviceenabled "$from_service" off
  if ! wait_for_uplink "$to_device"; then
    report "INCONCLUSIVE: $to_device did not become the primary uplink after $from_service went off"
    exit 2
  fi
  if seconds=$(wait_for_recovery); then
    report "cycle $cycle: $from_service off -> $to_device recovered in ${seconds}s"
  else
    report "FAIL: cycle $cycle: $from_service off -> $to_device did not recover within ${RECOVERY_DEADLINE_SECONDS}s"
    exit 1
  fi
}

# Switches SERVICE back on and waits for its address before anything else
# goes off, so the Mac always keeps one working uplink.
restore() {
  networksetup -setnetworkserviceenabled "$1" on
  if ! wait_for_address "$(service_device "$1")"; then
    report "INCONCLUSIVE: $1 got no address within ${LINK_DEADLINE_SECONDS}s after switching it back on"
    exit 2
  fi
  sleep "$SETTLE_SECONDS"
}

ORIGINAL_INTERFACE=$(primary_interface)
ORIGINAL_SERVICE=$(service_for_device "$ORIGINAL_INTERFACE")
ALTERNATE=${ALTERNATE_SERVICE:-$(pick_alternate "$ORIGINAL_INTERFACE")}
ALTERNATE_INTERFACE=$(test -n "$ALTERNATE" && service_device "$ALTERNATE" || true)
report "primary $ORIGINAL_SERVICE ($ORIGINAL_INTERFACE), alternate ${ALTERNATE:-none} (${ALTERNATE_INTERFACE:-none})"
if [ -z "$ORIGINAL_SERVICE" ] || [ -z "$ALTERNATE_INTERFACE" ]; then
  report "INCONCLUSIVE: needs two active physical uplinks"
  exit 2
fi

BASELINE=$(probe)
if [ "$BASELINE" != 204 ]; then
  report "INCONCLUSIVE: baseline probe returned '$BASELINE'; connect AetherRoute first"
  exit 2
fi

cycle=1
while [ "$cycle" -le "$CYCLES" ]; do
  move "$ORIGINAL_SERVICE" "$ALTERNATE"
  restore "$ORIGINAL_SERVICE"
  move "$ALTERNATE" "$ORIGINAL_SERVICE"
  restore "$ALTERNATE"
  cycle=$((cycle + 1))
done

report "PASS: interface switch recovered ($CYCLES cycles, deadline ${RECOVERY_DEADLINE_SECONDS}s)"
