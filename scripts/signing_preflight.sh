#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG=${1:-}
FAILURES=0

fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

note() {
  echo "INFO: $*"
}

for command in plutil security; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "signing preflight requires $command" >&2
    exit 1
  fi
done

identity_output=$(security find-identity -v -p codesigning 2>&1 || true)
identity_count=$(printf '%s\n' "$identity_output" \
  | awk '/valid identities found/ { print $1; found = 1 } END { if (!found) print 0 }')
note "valid code-signing identities: $identity_count"

home_directory=$(cd && pwd -P)
profile_count=0
for profile_directory in \
  "$home_directory/Library/MobileDevice/Provisioning Profiles" \
  "$home_directory/Library/Developer/Xcode/UserData/Provisioning Profiles"
do
  if [ -d "$profile_directory" ]; then
    count=0
    for profile in \
      "$profile_directory"/*.provisionprofile \
      "$profile_directory"/*.mobileprovision
    do
      if [ -f "$profile" ]; then
        count=$((count + 1))
      fi
    done
    profile_count=$((profile_count + count))
  fi
done
note "locally installed provisioning profiles: $profile_count"

if [ -z "$CONFIG" ]; then
  if grep -En 'com\.example\.aetherroute|DEVELOPMENT_TEAM:[[:space:]]*""' \
    "$ROOT/project.yml" \
    "$ROOT/Config"/*.entitlements \
    "$ROOT/Config"/*-Info.plist \
    "$ROOT/Sources/AetherRouteKit/TunnelConfiguration.swift" \
    "$ROOT/Sources/AetherRouteApp/ProfileArchiveTransfer.swift" \
    >/dev/null; then
    fail "production signing surfaces still contain placeholder identifiers"
  fi
  if [ "$identity_count" -eq 0 ]; then
    fail "no valid code-signing identity is available"
  fi
  if [ "$profile_count" -eq 0 ]; then
    fail "no provisioning profile is installed"
  fi
  echo "Signing inventory complete. Pass a populated Signing.example.json copy for strict profile validation."
  if [ "$FAILURES" -ne 0 ]; then
    echo "Signing preflight failed: failures=$FAILURES" >&2
    exit 2
  fi
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "strict signing preflight requires jq" >&2
  exit 1
fi

case "$CONFIG" in
  /*) ;;
  *) CONFIG="$PWD/$CONFIG" ;;
esac
if [ ! -f "$CONFIG" ]; then
  echo "signing configuration not found: $CONFIG" >&2
  exit 1
fi

jq -e '
  .schemaVersion == 2 and
  (.teamID | test("^[A-Z0-9]{10}$")) and
  (.applicationIdentifierPrefix | test("^[A-Z0-9]{10}$")) and
  (.appGroup | test("^group\\.[A-Za-z0-9.-]+$")) and
  (.keychainAccessGroup | test("^[A-Z0-9]{10}\\.[A-Za-z0-9.-]+$")) and
  (.developerIDIdentitySHA1 | test("^[A-Fa-f0-9]{40}$")) and
  ([.profiles[].role] | sort) ==
    (["transparent-proxy", "direct-host", "packet-tunnel"] | sort) and
  (.profiles | length == 3) and
  all(.profiles[];
    (.bundleID | test("^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$")) and
    (.path | startswith("/")) and
    (.networkExtensions | type == "array" and length > 0) and
    all(.networkExtensions[];
      . == "app-proxy-provider" or . == "packet-tunnel-provider")
  )
' "$CONFIG" >/dev/null || {
  echo "invalid signing configuration schema: $CONFIG" >&2
  exit 1
}

team_id=$(jq -r '.teamID' "$CONFIG")
app_identifier_prefix=$(jq -r '.applicationIdentifierPrefix' "$CONFIG")
app_group=$(jq -r '.appGroup' "$CONFIG")
keychain_group=$(jq -r '.keychainAccessGroup' "$CONFIG")
developer_id_identity=$(jq -r '.developerIDIdentitySHA1 | ascii_upcase' "$CONFIG")

if [ "$developer_id_identity" = 0000000000000000000000000000000000000000 ]; then
  fail "developerIDIdentitySHA1 is still the example value"
elif ! printf '%s\n' "$identity_output" | grep -F "$developer_id_identity" \
  | grep -F 'Developer ID Application' >/dev/null; then
  fail "configured Developer ID Application identity is unavailable or has the wrong type"
fi

if printf '%s\n' "$app_group $keychain_group" | grep -F 'yourcompany' >/dev/null; then
  fail "signing identifiers still contain the example organization"
fi

repo_identity_files="
$ROOT/project.yml
$ROOT/Config/AetherRoute.entitlements
$ROOT/Config/AetherRoutePacketTunnel.entitlements
$ROOT/Config/AetherRouteTransparentProxy.entitlements
$ROOT/Config/App-Info.plist
$ROOT/Config/PacketTunnel-Info.plist
$ROOT/Config/TransparentProxy-Info.plist
$ROOT/Sources/AetherRouteKit/TunnelConfiguration.swift
$ROOT/Sources/AetherRouteApp/ProfileArchiveTransfer.swift
"
decoded_directory=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-signing-preflight.XXXXXX")
cleanup() {
  if [ -d "$decoded_directory" ]; then
    find "$decoded_directory" -depth -delete
  fi
}
trap cleanup EXIT HUP INT TERM

overrides="$decoded_directory/AetherRouteSigning.xcconfig"
if ! "$ROOT/scripts/generate_signing_overrides.sh" \
  "$CONFIG" "$overrides" >/dev/null; then
  fail "release signing overrides could not be generated"
else
  grep -qx "AETHERROUTE_DEVELOPMENT_TEAM = $team_id" "$overrides" || \
    fail "generated development team does not match signing configuration"
  grep -qx "AETHERROUTE_APP_GROUP = $app_group" "$overrides" || \
    fail "generated App Group does not match signing configuration"
  grep -qx "AETHERROUTE_KEYCHAIN_GROUP_SUFFIX = ${keychain_group#*.}" \
    "$overrides" || \
    fail "generated Keychain suffix does not match signing configuration"
fi

grep -F 'DEVELOPMENT_TEAM: $(AETHERROUTE_DEVELOPMENT_TEAM)' \
  "$ROOT/project.yml" >/dev/null || \
  fail "project development team is not parameterized"
grep -F 'PRODUCT_BUNDLE_IDENTIFIER: $(AETHERROUTE_BUNDLE_ID)' \
  "$ROOT/project.yml" >/dev/null || \
  fail "host bundle identifier is not parameterized"
for entitlements in \
  "$ROOT/Config/AetherRoute.entitlements" \
  "$ROOT/Config/AetherRoutePacketTunnel.entitlements" \
  "$ROOT/Config/AetherRouteTransparentProxy.entitlements"
do
  grep -F '$(AETHERROUTE_APP_GROUP)' "$entitlements" >/dev/null || \
    fail "App Group is not parameterized in $entitlements"
  grep -F '$(AETHERROUTE_KEYCHAIN_GROUP_SUFFIX)' "$entitlements" >/dev/null || \
    fail "Keychain group is not parameterized in $entitlements"
done
if grep -En 'com\.example\.aetherroute' \
  "$ROOT/Sources/AetherRouteKit/TunnelConfiguration.swift" \
  "$ROOT/Sources/AetherRouteApp/ProfileArchiveTransfer.swift" >/dev/null; then
  fail "runtime signing identifiers remain hard-coded in Swift"
fi

profile_rows_file="$decoded_directory/profile-rows.tsv"
jq -r '.profiles[] | [
  .role,
  .bundleID,
  .path,
  (.networkExtensions | join(","))
] | @tsv' "$CONFIG" >"$profile_rows_file"

while IFS="	" read -r role bundle_id profile_path network_extensions; do
  if printf '%s\n' "$bundle_id" | grep -F 'yourcompany' >/dev/null; then
    fail "$role bundleID is still the example value"
    continue
  fi
  if [ ! -f "$profile_path" ]; then
    fail "$role provisioning profile is missing: $profile_path"
    continue
  fi

  decoded="$decoded_directory/$role.plist"
  if ! security cms -D -i "$profile_path" >"$decoded" 2>/dev/null; then
    fail "$role provisioning profile cannot be decoded"
    continue
  fi
  if ! plutil -lint "$decoded" >/dev/null; then
    fail "$role provisioning profile payload is not a valid plist"
    continue
  fi

  actual_team=$(plutil -extract TeamIdentifier.0 raw -o - "$decoded" 2>/dev/null || true)
  actual_prefix=$(plutil -extract ApplicationIdentifierPrefix.0 raw -o - "$decoded" 2>/dev/null || true)
  actual_app_id=$(plutil -extract Entitlements.application-identifier raw -o - "$decoded" 2>/dev/null || true)
  actual_team_entitlement=$(plutil -extract Entitlements.com.apple.developer.team-identifier raw -o - "$decoded" 2>/dev/null || true)
  expiration=$(plutil -extract ExpirationDate raw -o - "$decoded" 2>/dev/null || true)

  [ "$actual_team" = "$team_id" ] || fail "$role profile TeamIdentifier mismatch"
  [ "$actual_prefix" = "$app_identifier_prefix" ] || fail "$role profile AppIdentifierPrefix mismatch"
  [ "$actual_team_entitlement" = "$team_id" ] || fail "$role profile team entitlement mismatch"
  [ "$actual_app_id" = "$app_identifier_prefix.$bundle_id" ] || fail "$role profile application-identifier mismatch"

  if [ -z "$expiration" ]; then
    fail "$role profile has no expiration date"
  else
    expiration_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' \
      "$expiration" '+%s' 2>/dev/null \
      || date -j -f '%Y-%m-%d %H:%M:%S %z' \
        "$expiration" '+%s' 2>/dev/null \
      || echo 0)
    now_epoch=$(date '+%s')
    if [ "$expiration_epoch" -le "$now_epoch" ]; then
      fail "$role profile is expired or has an unreadable expiration date"
    fi
  fi

  if ! plutil -extract Entitlements.com.apple.security.application-groups json -o - "$decoded" 2>/dev/null \
    | jq -e --arg expected "$app_group" 'index($expected) != null' >/dev/null; then
    fail "$role profile does not grant App Group $app_group"
  fi
  if ! plutil -extract Entitlements.keychain-access-groups json -o - "$decoded" 2>/dev/null \
    | jq -e --arg expected "$keychain_group" 'index($expected) != null' >/dev/null; then
    fail "$role profile does not grant Keychain group $keychain_group"
  fi

  for network_extension in $(printf '%s\n' "$network_extensions" | tr ',' ' '); do
    if ! plutil -extract Entitlements.com.apple.developer.networking.networkextension json -o - "$decoded" 2>/dev/null \
      | jq -e --arg expected "$network_extension" 'index($expected) != null' >/dev/null; then
      fail "$role profile does not grant Network Extension $network_extension"
    fi
  done

  note "$role profile decoded and matched: bundle=$bundle_id expires=$expiration"
done <"$profile_rows_file"

if [ "$FAILURES" -ne 0 ]; then
  echo "Signing preflight failed: failures=$FAILURES" >&2
  exit 2
fi

echo "Signing preflight passed for the Developer ID host and both Network Extensions. No profile was installed and no app was signed."
