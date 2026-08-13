#!/bin/sh
set -eu

# Resolve only the packet-tunnel service owned by the installed AetherRoute
# host. This helper is deliberately read-only; the signed gate performs the
# stop only after this resolver returns one strictly verified service UUID.
HOST_BUNDLE=${1:-}
PACKET_BUNDLE=${2:-}
SERVICE_NAME=${3:-}
SCUTIL_COMMAND=${4:-/usr/sbin/scutil}

fail() {
  echo "AetherRoute TUN service resolution failed: $*" >&2
  exit 1
}

for bundle_identifier in "$HOST_BUNDLE" "$PACKET_BUNDLE"; do
  printf '%s\n' "$bundle_identifier" \
    | grep -Eq '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' \
    || fail "bundle identifier is invalid"
done
test "$SERVICE_NAME" = AetherRoute \
  || fail "service name must be the exact AetherRoute name"
case "$SCUTIL_COMMAND" in
  /*) ;;
  *) fail "scutil command must be absolute" ;;
esac
test -x "$SCUTIL_COMMAND" || fail "scutil command is not executable"

service_list=$("$SCUTIL_COMMAND" --nc list 2>/dev/null) \
  || fail "could not read network connection services"
service_id=$(printf '%s\n' "$service_list" | awk \
  -v marker="[VPN:$HOST_BUNDLE]" \
  -v quoted_name="\"$SERVICE_NAME\"" '
    index($0, marker) && index($0, quoted_name) {
      matching_lines++
      found_uuid = 0
      for (field_index = 1; field_index <= NF; field_index++) {
        candidate = $field_index
        part_count = split(candidate, parts, "-")
        if (part_count == 5 && length(parts[1]) == 8 &&
            length(parts[2]) == 4 && length(parts[3]) == 4 &&
            length(parts[4]) == 4 && length(parts[5]) == 12 &&
            candidate ~ /^[0-9A-Fa-f-]+$/) {
          found_uuid++
          resolved_uuid = candidate
        }
      }
      if (found_uuid != 1) malformed_lines++
    }
    END {
      if (matching_lines != 1 || malformed_lines != 0) exit 1
      print resolved_uuid
    }
  ') || fail "host bundle and service name did not resolve uniquely"

service_show=$("$SCUTIL_COMMAND" --nc show "$service_id" 2>/dev/null) \
  || fail "could not inspect the resolved network connection service"
printf '%s\n' "$service_show" | awk \
  -v expected_provider="$PACKET_BUNDLE" \
  -v expected_remote="Local packet tunnel" '
    function normalized(value) {
      gsub(/^[[:space:]]+/, "", value)
      gsub(/[[:space:]]+$/, "", value)
      gsub(/[[:space:]]+/, " ", value)
      return value
    }
    $1 == "NEProviderBundleIdentifier" {
      provider_count++
      if (normalized($0) == "NEProviderBundleIdentifier : " expected_provider) {
        provider_matches++
      }
    }
    $1 == "RemoteAddress" {
      remote_count++
      if (normalized($0) == "RemoteAddress : " expected_remote) {
        remote_matches++
      }
    }
    END {
      if (provider_count != 1 || provider_matches != 1 ||
          remote_count != 1 || remote_matches != 1) exit 1
    }
  ' || fail "resolved service is not the exact local AetherRoute packet tunnel"

printf '%s\n' "$service_id"
