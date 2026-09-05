#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/build_signed_local_test_candidate.sh"
GUARD="$ROOT/scripts/guard_developer_id_network_extension_build.sh"
TUNNEL_MANAGER="$ROOT/Sources/AetherRouteApp/TunnelManager.swift"

sh -n "$SCRIPT"
sh -n "$GUARD"
if "$SCRIPT" >/dev/null 2>&1; then
  echo "local signed candidate script accepted missing inputs" >&2
  exit 1
fi

for required in \
  'scripts/signing_preflight.sh' \
  'scripts/verify_developer_id_private_key_access.sh' \
  "AETHERROUTE_CORE_FEATURES='aether-flow-only,aether-diagnostics'" \
  "AETHERROUTE_DIRECT_CORE_FEATURES='aether-embedded,aether-diagnostics'" \
  "grep -F 'aether_flow stage='" \
  "grep -F 'aether_packet stage='" \
  'scripts/generate_licenses.sh' \
  'scripts/verify_licenses.sh" source' \
  'scripts/verify_licenses.sh" built' \
  'CODE_SIGN_STYLE = Manual' \
  'OTHER_CODE_SIGN_FLAGS = --timestamp' \
  'AETHERROUTE_RELEASE_CHANNEL = development' \
  'Authority=Developer ID Application' \
  'Xcode-managed Mac Team profile escaped' \
  'ProvisionsAllDevices' \
  'packet-tunnel-provider-systemextension' \
  'app-proxy-provider-systemextension' \
  'releaseStatus: "signed-local-test-candidate"' \
  'productionApproved: false' \
  'crossMachineApproved: false' \
  'notarized: false' \
  'source changed while building' \
  'system network state changed while building'
do
  grep -F "$required" "$SCRIPT" >/dev/null || {
    echo "local signed candidate pipeline is missing gate: $required" >&2
    exit 1
  }
done

flow_build_line=$(grep -nF \
  "AETHERROUTE_CORE_FEATURES='aether-flow-only,aether-diagnostics'" \
  "$SCRIPT" | cut -d: -f1)
packet_build_line=$(grep -nF \
  "AETHERROUTE_DIRECT_CORE_FEATURES='aether-embedded,aether-diagnostics'" \
  "$SCRIPT" | cut -d: -f1)
license_generation_line=$(grep -nF \
  '"$ROOT/scripts/generate_licenses.sh"' "$SCRIPT" | cut -d: -f1)
license_source_line=$(grep -nF \
  '"$ROOT/scripts/verify_licenses.sh" source' "$SCRIPT" | cut -d: -f1)
bootstrap_line=$(grep -nF '"$ROOT/scripts/bootstrap.sh"' "$SCRIPT" | cut -d: -f1)
license_built_line=$(grep -nF \
  '"$ROOT/scripts/verify_licenses.sh" built' "$SCRIPT" | cut -d: -f1)
signature_line=$(grep -nF \
  'codesign --verify --deep --strict' "$SCRIPT" | cut -d: -f1)
package_line=$(grep -nF 'ditto -c -k --keepParent' "$SCRIPT" | cut -d: -f1)
if [ "$flow_build_line" -ge "$license_generation_line" ] \
  || [ "$packet_build_line" -ge "$license_generation_line" ] \
  || [ "$license_generation_line" -ge "$license_source_line" ] \
  || [ "$license_source_line" -ge "$bootstrap_line" ] \
  || [ "$signature_line" -ge "$license_built_line" ] \
  || [ "$license_built_line" -ge "$package_line" ]; then
  echo "QA notices must follow both core builds and be verified before packaging" >&2
  exit 1
fi

KEY_GUARD="$ROOT/scripts/verify_developer_id_private_key_access.sh"
sh -n "$KEY_GUARD"
for required in \
  '--timestamp=none' \
  'Developer ID certificate is installed, but its private key is unavailable.' \
  'Unlock the login Keychain in Keychain Access' \
  'will not fall back to an automatic Mac Team profile'
do
  grep -F -- "$required" "$KEY_GUARD" >/dev/null || {
    echo "Developer ID private-key guard is missing: $required" >&2
    exit 1
  }
