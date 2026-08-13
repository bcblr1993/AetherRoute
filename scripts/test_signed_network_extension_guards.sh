#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/test_signed_network_extension.sh"
WATCHDOG="$ROOT/scripts/signed_ne_control_watchdog.sh"
WATCHDOG_TEST="$ROOT/scripts/test_signed_ne_control_watchdog.sh"
DNS_PROBE="$ROOT/scripts/signed_ne_dns_probe.sh"
DNS_PROBE_TEST="$ROOT/scripts/test_signed_ne_dns_probe.sh"
TUN_SERVICE_RESOLVER="$ROOT/scripts/signed_ne_tun_service_resolver.sh"
UI_TEST="$ROOT/Tests/AetherRouteUITests/AetherRouteUITests.swift"

sh -n "$SCRIPT"
sh -n "$WATCHDOG"
sh -n "$WATCHDOG_TEST"
sh -n "$DNS_PROBE"
sh -n "$DNS_PROBE_TEST"
sh -n "$TUN_SERVICE_RESOLVER"
for required in \
  'AETHERROUTE_SIGNED_NE_ENGINES' \
  'AETHERROUTE_SIGNED_NE_ENGINE' \
  'AETHERROUTE_SIGNED_PROBE_URL' \
  'AETHERROUTE_SIGNED_PROBE_SHA256' \
  'AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY' \
  'AETHERROUTE_SIGNED_NE_BYPASS_CIDRS' \
  'AETHERROUTE_SIGNED_NE_CONTROL_PEER' \
  'AETHERROUTE_SIGNED_NE_CONTROL_TIMEOUT_SECONDS' \
  'AETHERROUTE_SIGNED_DNS_PROBE_SCRIPT' \
  'AETHERROUTE_SIGNED_DNS_PROBE_SHA256' \
  'dns_gate_schema=public-best-effort-v1' \
  'dns_claim_level=resolver-control+synthetic-stub-data-plane' \
  'dns_upstream_path=not-verified' \
  'dns_no_leak=not-verified' \
  'valid_ipv4_bypass_cidr' \
  'ipv4_cidr_contains' \
  'IPv4 /8 through /32 routes' \
  'must be covered by AETHERROUTE_SIGNED_NE_BYPASS_CIDRS' \
  'signed_ne_control_watchdog.sh' \
  'BASELINE_MAGIC_DNS_INTERFACE' \
  'safe_stop_aetherroute_tun' \
  'EXPECTED_TUN_SERVICE_NAME=AetherRoute' \
  'signed_ne_tun_service_resolver.sh' \
  'refusing to stop an unverified AetherRoute TUN service' \
  '/usr/sbin/scutil --nc stop' \
  'control_watchdog_interval_seconds=2' \
  'control_watchdog_failure_limit=5' \
  'control_peer_route_and_direct_ping=passed' \
  '--until-direct=true' \
  'tailscale_magic_dns_route=passed' \
  'TAILSCALE_MAGIC_DNS=100.100.100.100' \
  'AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST' \
  'AETHERROUTE_SIGNED_NE_ALLOW_LOCAL_CANDIDATE' \
  'source_manifest_sha256' \
  'raw_xcresult_retained=no' \
  'probe_url_retained=no' \
  'System proxy/DNS/default-route/interface state was not restored' \
  'signed Network Extension gate always uses disposable DerivedData' \
  '$EXPECTED_PACKET_BUNDLE.systemextension' \
  '$EXPECTED_TRANSPARENT_BUNDLE.systemextension' \
  'packet-tunnel-provider' \
  'app-proxy-provider' \
  'Developer ID Application' \
  'signed host must not carry network.server' \
  'network.server escaped the signed Network Extension boundary'
do
  grep -F -- "$required" "$SCRIPT" >/dev/null || {
    echo "signed Network Extension gate is missing guard: $required" >&2
    exit 1
  }
