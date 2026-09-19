#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DNS_PROBE_SCRIPT="$ROOT/scripts/signed_ne_dns_probe.sh"
SIGNING_CONFIG=${1:-}
PRODUCT=independent
CYCLES=${AETHERROUTE_SIGNED_NE_CYCLES:-3}
ENGINES=${AETHERROUTE_SIGNED_NE_ENGINES:-tun,transparent}
EXPECTED_HOST=${AETHERROUTE_NETWORK_TEST_HOST:-}
PROBE_URL=${AETHERROUTE_SIGNED_PROBE_URL:-}
PROBE_SHA256=${AETHERROUTE_SIGNED_PROBE_SHA256:-}
EVIDENCE_DIRECTORY=${AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY:-}
BYPASS_CIDRS=${AETHERROUTE_SIGNED_NE_BYPASS_CIDRS:-}
CONTROL_PEER=${AETHERROUTE_SIGNED_NE_CONTROL_PEER:-}
CONTROL_TIMEOUT_SECONDS=${AETHERROUTE_SIGNED_NE_CONTROL_TIMEOUT_SECONDS:-}
TAILSCALE_CLI=${AETHERROUTE_SIGNED_NE_TAILSCALE_CLI:-}
CANDIDATE_MANIFEST=${AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST:-}
ALLOW_LOCAL_CANDIDATE=${AETHERROUTE_SIGNED_NE_ALLOW_LOCAL_CANDIDATE:-NO}

usage() {
  echo "usage: AETHERROUTE_ALLOW_REAL_NETWORK_TEST=YES AETHERROUTE_SIGNED_PROFILE_READY=YES AETHERROUTE_NETWORK_TEST_HOST=host AETHERROUTE_SIGNED_PROBE_URL=https://canary.example/path AETHERROUTE_SIGNED_PROBE_SHA256=lowercase64 AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY=/absolute/new/evidence AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST=/absolute/candidate.json AETHERROUTE_SIGNED_NE_BYPASS_CIDRS=ipv4-cidrs AETHERROUTE_SIGNED_NE_CONTROL_PEER=tailscale-ipv4 [AETHERROUTE_SIGNED_NE_CONTROL_TIMEOUT_SECONDS=seconds] [AETHERROUTE_SIGNED_NE_TAILSCALE_CLI=/absolute/tailscale] [AETHERROUTE_SIGNED_NE_ALLOW_LOCAL_CANDIDATE=YES] [AETHERROUTE_SIGNED_NE_ENGINES=tun,transparent] $0 /absolute/path/to/Signing.json" >&2
}

if [ -z "$SIGNING_CONFIG" ]; then
  usage
  exit 1
fi
if [ ! -f "$DNS_PROBE_SCRIPT" ] || [ -L "$DNS_PROBE_SCRIPT" ] \
  || [ ! -x "$DNS_PROBE_SCRIPT" ]; then
  echo "the signed DNS probe must be a regular executable non-symlink" >&2
  exit 2
fi
DNS_PROBE_SHA256=$(shasum -a 256 "$DNS_PROBE_SCRIPT" | awk '{print $1}')
if ! printf '%s\n' "$DNS_PROBE_SHA256" \
  | grep -Eq '^[0-9a-f]{64}$'; then
  echo "the signed DNS probe SHA-256 is invalid" >&2
  exit 2
fi
if [ -n "${AETHERROUTE_SIGNED_DERIVED_DATA:-}" ]; then
  echo "signed Network Extension gate always uses disposable DerivedData" >&2
  exit 2
fi
case "$CYCLES" in
  ''|*[!0-9]*) echo "AETHERROUTE_SIGNED_NE_CYCLES must be an integer" >&2; exit 1 ;;
esac
if [ "$CYCLES" -lt 1 ] || [ "$CYCLES" -gt 20 ]; then
  echo "AETHERROUTE_SIGNED_NE_CYCLES must be between 1 and 20" >&2
  exit 1
fi
if [ -z "$CONTROL_TIMEOUT_SECONDS" ]; then
  CONTROL_TIMEOUT_SECONDS=$((CYCLES * 120 + 180))
fi
case "$CONTROL_TIMEOUT_SECONDS" in
  ''|*[!0-9]*) echo "AETHERROUTE_SIGNED_NE_CONTROL_TIMEOUT_SECONDS must be an integer" >&2; exit 1 ;;
esac
if [ "$CONTROL_TIMEOUT_SECONDS" -lt 180 ] \
  || [ "$CONTROL_TIMEOUT_SECONDS" -gt 3600 ]; then
  echo "AETHERROUTE_SIGNED_NE_CONTROL_TIMEOUT_SECONDS must be between 180 and 3600" >&2
  exit 1
fi
case "$ENGINES" in
  tun,transparent|transparent,tun) ;;
  *)
    echo "AETHERROUTE_SIGNED_NE_ENGINES must include both tun and transparent" >&2
    exit 1
    ;;
esac
case "$PROBE_URL" in
  https://*.*/*) ;;
  *)
    echo "AETHERROUTE_SIGNED_PROBE_URL must use a non-local HTTPS hostname and path" >&2
    exit 1
    ;;
esac
if printf '%s' "$PROBE_URL" | grep -Eq '[@?#[:space:]]|localhost|127\.|\[::1\]'; then
  echo "AETHERROUTE_SIGNED_PROBE_URL must contain no credentials, query, fragment, whitespace, or loopback host" >&2
  exit 1