done

for required in \
  'CONFIGURATION:-}" != Release' \
  'CODE_SIGN_STYLE must be Manual' \
  'automatic Mac Team signing is forbidden' \
  'AETHERROUTE_ALLOW_ISOLATED_RELEASE_TEST_BUILD' \
  'isolated Release test builds are limited to ACTION=build' \
  'stable builds cannot use the isolated Release test exception' \
  'isolated Release test builds require a fail-closed fixture' \
  'build_signed_local_test_candidate.sh' \
  'scripts/release.sh'
do
  grep -F "$required" "$GUARD" >/dev/null || {
    echo "Release signing build guard is missing: $required" >&2
    exit 1
  }
done

for isolated_script in \
  "$ROOT/scripts/build_development_preview.sh" \
  "$ROOT/scripts/test_dmg_upgrade_rollback.sh" \
  "$ROOT/scripts/test_large_import_performance.sh" \
  "$ROOT/scripts/test_disconnected_idle_performance.sh" \
  "$ROOT/scripts/test_ui.sh"
do
  grep -F 'AETHERROUTE_ALLOW_ISOLATED_RELEASE_TEST_BUILD=YES' \
    "$isolated_script" >/dev/null || {
    echo "isolated Release test does not declare its signing boundary: $isolated_script" >&2
    exit 1
  }
done

CONFIGURATION=Release \
ACTION=build \
AETHERROUTE_RELEASE_CHANNEL=beta \
AETHERROUTE_ALLOW_ISOLATED_RELEASE_TEST_BUILD=YES \
SWIFT_ACTIVE_COMPILATION_CONDITIONS='AETHERROUTE_DEVELOPMENT_PREVIEW' \
  "$GUARD" >/dev/null

for rejected_case in archive stable missing-fixture; do
  case "$rejected_case" in
    archive)
      action=install
      channel=beta
      conditions=AETHERROUTE_DEVELOPMENT_PREVIEW
      ;;
    stable)
      action=build
      channel=stable
      conditions=AETHERROUTE_DEVELOPMENT_PREVIEW
      ;;
    missing-fixture)
      action=build
      channel=beta
      conditions=RELEASE
      ;;
  esac
  if CONFIGURATION=Release \
    ACTION="$action" \
    AETHERROUTE_RELEASE_CHANNEL="$channel" \
    AETHERROUTE_ALLOW_ISOLATED_RELEASE_TEST_BUILD=YES \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="$conditions" \
      "$GUARD" >/dev/null 2>&1; then
    echo "Release signing guard accepted unsafe exception: $rejected_case" >&2
    exit 1
  fi
done

grep -A8 '^    Release:' "$ROOT/project.yml" \
  | grep -F 'CODE_SIGN_STYLE: Manual' >/dev/null || {
  echo "Release configuration is not permanently manual signed" >&2
  exit 1
}
grep -A8 '^    Release:' "$ROOT/project.yml" \
  | grep -F 'CODE_SIGN_IDENTITY: Developer ID Application' >/dev/null || {
  echo "Release configuration does not require Developer ID Application" >&2
  exit 1
}

guard_reference_count=$(grep -c \
  'path: scripts/guard_developer_id_network_extension_build.sh' \
  "$ROOT/project.yml")
test "$guard_reference_count" -eq 3 || {
  echo "host and both Network Extension targets must run the Release signing guard" >&2
  exit 1
}

grep -F '#if DEBUG || AETHERROUTE_DEVELOPMENT_PREVIEW' \
  "$TUNNEL_MANAGER" >/dev/null || {
  echo "Debug builds must fail closed before starting Network Extensions" >&2
  exit 1
}

for forbidden in \
  'xcrun notarytool submit' \
  'systemextensionsctl' \
  'networksetup' \
  'scutil --set'
do
  if grep -F "$forbidden" "$SCRIPT" >/dev/null; then
    echo "local signed candidate must not notarize, activate, or change networking: $forbidden" >&2
    exit 1
  fi
done

echo "Developer ID local QA candidate and Release signing guards passed."