done
for resolver_required in \
  '[VPN:$HOST_BUNDLE]' \
  '"$SCUTIL_COMMAND" --nc list' \
  '"$SCUTIL_COMMAND" --nc show "$service_id"' \
  'NEProviderBundleIdentifier' \
  'RemoteAddress' \
  'Local packet tunnel' \
  'matching_lines != 1' \
  'provider_count != 1' \
  'remote_count != 1'
do
  grep -F -- "$resolver_required" "$TUN_SERVICE_RESOLVER" >/dev/null || {
    echo "signed TUN service resolver is missing guard: $resolver_required" >&2
    exit 1
  }
done
if grep -Eq -- '--nc[[:space:]]+(start|stop|suspend|resume|select|enablevpn|disablevpn)' \
  "$TUN_SERVICE_RESOLVER"; then
  echo "signed TUN service resolver must remain read-only" >&2
  exit 1
fi
for watchdog_required in \
  'MAGIC_DNS_ADDRESS' \
  'BASELINE_MAGIC_DNS_INTERFACE' \
  'magic_dns_route_is_unchanged'
do
  grep -F -- "$watchdog_required" "$WATCHDOG" >/dev/null || {
    echo "control-peer watchdog is missing guard: $watchdog_required" >&2
    exit 1
  }
done
grep -F "'com\\.apple\\.developer\\.networking\\.networkextension'" \
  "$SCRIPT" >/dev/null || {
  echo "signed Network Extension gate must escape dotted plist keys" >&2
  exit 1
}
grep -F 'must include both tun and transparent' "$SCRIPT" >/dev/null || {
  echo "signed Network Extension gate does not require both engines" >&2
  exit 1
}
grep -F 'configuration.connectionProxyDictionary = [:]' "$UI_TEST" \
  >/dev/null || {
  echo "signed Network Extension canary must bypass the existing system proxy" >&2
  exit 1
}
grep -F 'APP=/Applications/AetherRoute.app' "$SCRIPT" >/dev/null || {
  echo "real Network Extension gate must test the installed Developer ID app" >&2
  exit 1
}
grep -F 'signed-local-test-candidate:YES' "$SCRIPT" \
  >/dev/null || {
  echo "real Network Extension gate must explicitly separate local and notarized candidates" >&2
  exit 1
}
grep -F 'EXPECTED_CDHASH' "$SCRIPT" >/dev/null || {
  echo "real Network Extension gate must bind a local installed app by CDHash" >&2
  exit 1
}
grep -F 'installTemporarySignedBypassRules' "$UI_TEST" >/dev/null || {
  echo "signed Network Extension gate must protect an existing proxy client" >&2
  exit 1
}
for dns_ui_required in \
  'validatedSignedDNSProbeScript' \
  'runSignedDNSProbe' \
  'tun-connected' \
  'transparent-connected' \
  'disconnected'
do
  grep -F -- "$dns_ui_required" "$UI_TEST" >/dev/null || {
    echo "signed Network Extension UI gate is missing DNS guard: $dns_ui_required" >&2
    exit 1
  }
done

GUARD_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-signed-ne-guards.XXXXXX")
trap 'find "$GUARD_TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
CANDIDATE="$GUARD_TEMP/candidate.json"
: >"$CANDIDATE"

SCUTIL_LIST="$GUARD_TEMP/scutil-list.txt"
SCUTIL_SHOW="$GUARD_TEMP/scutil-show.txt"
SCUTIL_MOCK="$GUARD_TEMP/scutil-mock"
AETHERROUTE_SERVICE_ID=11111111-2222-3333-4444-555555555555
SECOND_AETHERROUTE_SERVICE_ID=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
TAILSCALE_SERVICE_ID=99999999-8888-7777-6666-555555555555
printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'case "${1:-}:${2:-}" in' \
  '  --nc:list)' \
  '    exec /bin/cat "${AETHERROUTE_TEST_SCUTIL_LIST:?}"' \
  '    ;;' \
  '  --nc:show)' \
  '    test "${3:-}" = "${AETHERROUTE_TEST_SCUTIL_SERVICE:?}" || exit 91' \
  '    exec /bin/cat "${AETHERROUTE_TEST_SCUTIL_SHOW:?}"' \
  '    ;;' \
  '  *) exit 92 ;;' \
  'esac' >"$SCUTIL_MOCK"