fi
if ! printf '%s' "$PROBE_SHA256" \
  | grep -Eq '^[0-9a-f]{64}$'; then
  echo "AETHERROUTE_SIGNED_PROBE_SHA256 must be exactly 64 lowercase hex characters" >&2
  exit 1
fi
if [ "${AETHERROUTE_ALLOW_REAL_NETWORK_TEST:-}" != YES ]; then
  echo "refusing to start a real Network Extension without AETHERROUTE_ALLOW_REAL_NETWORK_TEST=YES" >&2
  exit 2
fi
if [ "${AETHERROUTE_SIGNED_PROFILE_READY:-}" != YES ]; then
  echo "prepare a validated active profile in the signed app, then set AETHERROUTE_SIGNED_PROFILE_READY=YES" >&2
  exit 2
fi
if [ -z "$EXPECTED_HOST" ]; then
  echo "set AETHERROUTE_NETWORK_TEST_HOST to the exact designated test host" >&2
  exit 2
fi
case "$EVIDENCE_DIRECTORY" in
  /*) ;;
  '') echo "set AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY to a new absolute directory" >&2; exit 2 ;;
  *) echo "AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY must be absolute" >&2; exit 2 ;;
esac
if [ -e "$EVIDENCE_DIRECTORY" ]; then
  echo "refusing to overwrite signed Network Extension evidence: $EVIDENCE_DIRECTORY" >&2
  exit 2
fi
case "$CANDIDATE_MANIFEST" in
  /*) ;;
  '') echo "set AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST to the exact notarized candidate manifest" >&2; exit 2 ;;
  *) echo "AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST must be absolute" >&2; exit 2 ;;
esac
test -f "$CANDIDATE_MANIFEST" || {
  echo "signed Network Extension candidate manifest is missing" >&2
  exit 2
}
case "$ALLOW_LOCAL_CANDIDATE" in
  YES|NO) ;;
  *) echo "AETHERROUTE_SIGNED_NE_ALLOW_LOCAL_CANDIDATE must be YES or NO" >&2; exit 2 ;;
esac
valid_ipv4_bypass_cidr() {
  printf '%s\n' "$1" | awk -F '[./]' '
    NF != 5 { exit 1 }
    {
      for (piece_index = 1; piece_index <= 5; piece_index++) {
        if ($piece_index !~ /^[0-9]+$/) exit 1
      }
      for (octet_index = 1; octet_index <= 4; octet_index++) {
        if ($octet_index < 0 || $octet_index > 255) exit 1
      }
      if ($5 < 8 || $5 > 32) exit 1
    }
  '
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
ipv4_cidr_contains() {
  awk -v peer="$1" -v cidr="$2" '
    function ipv4_number(value, octets) {
      split(value, octets, ".")
      return (((octets[1] * 256) + octets[2]) * 256 + octets[3]) * 256 + octets[4]
    }
    BEGIN {
      split(cidr, parts, "/")
      block_size = 2 ^ (32 - parts[2])
      exit int(ipv4_number(peer) / block_size) == int(ipv4_number(parts[1]) / block_size) ? 0 : 1
    }
  '
}
if [ -n "$BYPASS_CIDRS" ]; then
  bypass_count=0
  previous_ifs=$IFS
  IFS=,
  for bypass_cidr in $BYPASS_CIDRS; do
    bypass_count=$((bypass_count + 1))
    if ! valid_ipv4_bypass_cidr "$bypass_cidr"; then
      echo "AETHERROUTE_SIGNED_NE_BYPASS_CIDRS accepts only comma-separated IPv4 /8 through /32 routes" >&2
      exit 2
    fi
  done
  IFS=$previous_ifs
  if [ "$bypass_count" -gt 32 ]; then
    echo "AETHERROUTE_SIGNED_NE_BYPASS_CIDRS accepts at most 32 routes" >&2
    exit 2
  fi
fi
if ! valid_ipv4_address "$CONTROL_PEER"; then
  echo "set AETHERROUTE_SIGNED_NE_CONTROL_PEER to the designated Tailscale IPv4 peer" >&2
  exit 2
fi
control_peer_is_bypassed=0
previous_ifs=$IFS
IFS=,
for bypass_cidr in $BYPASS_CIDRS; do
  if ipv4_cidr_contains "$CONTROL_PEER" "$bypass_cidr"; then
    control_peer_is_bypassed=1
    break
  fi
done
IFS=$previous_ifs
if [ "$control_peer_is_bypassed" -ne 1 ]; then
  echo "AETHERROUTE_SIGNED_NE_CONTROL_PEER must be covered by AETHERROUTE_SIGNED_NE_BYPASS_CIDRS" >&2
  exit 2
fi

CURRENT_HOST=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
if [ "$CURRENT_HOST" != "$EXPECTED_HOST" ]; then
  echo "refusing real Network Extension test on $CURRENT_HOST; expected $EXPECTED_HOST" >&2
  exit 2
fi
if ! security find-identity -v -p codesigning 2>&1 \
  | grep -F "Apple Development" >/dev/null; then
  echo "a valid Apple Development identity is required for XCUITest" >&2
  exit 2
fi
if [ -z "$TAILSCALE_CLI" ]; then
  if [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    TAILSCALE_CLI=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  else
    TAILSCALE_CLI=$(command -v tailscale 2>/dev/null || true)
  fi
fi
case "$TAILSCALE_CLI" in
  /*) ;;
  *) echo "AETHERROUTE_SIGNED_NE_TAILSCALE_CLI must resolve to an absolute executable" >&2; exit 2 ;;
esac
if [ ! -x "$TAILSCALE_CLI" ]; then
  echo "AETHERROUTE_SIGNED_NE_TAILSCALE_CLI is not executable" >&2
  exit 2
fi
CONTROL_ROUTE_COMMAND=/sbin/route
TAILSCALE_MAGIC_DNS=100.100.100.100
BASELINE_CONTROL_INTERFACE=$("$CONTROL_ROUTE_COMMAND" -n get "$CONTROL_PEER" \
  2>/dev/null | awk '$1 == "interface:" {print $2; exit}')
case "$BASELINE_CONTROL_INTERFACE" in
  utun[0-9]*) ;;
  *) echo "the designated control peer does not have a baseline Tailscale utun route" >&2; exit 2 ;;
esac
BASELINE_MAGIC_DNS_INTERFACE=$("$CONTROL_ROUTE_COMMAND" -n get \
  "$TAILSCALE_MAGIC_DNS" 2>/dev/null \
  | awk '$1 == "interface:" {print $2; exit}')
if [ "$BASELINE_MAGIC_DNS_INTERFACE" != "$BASELINE_CONTROL_INTERFACE" ]; then
  echo "the Tailscale MagicDNS route does not share the baseline control interface" >&2
  exit 2
fi
tailscale_direct_ping() {
  direct_ping_output=$("$TAILSCALE_CLI" ping \
    --c 1 --timeout 2s --until-direct=true "$CONTROL_PEER" 2>/dev/null) \
    || return 1
  printf '%s\n' "$direct_ping_output" | grep -Eq \
    ' via ([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+( |$)| via \[[0-9A-Fa-f:]+\]:[0-9]+( |$)'
}
if ! tailscale_direct_ping; then
  echo "the designated Tailscale control peer has no direct path before the TUN gate" >&2
  exit 2
fi

"$ROOT/scripts/signing_preflight.sh" "$SIGNING_CONFIG"
"$ROOT/scripts/bootstrap.sh"

AUDIT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-signed-ne.XXXXXX")
DERIVED_DATA="$AUDIT_DIR/DerivedData"
EVIDENCE_CREATED=0
EVIDENCE_COMPLETE=0
CLEANUP_STARTED=0
TUN_CONTROL_GATE_ACTIVE=0
TUN_WATCHDOG_PID=
TUN_TEST_PID=
TUN_WATCHDOG_STOP_FILE=
prune_children_except() {
  parent=$1
  keep=$2
  for child in "$parent"/* "$parent"/.[!.]* "$parent"/..?*; do
    [ -e "$child" ] || continue
    if [ "$child" != "$keep" ]; then
      find "$child" -depth -delete 2>/dev/null || true
    fi
  done
}
prune_ui_test_bulk() {
  build_directory="$DERIVED_DATA/Build"
  products_directory="$build_directory/Products"
  [ -d "$products_directory" ] || return 0
  prune_children_except "$AUDIT_DIR" "$DERIVED_DATA"
  prune_children_except "$DERIVED_DATA" "$build_directory"
  prune_children_except "$build_directory" "$products_directory"
}
cleanup() {
  if [ "$CLEANUP_STARTED" -eq 1 ]; then
    return
  fi
  CLEANUP_STARTED=1
  if [ "$TUN_CONTROL_GATE_ACTIVE" -eq 1 ]; then
    if [ -n "$TUN_WATCHDOG_STOP_FILE" ]; then
      : >"$TUN_WATCHDOG_STOP_FILE"
    fi
    # This function resolves only VPN services owned by the exact packet
    # provider bundle. Never stop an unrelated VPN or alter routes directly.
    safe_stop_aetherroute_tun 2>/dev/null || true
    if [ -n "$TUN_TEST_PID" ] \
      && kill -0 "$TUN_TEST_PID" 2>/dev/null; then
      kill -TERM "$TUN_TEST_PID" 2>/dev/null || true
    fi
    if [ -n "$TUN_WATCHDOG_PID" ]; then
      wait "$TUN_WATCHDOG_PID" 2>/dev/null || true
    fi
  fi
  RUNNER_APP="$DERIVED_DATA/Build/Products/Debug/AetherRouteUITests-Runner.app"
  PRODUCT_APP="$DERIVED_DATA/Build/Products/Debug/AetherRoute.app"
  # Stop queued XCTest launches before removing their bundle. Otherwise
  # LaunchServices may try to open the now-deleted runner and present a
  # misleading "damaged" alert after the test has already finished.
  pkill -TERM -f "$DERIVED_DATA" 2>/dev/null || true
  attempts=0
  while [ "$attempts" -lt 25 ]; do
    if ! pgrep -f "$DERIVED_DATA" >/dev/null 2>&1; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 0.2
  done
  pkill -KILL -f "$DERIVED_DATA" 2>/dev/null || true
  # LaunchServices accepts XCTest launch requests asynchronously. Unregister
  # the bundles now, but leave the still-valid signed apps at their exact paths
  # for a bounded quiet period so a late launch request cannot resolve to a
  # runner that cleanup has already deleted.
  for application in "$RUNNER_APP" "$PRODUCT_APP"; do
    if [ -d "$application" ]; then
      xattr -dr com.apple.quarantine "$application" 2>/dev/null || true
      /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
        -u "$application" >/dev/null 2>&1 || true
    fi
  done
  if [ -d /Applications/AetherRoute.app ]; then
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
      -f /Applications/AetherRoute.app >/dev/null 2>&1 || true
  fi
  if [ -d "$RUNNER_APP" ] && [ -d "$PRODUCT_APP" ]; then
    # Keep disk usage bounded even when the execution host terminates detached
    # cleanup workers as soon as their parent command exits.
    prune_ui_test_bulk
    AETHERROUTE_UI_CLEANUP_GRACE_SECONDS=600 \
      nohup "$ROOT/scripts/deferred_ui_test_cleanup.sh" \
        "$AUDIT_DIR" "$DERIVED_DATA" "$RUNNER_APP" "$PRODUCT_APP" \
        </dev/null >/dev/null 2>&1 &
  else
    find "$AUDIT_DIR" -depth -delete 2>/dev/null || true
  fi
  if [ "$EVIDENCE_CREATED" -eq 1 ] && [ "$EVIDENCE_COMPLETE" -eq 0 ]; then
    find "$EVIDENCE_DIRECTORY" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM
SIGNING_OVERRIDES="$AUDIT_DIR/AetherRouteSigning.xcconfig"
"$ROOT/scripts/generate_signing_overrides.sh" \
  "$SIGNING_CONFIG" "$SIGNING_OVERRIDES" >/dev/null

SCHEME=AetherRoute
TEST_TARGET=AetherRouteUITests
APP_NAME=AetherRoute.app
EXPECTED_HOST_BUNDLE=$(jq -r \
  '.profiles[] | select(.role == "direct-host") | .bundleID' \
  "$SIGNING_CONFIG")
EXPECTED_PACKET_BUNDLE=$(jq -r \
  '.profiles[] | select(.role == "packet-tunnel") | .bundleID' \
  "$SIGNING_CONFIG")
EXPECTED_TRANSPARENT_BUNDLE=$(jq -r \
  '.profiles[] | select(.role == "transparent-proxy") | .bundleID' \
  "$SIGNING_CONFIG")
EXPECTED_TUN_SERVICE_NAME=AetherRoute
TUN_SERVICE_RESOLVER="$ROOT/scripts/signed_ne_tun_service_resolver.sh"
test -x "$TUN_SERVICE_RESOLVER" || {
  echo "signed TUN service resolver is missing or not executable" >&2
  exit 1
}

safe_stop_aetherroute_tun() {
  service_id=$("$TUN_SERVICE_RESOLVER" \
    "$EXPECTED_HOST_BUNDLE" \
    "$EXPECTED_PACKET_BUNDLE" \
    "$EXPECTED_TUN_SERVICE_NAME" \
    /usr/sbin/scutil) || {
    echo "refusing to stop an unverified AetherRoute TUN service" >&2
    return 1
  }
  (/usr/sbin/scutil --nc stop "$service_id") >/dev/null 2>&1 || {
    echo "failed to request a safe AetherRoute TUN stop" >&2
    return 1
  }
  stop_attempt=0
  while [ "$stop_attempt" -lt 20 ]; do
    service_state=$(/usr/sbin/scutil --nc status "$service_id" \
      2>/dev/null | awk 'NR == 1 {print $1}' || true)
    case "$service_state" in
      Disconnected) return 0 ;;
      Connected|Connecting|Disconnecting) ;;
      *)
        echo "could not verify the stopped AetherRoute TUN service state" >&2
        return 1
        ;;
    esac
    stop_attempt=$((stop_attempt + 1))
    sleep 1
  done
  echo "AetherRoute TUN did not reach a stopped state after the safe stop request" >&2
  return 1
}

xcodebuild \
  -project "$ROOT/AetherRoute.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -xcconfig "$SIGNING_OVERRIDES" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  build-for-testing

RUNNER_APP="$DERIVED_DATA/Build/Products/Debug/AetherRouteUITests-Runner.app"
APP=/Applications/AetherRoute.app
EXPECTED_SIGNING_AUTHORITY="Developer ID Application"
EXPECTED_PACKET_GRANT=packet-tunnel-provider-systemextension
EXPECTED_TRANSPARENT_GRANT=app-proxy-provider-systemextension
PACKET_EXTENSION="$APP/Contents/Library/SystemExtensions/$EXPECTED_PACKET_BUNDLE.systemextension"
TRANSPARENT_EXTENSION="$APP/Contents/Library/SystemExtensions/$EXPECTED_TRANSPARENT_BUNDLE.systemextension"
if [ ! -d "$RUNNER_APP" ] \
  || [ ! -d "$APP" ] \
  || [ ! -d "$PACKET_EXTENSION" ] \
  || [ ! -d "$TRANSPARENT_EXTENSION" ]; then
  echo "signed build is missing its UI runner, host, or one of the expected extensions" >&2
  exit 1
fi
CURRENT_SOURCE_MANIFEST=$("$ROOT/scripts/source_manifest.sh" \
  | awk '$1 == "MANIFEST_SHA256" {print $2}')
CANDIDATE_STATUS=$(jq -r '.releaseStatus // empty' "$CANDIDATE_MANIFEST")
case "$CANDIDATE_STATUS:$ALLOW_LOCAL_CANDIDATE" in
  notarized-test-candidate:YES|notarized-test-candidate:NO) ;;
  signed-local-test-candidate:YES) ;;
  signed-local-test-candidate:NO)
    echo "local signed candidate requires AETHERROUTE_SIGNED_NE_ALLOW_LOCAL_CANDIDATE=YES" >&2
    exit 2
    ;;
  *)
    echo "unsupported signed Network Extension candidate status" >&2
    exit 2
    ;;
esac
jq -e --arg source "$CURRENT_SOURCE_MANIFEST" \
  --arg status "$CANDIDATE_STATUS" '
  .schemaVersion == 1 and
  .releaseStatus == $status and
  .product == "AetherRoute" and
  .architecture == "arm64" and
  .sourceManifestSHA256 == $source and
  (.version | test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$")) and
  (.build | test("^[1-9][0-9]*$"))
' "$CANDIDATE_MANIFEST" >/dev/null || {
  echo "installed Network Extension candidate is not bound to the current source manifest" >&2
  exit 2
}
EXPECTED_VERSION=$(jq -r '.version' "$CANDIDATE_MANIFEST")
EXPECTED_BUILD=$(jq -r '.build' "$CANDIDATE_MANIFEST")
test "$(plutil -extract CFBundleShortVersionString raw -o - \
  "$APP/Contents/Info.plist")" = "$EXPECTED_VERSION" || {
  echo "installed Network Extension candidate version differs from its manifest" >&2
  exit 2
}
test "$(plutil -extract CFBundleVersion raw -o - \
  "$APP/Contents/Info.plist")" = "$EXPECTED_BUILD" || {
  echo "installed Network Extension candidate build differs from its manifest" >&2
  exit 2
}
if [ "$CANDIDATE_STATUS" = notarized-test-candidate ]; then
  spctl --assess --type execute --verbose=4 "$APP"
else
  test "$(jq -r '.safety.productionApproved' "$CANDIDATE_MANIFEST")" = false
  test "$(jq -r '.safety.crossMachineApproved' "$CANDIDATE_MANIFEST")" = false
  test "$(jq -r '.application.notarized' "$CANDIDATE_MANIFEST")" = false
  EXPECTED_CDHASH=$(jq -r '.application.cdHash | ascii_downcase' \
    "$CANDIDATE_MANIFEST")
  ACTUAL_CDHASH=$(codesign -dv --verbose=4 "$APP" 2>&1 \
    | awk -F= '$1 == "CDHash" {print tolower($2); exit}')
  test -n "$EXPECTED_CDHASH" && test "$ACTUAL_CDHASH" = "$EXPECTED_CDHASH" || {
    echo "installed local candidate CDHash differs from its manifest" >&2
    exit 2
  }
fi
codesign --verify --deep --strict --verbose=2 "$RUNNER_APP"
if ! codesign -dv --verbose=4 "$RUNNER_APP" 2>&1 \
  | grep -F "Authority=Apple Development" >/dev/null; then
  echo "signed lifecycle UI runner is not Apple Development signed" >&2
  exit 1
fi
if xattr -p com.apple.quarantine "$RUNNER_APP" >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$RUNNER_APP"
fi
ACTUAL_HOST_BUNDLE=$(/usr/libexec/PlistBuddy -c \
  'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
if [ "$ACTUAL_HOST_BUNDLE" != "$EXPECTED_HOST_BUNDLE" ]; then
  echo "signed lifecycle host bundle identifier mismatch" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"
if ! codesign -dv --verbose=4 "$APP" 2>&1 \
  | grep -F "Authority=$EXPECTED_SIGNING_AUTHORITY" >/dev/null; then
  echo "signed lifecycle host does not use $EXPECTED_SIGNING_AUTHORITY" >&2
  exit 1
fi
HOST_ENTITLEMENTS="$AUDIT_DIR/host.plist"
codesign -d --entitlements :- "$APP" >"$HOST_ENTITLEMENTS" 2>/dev/null
if plutil -extract 'com\.apple\.security\.network\.server' raw -o - \
  "$HOST_ENTITLEMENTS" >/dev/null 2>&1; then
  echo "signed host must not carry network.server" >&2
  exit 1
fi

verify_extension() {
  extension=$1
  expected_bundle=$2
  expected_grant=$3
  server_entitlement=$4
  actual_bundle=$(/usr/libexec/PlistBuddy -c \
    'Print :CFBundleIdentifier' "$extension/Contents/Info.plist")
  if [ "$actual_bundle" != "$expected_bundle" ]; then
    echo "signed lifecycle extension bundle identifier mismatch: $extension" >&2
    exit 1
  fi
  codesign --verify --strict --verbose=2 "$extension"
  if ! codesign -dv --verbose=4 "$extension" 2>&1 \
    | grep -F "Authority=$EXPECTED_SIGNING_AUTHORITY" >/dev/null; then
    echo "signed lifecycle extension does not use $EXPECTED_SIGNING_AUTHORITY: $extension" >&2
    exit 1
  fi
  entitlements="$AUDIT_DIR/$(basename "$extension").plist"
  codesign -d --entitlements :- "$extension" >"$entitlements" 2>/dev/null
  plutil -extract 'com\.apple\.developer\.networking\.networkextension' json \
    -o - "$entitlements" \
    | jq -e --arg expected "$expected_grant" \
      'index($expected) != null' >/dev/null
  if [ "$server_entitlement" = required ]; then
    if [ "$(plutil -extract 'com\.apple\.security\.network\.server' raw -o - \
      "$entitlements" 2>/dev/null || echo false)" != true ]; then
      echo "signed Network Extension is missing its UDP receive entitlement" >&2
      exit 1
    fi
  elif plutil -extract 'com\.apple\.security\.network\.server' raw -o - \
    "$entitlements" >/dev/null 2>&1; then
    echo "network.server escaped the signed Network Extension boundary" >&2
    exit 1
  fi
}

verify_extension \
  "$PACKET_EXTENSION" \
  "$EXPECTED_PACKET_BUNDLE" \
  "$EXPECTED_PACKET_GRANT" \
  required
verify_extension \
  "$TRANSPARENT_EXTENSION" \
  "$EXPECTED_TRANSPARENT_BUNDLE" \
  "$EXPECTED_TRANSPARENT_GRANT" \
  required

mkdir -p "$EVIDENCE_DIRECTORY"
EVIDENCE_CREATED=1
network_control_hash() {
  {
    /usr/sbin/scutil --proxy
    /usr/sbin/scutil --dns
    /usr/sbin/netstat -rn -f inet | awk '$1 == "default" {print}'
    /usr/sbin/netstat -rn -f inet6 | awk '$1 == "default" {print}'
    /sbin/ifconfig -l
    "$CONTROL_ROUTE_COMMAND" -n get "$CONTROL_PEER" 2>/dev/null \
      | awk '$1 == "destination:" || $1 == "gateway:" || $1 == "interface:" || $1 == "flags:" {print}'
    "$CONTROL_ROUTE_COMMAND" -n get "$TAILSCALE_MAGIC_DNS" 2>/dev/null \
      | awk '$1 == "destination:" || $1 == "gateway:" || $1 == "interface:" || $1 == "flags:" {print}'
  } | shasum -a 256 | awk '{print $1}'
}
control_peer_is_healthy() {
  current_control_interface=$("$CONTROL_ROUTE_COMMAND" -n get "$CONTROL_PEER" \
    2>/dev/null | awk '$1 == "interface:" {print $2; exit}' || true)
  current_magic_dns_interface=$("$CONTROL_ROUTE_COMMAND" -n get \
    "$TAILSCALE_MAGIC_DNS" 2>/dev/null \
    | awk '$1 == "interface:" {print $2; exit}' || true)
  [ "$current_control_interface" = "$BASELINE_CONTROL_INTERFACE" ] \
    && [ "$current_magic_dns_interface" = "$BASELINE_MAGIC_DNS_INTERFACE" ] \
    && tailscale_direct_ping
}
network_control_before=$(network_control_hash)
source_manifest_sha256=$("$ROOT/scripts/source_manifest.sh" \
  | awk '$1 == "MANIFEST_SHA256" {print $2}')
candidate_manifest_sha256=$(shasum -a 256 "$CANDIDATE_MANIFEST" | awk '{print $1}')
probe_url_sha256=$(printf '%s' "$PROBE_URL" | shasum -a 256 | awk '{print $1}')
host_name_sha256=$(printf '%s' "$CURRENT_HOST" | shasum -a 256 | awk '{print $1}')
control_peer_sha256=$(printf '%s' "$CONTROL_PEER" | shasum -a 256 | awk '{print $1}')
control_interface_sha256=$(printf '%s' "$BASELINE_CONTROL_INTERFACE" \
  | shasum -a 256 | awk '{print $1}')
{
  printf 'schema=2\n'
  printf 'product=%s\n' "$PRODUCT"
  printf 'machine=%s\n' "$(uname -m)"
  printf 'os=%s\n' "$(sw_vers -productVersion)"
  printf 'host_name_sha256=%s\n' "$host_name_sha256"
  printf 'engines=%s\n' "$ENGINES"
  printf 'cycles_per_engine=%s\n' "$CYCLES"
  printf 'signing_identity=Apple Development\n'
  printf 'runtime_signing_identity=%s\n' "$EXPECTED_SIGNING_AUTHORITY"
  printf 'candidate_release_status=%s\n' "$CANDIDATE_STATUS"
  printf 'candidate_manifest_sha256=%s\n' "$candidate_manifest_sha256"
  printf 'candidate_version=%s\n' "$EXPECTED_VERSION"
  printf 'candidate_build=%s\n' "$EXPECTED_BUILD"
  printf 'host_bundle_id=%s\n' "$EXPECTED_HOST_BUNDLE"
  printf 'packet_bundle_id=%s\n' "$EXPECTED_PACKET_BUNDLE"
  printf 'transparent_bundle_id=%s\n' "$EXPECTED_TRANSPARENT_BUNDLE"
  printf 'probe_url_sha256=%s\n' "$probe_url_sha256"
  printf 'probe_response_sha256=%s\n' "$PROBE_SHA256"
  printf 'control_peer_sha256=%s\n' "$control_peer_sha256"
  printf 'control_interface_sha256=%s\n' "$control_interface_sha256"
  printf 'control_watchdog_interval_seconds=2\n'
  printf 'control_watchdog_failure_limit=5\n'
  printf 'control_watchdog_hard_timeout_seconds=%s\n' "$CONTROL_TIMEOUT_SECONDS"
  printf 'dns_gate_schema=public-best-effort-v1\n'
  printf 'dns_claim_level=resolver-control+synthetic-stub-data-plane\n'
  printf 'dns_probe_sha256=%s\n' "$DNS_PROBE_SHA256"
  printf 'dns_owner_canary=not-configured\n'
  printf 'dns_upstream_path=not-verified\n'
  printf 'dns_no_leak=not-verified\n'
  printf 'network_control_before_sha256=%s\n' "$network_control_before"
  printf 'source_manifest_sha256=%s\n' "$source_manifest_sha256"
  printf 'runner_sha256=%s\n' "$(shasum -a 256 "$ROOT/scripts/test_signed_network_extension.sh" | awk '{print $1}')"
  printf 'control_watchdog_sha256=%s\n' "$(shasum -a 256 "$ROOT/scripts/signed_ne_control_watchdog.sh" | awk '{print $1}')"
  printf 'ui_test_sha256=%s\n' "$(shasum -a 256 "$ROOT/Tests/AetherRouteUITests/AetherRouteUITests.swift" | awk '{print $1}')"
  printf 'flow_artifact_sha256=%s\n' "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" | awk '{print $1}')"
  printf 'packet_artifact_sha256=%s\n' "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" | awk '{print $1}')"
  printf 'network_extension_runtime=enabled\n'
  printf 'raw_xcresult_retained=no\n'
  printf 'probe_url_retained=no\n'
  printf 'control_peer_retained=no\n'
  printf 'dns_probe_host_retained=no\n'
  printf 'dns_nonce_retained=no\n'
} >"$EVIDENCE_DIRECTORY/metadata.txt"
for ENGINE in $(printf '%s' "$ENGINES" | tr ',' ' '); do
  RESULT_STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
  RESULT_BUNDLE="$AUDIT_DIR/$PRODUCT-$ENGINE-$RESULT_STAMP.xcresult"
  RESULT_SUMMARY="$EVIDENCE_DIRECTORY/engine-$ENGINE.txt"
  echo "Starting explicitly authorized $ENGINE Network Extension lifecycle gate on $CURRENT_HOST"
  export AETHERROUTE_RUN_SIGNED_NE_TEST=YES
  export AETHERROUTE_SIGNED_NE_PRODUCT="$PRODUCT"
  export AETHERROUTE_SIGNED_NE_ENGINE="$ENGINE"
  export AETHERROUTE_SIGNED_NE_CYCLES="$CYCLES"
  export AETHERROUTE_SIGNED_PROBE_URL="$PROBE_URL"
  export AETHERROUTE_SIGNED_PROBE_SHA256="$PROBE_SHA256"
  export AETHERROUTE_SIGNED_DNS_PROBE_SCRIPT="$DNS_PROBE_SCRIPT"
  export AETHERROUTE_SIGNED_DNS_PROBE_SHA256="$DNS_PROBE_SHA256"
  export AETHERROUTE_SIGNED_NE_BYPASS_CIDRS="$BYPASS_CIDRS"
  export AETHERROUTE_SIGNED_NE_USE_INSTALLED_APP=YES
  export AETHERROUTE_SIGNED_NE_HOST_BUNDLE_ID="$EXPECTED_HOST_BUNDLE"
  set -- xcodebuild \
    -project "$ROOT/AetherRoute.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -xcconfig "$SIGNING_OVERRIDES" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$RESULT_BUNDLE" \
    test-without-building \
    -only-testing:"$TEST_TARGET/AetherRouteUITests/testSignedNetworkExtensionConnectDisconnectLifecycle"

  control_watchdog_result=not-applicable
  if [ "$ENGINE" = tun ]; then
    TUN_CONTROL_GATE_ACTIVE=1
    TUN_WATCHDOG_STOP_FILE="$AUDIT_DIR/tun-control-watchdog.stop"
    TUN_WATCHDOG_LOG="$AUDIT_DIR/tun-control-watchdog.log"
    "$ROOT/scripts/signed_ne_control_watchdog.sh" \
      "$CONTROL_PEER" \
      "$BASELINE_CONTROL_INTERFACE" \
      "$TAILSCALE_MAGIC_DNS" \
      "$BASELINE_MAGIC_DNS_INTERFACE" \
      "$TUN_WATCHDOG_STOP_FILE" \
      "$CONTROL_TIMEOUT_SECONDS" \
      "$CONTROL_ROUTE_COMMAND" \
      "$TAILSCALE_CLI" \
      2 \
      5 >"$TUN_WATCHDOG_LOG" 2>&1 &
    TUN_WATCHDOG_PID=$!
    "$@" &
    TUN_TEST_PID=$!

    completed_process=
    while [ -z "$completed_process" ]; do
      if ! kill -0 "$TUN_TEST_PID" 2>/dev/null; then
        completed_process=test
      elif ! kill -0 "$TUN_WATCHDOG_PID" 2>/dev/null; then
        completed_process=watchdog
      else
        sleep 1
      fi
    done

    if [ "$completed_process" = watchdog ]; then
      watchdog_exit_code=0
      wait "$TUN_WATCHDOG_PID" || watchdog_exit_code=$?
      safe_stop_exit_code=0
      safe_stop_aetherroute_tun || safe_stop_exit_code=$?
      if kill -0 "$TUN_TEST_PID" 2>/dev/null; then
        kill -TERM "$TUN_TEST_PID" 2>/dev/null || true
      fi
      termination_attempt=0
      while kill -0 "$TUN_TEST_PID" 2>/dev/null \
        && [ "$termination_attempt" -lt 10 ]; do
        termination_attempt=$((termination_attempt + 1))
        sleep 1
      done
      if kill -0 "$TUN_TEST_PID" 2>/dev/null; then
        kill -KILL "$TUN_TEST_PID" 2>/dev/null || true
      fi
      wait "$TUN_TEST_PID" 2>/dev/null || true
      pkill -TERM -f "$DERIVED_DATA" 2>/dev/null || true
      sleep 1
      final_stop_exit_code=0
      safe_stop_aetherroute_tun || final_stop_exit_code=$?
      TUN_WATCHDOG_PID=
      TUN_TEST_PID=
      if [ "$final_stop_exit_code" -eq 0 ]; then
        TUN_CONTROL_GATE_ACTIVE=0
      fi
      case "$watchdog_exit_code" in
        70) echo "TUN gate stopped safely after five consecutive control-path failures" >&2 ;;
        124) echo "TUN gate stopped safely at the control-path hard timeout" >&2 ;;
        *) echo "TUN gate stopped safely after an unexpected control watchdog exit" >&2 ;;
      esac
      if [ "$safe_stop_exit_code" -ne 0 ] \
        || [ "$final_stop_exit_code" -ne 0 ]; then
        echo "the scoped AetherRoute TUN stop could not be verified" >&2
      fi
      exit 1
    fi

    test_exit_code=0
    wait "$TUN_TEST_PID" || test_exit_code=$?
    : >"$TUN_WATCHDOG_STOP_FILE"
    watchdog_exit_code=0
    wait "$TUN_WATCHDOG_PID" || watchdog_exit_code=$?
    TUN_WATCHDOG_PID=
    TUN_TEST_PID=
    if [ "$test_exit_code" -ne 0 ] || [ "$watchdog_exit_code" -ne 0 ]; then
      lifecycle_stop_exit_code=0
      safe_stop_aetherroute_tun || lifecycle_stop_exit_code=$?
      if [ "$lifecycle_stop_exit_code" -eq 0 ]; then
        TUN_CONTROL_GATE_ACTIVE=0
      fi
      echo "TUN lifecycle or its control-path watchdog failed" >&2
      exit 1
    fi
    watchdog_checks=$(awk -F= \
      '$1 == "control-peer watchdog stopped: checks" {print $2; exit}' \
      "$TUN_WATCHDOG_LOG")
    case "$watchdog_checks" in
      ''|*[!0-9]*|0)
        empty_watchdog_stop_exit_code=0
        safe_stop_aetherroute_tun || empty_watchdog_stop_exit_code=$?
        if [ "$empty_watchdog_stop_exit_code" -eq 0 ]; then
          TUN_CONTROL_GATE_ACTIVE=0
        fi
        echo "TUN control-path watchdog completed without a real probe" >&2
        exit 1
        ;;
    esac
    control_watchdog_result=passed
  else
    "$@"
  fi

  if ! control_peer_is_healthy; then
    echo "Tailscale control route or peer reachability was not restored after $ENGINE" >&2
    exit 1
  fi
  network_control_after=$(network_control_hash)
  if [ "$network_control_after" != "$network_control_before" ]; then
    echo "System proxy/DNS/default-route/interface state was not restored after $ENGINE" >&2
    exit 1
  fi
  if [ "$ENGINE" = tun ]; then
    TUN_CONTROL_GATE_ACTIVE=0
  fi
  {
    printf 'product=%s\n' "$PRODUCT"
    printf 'engine=%s\n' "$ENGINE"
    printf 'cycles=%s\n' "$CYCLES"
    printf 'completed_at=%s\n' "$RESULT_STAMP"
    printf 'before_connection_probe=unreachable\n'
    printf 'connected_probe=matched\n'
    printf 'after_disconnect_probe=unreachable\n'
    printf 'provider_readiness=reported\n'
    printf 'control_peer_route_and_direct_ping=passed\n'
    printf 'tailscale_magic_dns_route=passed\n'
    printf 'control_peer_watchdog=%s\n' "$control_watchdog_result"
    printf 'dns_gate_schema=public-best-effort-v1\n'
    printf 'dns_cycles=%s\n' "$CYCLES"
    printf 'dns_connected_checks=%s\n' "$CYCLES"
    printf 'dns_disconnect_checks=%s\n' "$CYCLES"
    printf 'dns_baseline_stub=unavailable\n'
    if [ "$ENGINE" = tun ]; then
      printf 'dns_default_resolver=passed\n'
      printf 'dns_connected_resolver_unchanged=not-applicable\n'
      printf 'dns_stub_route=utun\n'
      printf 'dns_stub_interface=198.18.0.1-present\n'
      printf 'dns_stub_udp_passed=%s\n' "$CYCLES"
      printf 'dns_stub_tcp_passed=%s\n' "$CYCLES"
    else
      printf 'dns_default_resolver=not-applicable\n'
      printf 'dns_connected_resolver_unchanged=passed\n'
      printf 'dns_stub_route=not-applicable\n'
      printf 'dns_stub_interface=not-applicable\n'
      printf 'dns_stub_udp_passed=not-applicable\n'
      printf 'dns_stub_tcp_passed=not-applicable\n'
    fi
    printf 'dns_disconnect_resolver_restore=passed\n'
    printf 'dns_disconnect_stub=unavailable\n'
    printf 'dns_upstream_path=not-verified\n'
    printf 'dns_no_leak=not-verified\n'
    printf 'network_control_restored=yes\n'
    printf 'result=passed\n'
  } >"$RESULT_SUMMARY"
  echo "Signed $ENGINE lifecycle gate passed: cycles=$CYCLES summary=$RESULT_SUMMARY"
done
{
  printf 'engines=tun,transparent\n'
  printf 'cycles_per_engine=%s\n' "$CYCLES"
  printf 'raw_xcresult_retained=no\n'
  printf 'tun_control_peer_watchdog=passed\n'
  printf 'control_peer_route_and_direct_ping_restored=yes\n'
  printf 'tailscale_magic_dns_route_restored=yes\n'
  printf 'dns_gate=passed\n'
  printf 'dns_claim_level=resolver-control+synthetic-stub-data-plane\n'
  printf 'dns_owner_canary=not-configured\n'
  printf 'dns_upstream_path=not-verified\n'
  printf 'dns_no_leak=not-verified\n'
  printf 'dns_status=passed-with-upstream-unproven\n'
  printf 'network_control_restored=yes\n'
  printf 'status=passed\n'
} >"$EVIDENCE_DIRECTORY/result.txt"
(
  cd "$EVIDENCE_DIRECTORY"
  shasum -a 256 metadata.txt engine-tun.txt engine-transparent.txt result.txt \
    >SHA256SUMS
)
EVIDENCE_COMPLETE=1
echo "Signed dual-engine Network Extension evidence passed: $EVIDENCE_DIRECTORY"
