#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG=${1:-}
OUTPUT=${2:-}

if [ -z "$CONFIG" ] || [ -z "$OUTPUT" ]; then
  echo "usage: $0 /absolute/path/to/Signing.json /absolute/path/to/AetherRouteSigning.xcconfig" >&2
  exit 1
fi
for command in jq mktemp; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "signing override generation requires $command" >&2
    exit 1
  }
done
case "$CONFIG" in
  /*) ;;
  *) echo "signing configuration path must be absolute" >&2; exit 1 ;;
esac
case "$OUTPUT" in
  /*) ;;
  *) echo "xcconfig output path must be absolute" >&2; exit 1 ;;
esac
case "$OUTPUT" in
  "$ROOT"|"$ROOT"/*)
    echo "refusing to write organization signing overrides inside the source tree" >&2
    exit 1
    ;;
esac
[ -f "$CONFIG" ] || {
  echo "signing configuration not found: $CONFIG" >&2
  exit 1
}
[ -d "$(dirname -- "$OUTPUT")" ] || {
  echo "xcconfig output directory does not exist: $(dirname -- "$OUTPUT")" >&2
  exit 1
}

jq -e '
  .schemaVersion == 2 and
  (.teamID | test("^[A-Z0-9]{10}$")) and
  (.applicationIdentifierPrefix | test("^[A-Z0-9]{10}$")) and
  (.appGroup | test("^group\\.[A-Za-z0-9.-]+$")) and
  (.keychainAccessGroup | test("^[A-Z0-9]{10}\\.[A-Za-z0-9.-]+$")) and
  ([.profiles[].role] | sort) ==
    (["transparent-proxy", "direct-host", "packet-tunnel"] | sort) and
  (.profiles | length == 3) and
  all(.profiles[]; .bundleID | test("^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$"))
' "$CONFIG" >/dev/null || {
  echo "invalid signing configuration schema: $CONFIG" >&2
  exit 1
}

team_id=$(jq -r '.teamID' "$CONFIG")
prefix=$(jq -r '.applicationIdentifierPrefix' "$CONFIG")
app_group=$(jq -r '.appGroup' "$CONFIG")
keychain_group=$(jq -r '.keychainAccessGroup' "$CONFIG")
host_bundle=$(jq -r '.profiles[] | select(.role == "direct-host") | .bundleID' "$CONFIG")
transparent_bundle=$(jq -r '.profiles[] | select(.role == "transparent-proxy") | .bundleID' "$CONFIG")
tunnel_bundle=$(jq -r '.profiles[] | select(.role == "packet-tunnel") | .bundleID' "$CONFIG")

[ "$transparent_bundle" = "$host_bundle.transparent-proxy" ] || {
  echo "Transparent Proxy bundle identifier must be $host_bundle.transparent-proxy" >&2
  exit 1
}
[ "$tunnel_bundle" = "$host_bundle.tunnel" ] || {
  echo "Packet Tunnel bundle identifier must be $host_bundle.tunnel" >&2
  exit 1
}
[ "$app_group" = "group.$host_bundle" ] || {
  echo "App Group must be group.$host_bundle" >&2
  exit 1
}
[ "$keychain_group" = "$prefix.$host_bundle.shared" ] || {
  echo "Keychain group must be $prefix.$host_bundle.shared" >&2
  exit 1
}
[ "$team_id" = "$prefix" ] || {
  echo "this release layout requires Team ID and App Identifier Prefix to match" >&2
  exit 1
}
case "$host_bundle $app_group $keychain_group" in
  *example*|*yourcompany*)
    echo "signing identifiers still contain example values" >&2
    exit 1
    ;;
esac

umask 077
temporary=$(mktemp "$(dirname -- "$OUTPUT")/.aetherroute-signing.XXXXXX")
cleanup() {
  if [ -f "$temporary" ]; then
    find "$temporary" -delete
  fi
}
trap cleanup EXIT HUP INT TERM

{
  printf '%s\n' '// Generated from a validated external Signing.json. Do not commit.'
  printf 'AETHERROUTE_DEVELOPMENT_TEAM = %s\n' "$team_id"
  printf 'AETHERROUTE_BUNDLE_ID = %s\n' "$host_bundle"
  printf 'AETHERROUTE_TUNNEL_BUNDLE_ID = %s\n' "$tunnel_bundle"
  printf 'AETHERROUTE_TRANSPARENT_PROXY_BUNDLE_ID = %s\n' "$transparent_bundle"
  printf 'AETHERROUTE_APP_GROUP = %s\n' "$app_group"
  printf 'AETHERROUTE_KEYCHAIN_GROUP_SUFFIX = %s.shared\n' "$host_bundle"
  printf 'AETHERROUTE_PROFILE_ARCHIVE_TYPE = %s.profile-archive\n' "$host_bundle"
  printf 'AETHERROUTE_SUBSCRIPTION_URL_NAME = %s.subscription\n' "$host_bundle"
} >"$temporary"
chmod 600 "$temporary"
mv -f "$temporary" "$OUTPUT"
trap - EXIT HUP INT TERM

echo "Signing overrides generated at $OUTPUT (mode 600). No profile was installed and no app was signed."