chmod 755 "$SCUTIL_MOCK"

write_resolver_list() {
  second_service=${1:-NO}
  service_name=${2:-AetherRoute}
  printf '%s\n' \
    'Available network connection services in the current set (*=enabled):' \
    "* (Connected) $TAILSCALE_SERVICE_ID VPN (io.tailscale.ipn.macsys) \"Tailscale\" [VPN:io.tailscale.ipn.macsys]" \
    "* (Disconnected) $AETHERROUTE_SERVICE_ID VPN (com.aetherroute.desktop) \"$service_name\" [VPN:com.aetherroute.desktop]" \
    >"$SCUTIL_LIST"
  if [ "$second_service" = YES ]; then
    printf '%s\n' \
      "* (Disconnected) $SECOND_AETHERROUTE_SERVICE_ID VPN (com.aetherroute.desktop) \"AetherRoute\" [VPN:com.aetherroute.desktop]" \
      >>"$SCUTIL_LIST"
  fi
}

write_resolver_show() {
  provider_bundle=$1
  remote_address=$2
  printf '%s\n' \
    '<dictionary> {' \
    "  NEProviderBundleIdentifier : $provider_bundle" \
    "  RemoteAddress : $remote_address" \
    '}' >"$SCUTIL_SHOW"
}

resolve_service_fixture() {
  AETHERROUTE_TEST_SCUTIL_LIST="$SCUTIL_LIST" \
  AETHERROUTE_TEST_SCUTIL_SHOW="$SCUTIL_SHOW" \
  AETHERROUTE_TEST_SCUTIL_SERVICE="$AETHERROUTE_SERVICE_ID" \
  "$TUN_SERVICE_RESOLVER" \
    com.aetherroute.desktop \
    com.aetherroute.desktop.tunnel \
    AetherRoute \
    "$SCUTIL_MOCK"
}

write_resolver_list
write_resolver_show com.aetherroute.desktop.tunnel 'Local packet tunnel'
resolved_service=$(resolve_service_fixture)
test "$resolved_service" = "$AETHERROUTE_SERVICE_ID" || {
  echo "signed TUN resolver did not select the exact AetherRoute service" >&2
  exit 1
}
test "$resolved_service" != "$TAILSCALE_SERVICE_ID" || {
  echo "signed TUN resolver selected Tailscale" >&2
  exit 1
}

printf '%s\n' \
  'Available network connection services in the current set (*=enabled):' \
  "* (Connected) $TAILSCALE_SERVICE_ID VPN (io.tailscale.ipn.macsys) \"Tailscale\" [VPN:io.tailscale.ipn.macsys]" \
  >"$SCUTIL_LIST"
if resolve_service_fixture >/dev/null 2>&1; then
  echo "signed TUN resolver accepted zero AetherRoute services" >&2
  exit 1
fi

write_resolver_list YES
if resolve_service_fixture >/dev/null 2>&1; then
  echo "signed TUN resolver accepted multiple AetherRoute services" >&2
  exit 1
fi

write_resolver_list NO 'AetherRoute Tunnel'
if resolve_service_fixture >/dev/null 2>&1; then
  echo "signed TUN resolver accepted a non-exact service name" >&2
  exit 1
fi

write_resolver_list
write_resolver_show com.aetherroute.desktop.not-tunnel 'Local packet tunnel'
if resolve_service_fixture >/dev/null 2>&1; then
  echo "signed TUN resolver accepted the wrong packet provider" >&2
  exit 1
