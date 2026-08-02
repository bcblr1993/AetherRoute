#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SIGNING_CONFIG=${1:-}
PRODUCT=independent
CYCLES=${AETHERROUTE_SIGNED_NE_CYCLES:-3}
ENGINES=${AETHERROUTE_SIGNED_NE_ENGINES:-tun,transparent}
EXPECTED_HOST=${AETHERROUTE_NETWORK_TEST_HOST:-}
PROBE_URL=${AETHERROUTE_SIGNED_PROBE_URL:-}
PROBE_SHA256=${AETHERROUTE_SIGNED_PROBE_SHA256:-}
EVIDENCE_DIRECTORY=${AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY:-}

usage() {
  echo "usage: AETHERROUTE_ALLOW_REAL_NETWORK_TEST=YES AETHERROUTE_SIGNED_PROFILE_READY=YES AETHERROUTE_NETWORK_TEST_HOST=host AETHERROUTE_SIGNED_PROBE_URL=https://canary.example/path AETHERROUTE_SIGNED_PROBE_SHA256=lowercase64 AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY=/absolute/new/evidence [AETHERROUTE_SIGNED_NE_ENGINES=tun,transparent] $0 /absolute/path/to/Signing.json" >&2
}

if [ -z "$SIGNING_CONFIG" ]; then
  usage
  exit 1
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

"$ROOT/scripts/signing_preflight.sh" "$SIGNING_CONFIG"
"$ROOT/scripts/bootstrap.sh"

