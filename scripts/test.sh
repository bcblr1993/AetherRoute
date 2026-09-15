#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-test.XXXXXX")
DERIVED_DATA_PATH=${AETHERROUTE_DERIVED_DATA_PATH:-"$TEST_TEMP/DerivedData"}
cleanup() {
  find "$TEST_TEMP" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

"$ROOT/scripts/bootstrap.sh"
"$ROOT/scripts/test_signing_overrides.sh"
"$ROOT/scripts/test_temporary_cleanup_guards.sh"
"$ROOT/scripts/test_external_profile_sanitizer.sh"
"$ROOT/scripts/test_signed_network_extension_guards.sh"
"$ROOT/Tests/SignedNEProbe/run.sh"
"$ROOT/scripts/test_app_termination_signal_guard.sh"
"$ROOT/scripts/test_signed_local_candidate_pipeline.sh"
"$ROOT/scripts/test_signed_network_extension_evidence.sh"
"$ROOT/scripts/test_postinstall_evidence.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/test_installed_ne_performance_collector.py"
"$ROOT/scripts/test_promotion_pipeline.sh"
"$ROOT/scripts/test_notarized_test_candidate_pipeline.sh"
"$ROOT/scripts/test_ui_isolation_guards.sh"
"$ROOT/scripts/test_telemetry_observation_scope.sh"
"$ROOT/scripts/test_packet_tunnel_autorelease_scope.sh"
"$ROOT/scripts/test_packet_tunnel_telemetry_buffer_reuse.sh"
"$ROOT/scripts/validation/test_correlate_vm_host_network_1434.sh"
"$ROOT/scripts/test_core_reproducibility_guards.sh"
"$ROOT/scripts/test_release_pipeline.sh"
"$ROOT/scripts/test_distribution_modes.sh"
"$ROOT/scripts/test_bundled_routing_license_coverage.sh"
"$ROOT/scripts/test_runtime_acceptance_regressions.sh"
"$ROOT/scripts/test_vm_acceptance_priming.sh"
"$ROOT/scripts/test_vm_matrix_lifecycle.sh"
"$ROOT/scripts/test_isolated_soak_process_cleanup.sh"
sh "$ROOT/Tests/ConnectionRows/run.sh"
sh "$ROOT/Tests/MenuProxyNodeOrder/run.sh"
sh "$ROOT/Tests/SystemExtensionActivation/run.sh"
sh "$ROOT/Tests/WindowVisibility/run.sh"
"$ROOT/scripts/test_release_soak_evidence.sh"
"$ROOT/scripts/test_remote_arm64_guards.sh"
"$ROOT/scripts/test_soak_result_verifier.sh"
"$ROOT/scripts/test_soak_trend_verifier.sh"
"$ROOT/scripts/test_update_envelope.sh"
"$ROOT/scripts/test_distribution_staging.sh"
"$ROOT/scripts/test_distribution_web.sh"
"$ROOT/scripts/test_distribution_service.sh"
"$ROOT/scripts/test_dmg_upgrade_rollback.sh"
"$ROOT/scripts/verify_independent_distribution_boundary.sh"
"$ROOT/scripts/test_large_import_performance.sh"
"$ROOT/scripts/test_udp_integrity.sh"
"$ROOT/scripts/test_tcp_performance.sh"
"$ROOT/scripts/verify_app_icon.sh"
"$ROOT/scripts/verify_localizations.sh"
"$ROOT/scripts/verify_protocol_matrix.sh"
"$ROOT/scripts/test_protocol_interop_runner.sh"
"$ROOT/scripts/verify_transparent_proxy_metadata.sh" source
"$ROOT/scripts/verify_product_metadata.sh" source
"$ROOT/scripts/verify_licenses.sh" source

plutil -lint \
  "$ROOT/Config/AetherRoute.entitlements" \
  "$ROOT/Config/AetherRoutePacketTunnel.entitlements" \
  "$ROOT/Config/AetherRouteTransparentProxy.entitlements" \
  "$ROOT/Config/AetherRoute.DeveloperID.entitlements" \
  "$ROOT/Config/AetherRoutePacketTunnel.DeveloperID.entitlements" \
  "$ROOT/Config/AetherRouteTransparentProxy.DeveloperID.entitlements"
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.security.app-sandbox' \
  "$ROOT/Config/AetherRoute.entitlements")" = true
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.security.files.user-selected.read-write' \
  "$ROOT/Config/AetherRoute.entitlements")" = true
if /usr/libexec/PlistBuddy -c \
  'Print :com.apple.security.files.user-selected.read-only' \
  "$ROOT/Config/AetherRoute.entitlements" >/dev/null 2>&1; then
  echo "Host must use one explicit read-write user-selected file entitlement" >&2
  exit 1
fi
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.security.app-sandbox' \
  "$ROOT/Config/AetherRoutePacketTunnel.entitlements")" = true
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.developer.networking.networkextension:0' \
  "$ROOT/Config/AetherRoute.entitlements")" = app-proxy-provider
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.developer.networking.networkextension:1' \
  "$ROOT/Config/AetherRoute.entitlements")" = packet-tunnel-provider
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.developer.networking.networkextension:0' \
  "$ROOT/Config/AetherRoutePacketTunnel.entitlements")" = packet-tunnel-provider
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.developer.networking.networkextension:0' \
  "$ROOT/Config/AetherRouteTransparentProxy.entitlements")" = app-proxy-provider
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.developer.networking.networkextension:0' \
  "$ROOT/Config/AetherRoute.DeveloperID.entitlements")" = \
  app-proxy-provider-systemextension
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.developer.networking.networkextension:1' \
  "$ROOT/Config/AetherRoute.DeveloperID.entitlements")" = \
  packet-tunnel-provider-systemextension
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.developer.networking.networkextension:0' \
  "$ROOT/Config/AetherRoutePacketTunnel.DeveloperID.entitlements")" = \
  packet-tunnel-provider-systemextension
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.developer.networking.networkextension:0' \
  "$ROOT/Config/AetherRouteTransparentProxy.DeveloperID.entitlements")" = \
  app-proxy-provider-systemextension
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.developer.system-extension.install' \
  "$ROOT/Config/AetherRoute.DeveloperID.entitlements")" = true
for ENTITLEMENTS in \
  "$ROOT/Config/AetherRoute.entitlements" \
  "$ROOT/Config/AetherRoutePacketTunnel.entitlements" \
  "$ROOT/Config/AetherRouteTransparentProxy.entitlements" \
  "$ROOT/Config/AetherRoute.DeveloperID.entitlements" \
  "$ROOT/Config/AetherRoutePacketTunnel.DeveloperID.entitlements" \
  "$ROOT/Config/AetherRouteTransparentProxy.DeveloperID.entitlements"
do
  test "$(/usr/libexec/PlistBuddy -c \
    'Print :keychain-access-groups:0' "$ENTITLEMENTS")" = \
    '$(AppIdentifierPrefix)$(AETHERROUTE_KEYCHAIN_GROUP_SUFFIX)'
done
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.security.application-groups:0' \
  "$ROOT/Config/AetherRouteTransparentProxy.entitlements")" = \
  '$(AETHERROUTE_APP_GROUP)'
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.security.network.client' \
  "$ROOT/Config/AetherRouteTransparentProxy.entitlements")" = true
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.security.network.server' \
  "$ROOT/Config/AetherRoutePacketTunnel.entitlements")" = true
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.security.network.server' \
  "$ROOT/Config/AetherRoutePacketTunnel.DeveloperID.entitlements")" = true
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.security.network.server' \
  "$ROOT/Config/AetherRouteTransparentProxy.entitlements")" = true
test "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.security.network.server' \
  "$ROOT/Config/AetherRouteTransparentProxy.DeveloperID.entitlements")" = true
for ENTITLEMENTS in \
  "$ROOT/Config/AetherRoute.entitlements" \
  "$ROOT/Config/AetherRoute.DeveloperID.entitlements"
do
  if /usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.network.server' \
    "$ENTITLEMENTS" >/dev/null 2>&1; then
    echo "Only Network Extensions may request network.server" >&2
    exit 1
  fi
done

xcodebuild \
  -project "$ROOT/AetherRoute.xcodeproj" \
  -scheme AetherRouteUnitTests \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS= \
  CODE_SIGN_IDENTITY=- \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  build-for-testing

"$ROOT/scripts/verify_transparent_proxy_metadata.sh" built \
  "$DERIVED_DATA_PATH/Build/Products/Debug"
"$ROOT/scripts/verify_product_metadata.sh" built \
  "$DERIVED_DATA_PATH/Build/Products/Debug"
"$ROOT/scripts/verify_licenses.sh" built \
  "$DERIVED_DATA_PATH/Build/Products/Debug"
if strings \
  "$DERIVED_DATA_PATH/Build/Products/Debug/AetherRoute.app/Contents/MacOS/AetherRoute" \
  | grep -F 'AETHERROUTE_PERFORMANCE_MEASUREMENT' >/dev/null; then
  echo "Performance measurement fixture escaped into the standard app build" >&2
  exit 1
fi

# Xcode 26 occasionally fails to instantiate a valid, ad-hoc-signed macOS
# test bundle through test-without-building. Run the produced bundle directly;
# this keeps the local and remote gate deterministic while still building the
# complete independent app and both embedded Network Extensions above.
for TEST_BUNDLE in \
  "$DERIVED_DATA_PATH/Build/Products/Debug/AetherRouteTests.xctest" \
  "$DERIVED_DATA_PATH/Build/Products/Debug/AetherRouteTransparentProxySupportTests.xctest" \
  "$DERIVED_DATA_PATH/Build/Products/Debug/AetherRouteFlowCoreBridgeTests.xctest"
do
  codesign --verify --deep --strict "$TEST_BUNDLE"
  xcrun xctest "$TEST_BUNDLE"
done
"$ROOT/scripts/core_smoke.sh"
"$ROOT/scripts/core_smoke_direct.sh"
"$ROOT/scripts/test_local_proxy.sh"
"$ROOT/scripts/test_manual_nodes.sh"
"$ROOT/scripts/test_protocol_input_compatibility.sh"