fi

write_resolver_show com.aetherroute.desktop.tunnel 'Not local packet tunnel'
if resolve_service_fixture >/dev/null 2>&1; then
  echo "signed TUN resolver accepted the wrong remote address" >&2
  exit 1
fi

write_resolver_show com.aetherroute.desktop.tunnel 'Local packet tunnel'
printf '%s\n' \
  '  NEProviderBundleIdentifier : com.aetherroute.desktop.tunnel' \
  >>"$SCUTIL_SHOW"
if resolve_service_fixture >/dev/null 2>&1; then
  echo "signed TUN resolver accepted duplicate packet-provider fields" >&2
  exit 1
fi

printf '%s\n' \
  '<dictionary> {' \
  '  NEProviderBundleIdentifier : com.aetherroute.desktop.tunnel' \
  '}' >"$SCUTIL_SHOW"
if resolve_service_fixture >/dev/null 2>&1; then
  echo "signed TUN resolver accepted a missing remote address" >&2
  exit 1
fi

preflight_output() {
  bypass_cidrs=$1
  control_peer=$2
  AETHERROUTE_ALLOW_REAL_NETWORK_TEST=YES \
  AETHERROUTE_SIGNED_PROFILE_READY=YES \
  AETHERROUTE_NETWORK_TEST_HOST=guard-host-must-not-match \
  AETHERROUTE_SIGNED_PROBE_URL=https://canary.example/proxy-only \
  AETHERROUTE_SIGNED_PROBE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY="$GUARD_TEMP/evidence" \
  AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST="$CANDIDATE" \
  AETHERROUTE_SIGNED_NE_BYPASS_CIDRS="$bypass_cidrs" \
  AETHERROUTE_SIGNED_NE_CONTROL_PEER="$control_peer" \
  "$SCRIPT" /nonexistent/signing.json 2>&1 || true
}

missing_peer_output=$(preflight_output 100.64.0.0/10 '')
printf '%s\n' "$missing_peer_output" \
  | grep -F 'set AETHERROUTE_SIGNED_NE_CONTROL_PEER' >/dev/null || {
  echo "signed Network Extension gate accepted a missing control peer" >&2
  exit 1
}

uncovered_peer_output=$(preflight_output 10.0.0.0/8 100.64.0.1)
printf '%s\n' "$uncovered_peer_output" \
  | grep -F 'must be covered by AETHERROUTE_SIGNED_NE_BYPASS_CIDRS' \
    >/dev/null || {
  echo "signed Network Extension gate accepted an unprotected control peer" >&2
  exit 1
}

too_broad_output=$(preflight_output 100.0.0.0/7 100.64.0.1)
printf '%s\n' "$too_broad_output" \
  | grep -F 'IPv4 /8 through /32 routes' >/dev/null || {
  echo "signed Network Extension gate accepted an overly broad bypass CIDR" >&2
  exit 1
}

for covered_cidr in 100.0.0.0/8 100.64.0.1/32; do
  covered_output=$(preflight_output "$covered_cidr" 100.64.0.1)
  printf '%s\n' "$covered_output" \
    | grep -F 'refusing real Network Extension test on' >/dev/null || {
    echo "signed Network Extension gate rejected supported bypass CIDR $covered_cidr" >&2
    exit 1
  }
done

if AETHERROUTE_ALLOW_REAL_NETWORK_TEST=NO \
  AETHERROUTE_SIGNED_PROBE_URL=https://canary.example/proxy-only \
  AETHERROUTE_SIGNED_PROBE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$SCRIPT" /nonexistent/signing.json >/dev/null 2>&1; then
  echo "signed Network Extension gate ran without explicit real-network opt-in" >&2
  exit 1
fi

"$WATCHDOG_TEST"
"$DNS_PROBE_TEST"

echo "Signed dual-engine Network Extension guard tests passed."