AUDIT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-signed-ne.XXXXXX")
DERIVED_DATA="$AUDIT_DIR/DerivedData"
EVIDENCE_CREATED=0
EVIDENCE_COMPLETE=0
cleanup() {
  find "$AUDIT_DIR" -depth -delete 2>/dev/null || true
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

APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME"
PACKET_EXTENSION="$APP/Contents/PlugIns/AetherRoutePacketTunnel.appex"
TRANSPARENT_EXTENSION="$APP/Contents/PlugIns/AetherRouteTransparentProxy.appex"
if [ ! -d "$APP" ] \
  || [ ! -d "$PACKET_EXTENSION" ] \
  || [ ! -d "$TRANSPARENT_EXTENSION" ]; then
  echo "signed build is missing its host or one of the expected extensions" >&2
  exit 1
fi
ACTUAL_HOST_BUNDLE=$(/usr/libexec/PlistBuddy -c \
  'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
if [ "$ACTUAL_HOST_BUNDLE" != "$EXPECTED_HOST_BUNDLE" ]; then
  echo "signed lifecycle host bundle identifier mismatch" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"
if ! codesign -dv --verbose=4 "$APP" 2>&1 \
  | grep -F "Authority=Apple Development" >/dev/null; then
  echo "signed lifecycle host is not Apple Development signed" >&2
  exit 1
fi
HOST_ENTITLEMENTS="$AUDIT_DIR/host.plist"
codesign -d --entitlements :- "$APP" >"$HOST_ENTITLEMENTS" 2>/dev/null
if plutil -extract com.apple.security.network.server raw -o - \
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
    | grep -F "Authority=Apple Development" >/dev/null; then
    echo "signed lifecycle extension is not Apple Development signed: $extension" >&2
    exit 1
  fi
  entitlements="$AUDIT_DIR/$(basename "$extension").plist"
  codesign -d --entitlements :- "$extension" >"$entitlements" 2>/dev/null
  plutil -extract com.apple.developer.networking.networkextension json \
    -o - "$entitlements" \
    | jq -e --arg expected "$expected_grant" \
      'index($expected) != null' >/dev/null
  if [ "$server_entitlement" = required ]; then
    if [ "$(plutil -extract com.apple.security.network.server raw -o - \
      "$entitlements" 2>/dev/null || echo false)" != true ]; then
      echo "signed packet tunnel is missing its loopback listener entitlement" >&2
      exit 1
    fi
  elif plutil -extract com.apple.security.network.server raw -o - \
    "$entitlements" >/dev/null 2>&1; then
    echo "network.server escaped the signed packet tunnel boundary" >&2
    exit 1
  fi
}

verify_extension \
  "$PACKET_EXTENSION" \
  "$EXPECTED_PACKET_BUNDLE" \
  packet-tunnel-provider \
  required
verify_extension \
  "$TRANSPARENT_EXTENSION" \
  "$EXPECTED_TRANSPARENT_BUNDLE" \
  app-proxy-provider \
  forbidden

mkdir -p "$EVIDENCE_DIRECTORY"
EVIDENCE_CREATED=1
network_control_hash() {
  {
    /usr/sbin/scutil --proxy
    /usr/sbin/scutil --dns
    /usr/sbin/netstat -rn -f inet | awk '$1 == "default" {print}'
    /usr/sbin/netstat -rn -f inet6 | awk '$1 == "default" {print}'
    /sbin/ifconfig -l
  } | shasum -a 256 | awk '{print $1}'
}
network_control_before=$(network_control_hash)
source_manifest_sha256=$("$ROOT/scripts/source_manifest.sh" \
  | awk '$1 == "MANIFEST_SHA256" {print $2}')
probe_url_sha256=$(printf '%s' "$PROBE_URL" | shasum -a 256 | awk '{print $1}')
host_name_sha256=$(printf '%s' "$CURRENT_HOST" | shasum -a 256 | awk '{print $1}')
{
  printf 'schema=1\n'
  printf 'product=%s\n' "$PRODUCT"
  printf 'machine=%s\n' "$(uname -m)"
  printf 'os=%s\n' "$(sw_vers -productVersion)"
  printf 'host_name_sha256=%s\n' "$host_name_sha256"
  printf 'engines=%s\n' "$ENGINES"
  printf 'cycles_per_engine=%s\n' "$CYCLES"
  printf 'signing_identity=Apple Development\n'
  printf 'host_bundle_id=%s\n' "$EXPECTED_HOST_BUNDLE"
  printf 'packet_bundle_id=%s\n' "$EXPECTED_PACKET_BUNDLE"
  printf 'transparent_bundle_id=%s\n' "$EXPECTED_TRANSPARENT_BUNDLE"
  printf 'probe_url_sha256=%s\n' "$probe_url_sha256"
  printf 'probe_response_sha256=%s\n' "$PROBE_SHA256"
  printf 'network_control_before_sha256=%s\n' "$network_control_before"
  printf 'source_manifest_sha256=%s\n' "$source_manifest_sha256"
  printf 'runner_sha256=%s\n' "$(shasum -a 256 "$ROOT/scripts/test_signed_network_extension.sh" | awk '{print $1}')"
  printf 'ui_test_sha256=%s\n' "$(shasum -a 256 "$ROOT/Tests/AetherRouteUITests/AetherRouteUITests.swift" | awk '{print $1}')"
  printf 'flow_artifact_sha256=%s\n' "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" | awk '{print $1}')"
  printf 'packet_artifact_sha256=%s\n' "$(shasum -a 256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" | awk '{print $1}')"
  printf 'network_extension_runtime=enabled\n'
  printf 'raw_xcresult_retained=no\n'
  printf 'probe_url_retained=no\n'
} >"$EVIDENCE_DIRECTORY/metadata.txt"
for ENGINE in $(printf '%s' "$ENGINES" | tr ',' ' '); do
  RESULT_STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
  RESULT_BUNDLE="$AUDIT_DIR/$PRODUCT-$ENGINE-$RESULT_STAMP.xcresult"
  RESULT_SUMMARY="$EVIDENCE_DIRECTORY/engine-$ENGINE.txt"
  echo "Starting explicitly authorized $ENGINE Network Extension lifecycle gate on $CURRENT_HOST"
  AETHERROUTE_RUN_SIGNED_NE_TEST=YES \
  AETHERROUTE_SIGNED_NE_PRODUCT="$PRODUCT" \
  AETHERROUTE_SIGNED_NE_ENGINE="$ENGINE" \
  AETHERROUTE_SIGNED_NE_CYCLES="$CYCLES" \
  AETHERROUTE_SIGNED_PROBE_URL="$PROBE_URL" \
  AETHERROUTE_SIGNED_PROBE_SHA256="$PROBE_SHA256" \
  xcodebuild \
    -project "$ROOT/AetherRoute.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -xcconfig "$SIGNING_OVERRIDES" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$RESULT_BUNDLE" \
    test-without-building \
    -only-testing:"$TEST_TARGET/AetherRouteUITests/testSignedNetworkExtensionConnectDisconnectLifecycle"
  network_control_after=$(network_control_hash)
  if [ "$network_control_after" != "$network_control_before" ]; then
    echo "System proxy/DNS/default-route/interface state was not restored after $ENGINE" >&2
    exit 1
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
    printf 'network_control_restored=yes\n'
    printf 'result=passed\n'
  } >"$RESULT_SUMMARY"
  echo "Signed $ENGINE lifecycle gate passed: cycles=$CYCLES summary=$RESULT_SUMMARY"
done
{
  printf 'engines=tun,transparent\n'
  printf 'cycles_per_engine=%s\n' "$CYCLES"
  printf 'raw_xcresult_retained=no\n'
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
