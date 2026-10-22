#!/bin/sh
# Prints the host network state a candidate build must leave unchanged:
# proxies, DNS, default routes and interfaces.
#
# Xcode's CoreDevice opens and closes a utun tunnel to each network-paired
# device every 20-40 seconds, each with a random fd00::/8 default route
# (seen 2026-10-22, failing two 1.8.7 notarized builds). Those tunnels say
# nothing about the build, so utun names and fd00::/8 default routes through
# a utun are left out. Proxies, DNS, IPv4 default routes (an AetherRoute
# reconnect changes its utun route) and all other IPv6 routes still compare.
#
# Sourced for its filters by scripts/test_network_state_snapshot.sh;
# executed to print the snapshot.

filter_ipv6_default_routes() {
  awk '$1 == "default" && !($4 ~ /^utun[0-9]+$/ && tolower($2) ~ /^fd/) {print}'
}

filter_interface_names() {
  tr ' ' '\n' | grep -v '^utun[0-9][0-9]*$' | grep -v '^$' | tr '\n' ' '
  echo
}

network_state_snapshot() {
  /usr/sbin/scutil --proxy
  /usr/sbin/scutil --dns
  /usr/sbin/netstat -rn -f inet | awk '$1 == "default" {print}'
  /usr/sbin/netstat -rn -f inet6 | filter_ipv6_default_routes
  /sbin/ifconfig -l | filter_interface_names
}

if [ "${0##*/}" = network_state_snapshot.sh ]; then
  set -eu
  network_state_snapshot
fi
