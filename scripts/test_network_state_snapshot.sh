#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=scripts/network_state_snapshot.sh
. "$ROOT/scripts/network_state_snapshot.sh"

fail() {
  echo "network state snapshot test failed: $1" >&2
  exit 1
}

# CoreDevice tunnels come and go; the snapshot must not notice them.
routes_without_tunnel=$(printf '%s\n' \
  'Destination Gateway Flags Netif Expire' \
  'default fe80::1%en0 UGcg en0' \
  'default fd7a:115c:a1e0:: UGcIg utun3' | filter_ipv6_default_routes)
routes_with_tunnel=$(printf '%s\n' \
  'Destination Gateway Flags Netif Expire' \
  'default fe80::1%en0 UGcg en0' \
  'default fd7a:115c:a1e0:: UGcIg utun3' \
  'default fd47:5cc8:3709:: UGcIg utun9' \
  'default FDCE:EF46:FCB7:: UGcIg utun12' | filter_ipv6_default_routes)
[ "$routes_without_tunnel" = "$routes_with_tunnel" ] || fail "a utun fd00::/8 default route changed the snapshot"
[ "$routes_with_tunnel" = "default fe80::1%en0 UGcg en0" ] || fail "unexpected IPv6 routes: $routes_with_tunnel"

# Any other default route change is still reported.
changed=$(printf '%s\n' 'default 2001:db8::1 UGcg en0' | filter_ipv6_default_routes)
[ "$changed" = "default 2001:db8::1 UGcg en0" ] || fail "a global IPv6 default route was dropped"
via_ethernet=$(printf '%s\n' 'default fd00::1 UGcg en0' | filter_ipv6_default_routes)
[ "$via_ethernet" = "default fd00::1 UGcg en0" ] || fail "a ULA route over Ethernet was dropped"

before=$(printf 'lo0 en0 utun4 bridge100\n' | filter_interface_names)
after=$(printf 'lo0 en0 utun4 bridge100 utun9\n' | filter_interface_names)
[ "$before" = "$after" ] || fail "a new utun changed the interface list"
added=$(printf 'lo0 en0 bridge100 en19\n' | filter_interface_names)
[ "$before" != "$added" ] || fail "a new physical interface went unnoticed"

# A Tart VM starting or stopping adds or removes vmenetN, a bridge1NN and a
# default route scoped to that bridge (flag I). That must not fail a
# candidate build that overlaps the VM matrix.
v4_without_vm=$(printf '%s\n' \
  'Destination Gateway Flags Netif Expire' \
  'default 172.20.10.1 UGScg en0' | filter_ipv4_default_routes)
v4_with_vm=$(printf '%s\n' \
  'Destination Gateway Flags Netif Expire' \
  'default 172.20.10.1 UGScg en0' \
  'default link#31 UCSIg bridge100 !' | filter_ipv4_default_routes)
[ "$v4_without_vm" = "$v4_with_vm" ] || fail "a VM bridge's scoped default route changed the snapshot"
unscoped_bridge=$(printf '%s\n' 'default link#31 UCSg bridge100' | filter_ipv4_default_routes)
[ -n "$unscoped_bridge" ] || fail "an unscoped default route over a bridge was dropped"
scoped_physical=$(printf '%s\n' 'default 192.168.50.1 UGScIg en1' | filter_ipv4_default_routes)
[ -n "$scoped_physical" ] || fail "a scoped default route on a physical interface was dropped"
moved=$(printf '%s\n' 'default 10.0.0.1 UGScg en1' | filter_ipv4_default_routes)
[ "$moved" != "$v4_without_vm" ] || fail "a default route change went unnoticed"

no_vm=$(printf 'lo0 en0 bridge0 awdl0\n' | filter_interface_names)
with_vm=$(printf 'lo0 en0 bridge0 awdl0 vmenet0 bridge100 vmenet1 bridge101\n' | filter_interface_names)
[ "$no_vm" = "$with_vm" ] || fail "VM vmenet/bridge1NN interfaces changed the interface list"
thunderbolt=$(printf 'lo0 en0 bridge0 awdl0 bridge1\n' | filter_interface_names)
[ "$no_vm" != "$thunderbolt" ] || fail "a new non-VM bridge went unnoticed"

# The executable form prints a non-empty snapshot on this host.
sh "$ROOT/scripts/network_state_snapshot.sh" | grep -q . || fail "no snapshot printed"

echo "Network state snapshot ignores CoreDevice tunnels and still reports other changes."
