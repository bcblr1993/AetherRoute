#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/release.sh"

PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "$ROOT/scripts/verify_independent_distribution_boundary.sh"

sh -n "$SCRIPT"
sh -n "$ROOT/scripts/test_disconnected_idle_performance.sh"
sh -n "$ROOT/scripts/verify_disconnected_idle_performance_result.sh"
if "$SCRIPT" >/dev/null 2>&1; then
  echo "release script accepted missing inputs" >&2
  exit 1
fi
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-release-pipeline-test.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
set +e
missing_soak_output=$(AETHERROUTE_LICENSE_SERVICE_URL=https://license.example \
  AETHERROUTE_UPDATE_MANIFEST_URL=https://updates.example/manifest.json \
  AETHERROUTE_DISTRIBUTION_PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
  "$SCRIPT" "$ROOT/Config/Signing.example.json" test-notary-profile \
    1.0.0 100 "$TEMP" 2>&1)
missing_soak_status=$?
set -e
test "$missing_soak_status" -eq 64 || {
  echo "release script did not fail closed on missing soak evidence" >&2
  exit 1
}
printf '%s\n' "$missing_soak_output" \
  | grep -F 'stable release requires AETHERROUTE_SOAK_EVIDENCE_DIRECTORY' \
    >/dev/null || {
  echo "release script did not identify the missing soak evidence" >&2
  exit 1
}
set +e
missing_signed_output=$(AETHERROUTE_LICENSE_SERVICE_URL=https://license.example \
  AETHERROUTE_UPDATE_MANIFEST_URL=https://updates.example/manifest.json \
  AETHERROUTE_DISTRIBUTION_PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
  AETHERROUTE_SOAK_EVIDENCE_DIRECTORY=/nonexistent/soak-evidence \
  "$SCRIPT" "$ROOT/Config/Signing.example.json" test-notary-profile \
    1.0.0 100 "$TEMP" 2>&1)
missing_signed_status=$?
set -e
test "$missing_signed_status" -eq 64 || {
  echo "release script did not fail closed on missing signed runtime evidence" >&2
  exit 1
}
printf '%s\n' "$missing_signed_output" \
  | grep -F 'stable release requires AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY' \
    >/dev/null || {
  echo "release script did not identify missing signed runtime evidence" >&2
  exit 1
}
for required in \
  'Developer ID Application' \
  'scripts/verify_developer_id_private_key_access.sh' \
  'OTHER_CODE_SIGN_FLAGS = --timestamp' \
  'AETHERROUTE_RELEASE_CHANNEL = stable' \
  'AETHERROUTE_LICENSE_SERVICE_URL' \
  'AETHERROUTE_UPDATE_MANIFEST_URL' \
  'AETHERROUTE_DISTRIBUTION_PUBLIC_KEY' \
  'AETHERROUTE_SOAK_EVIDENCE_DIRECTORY' \
  'AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY' \
  'scripts/verify_release_soak_evidence.sh' \
  'scripts/verify_signed_network_extension_evidence.sh' \
  'evidenceSHA256' \
  'soakDurationSeconds' \
  'soakRounds' \
  'signedNEEvidenceSHA256' \
  'signedNECycles' \
  'releaseStatus: "notarized-candidate"' \
  'stable release requires a clean source tree' \
  'stable release candidates must be created from main' \
  'productID: $productID' \
  'minimumSystemVersion: $minimumSystemVersion' \
  'gitCommit: $gitCommit' \
  'manifestSHA256: $sourceManifestSHA256' \
  'updateSigningPublicKeySHA256' \
  'Production promotion remains blocked' \
  'xcrun notarytool submit' \
  'AetherRoute-app-notarization.dmg' \
  'app-notary-stage' \
  'app-notary-result.json' \
  'dmg-notary-result.json' \
  'AETHERROUTE_NOTARY_KEYCHAIN' \
  '--keychain "$notary_keychain"' \
  'xcrun stapler staple' \
  'xcrun stapler validate "$app"' \
  'syspolicy_check distribution "$app"' \
  'appTicketStapled: true, dmgTicketStapled: true' \
  'spctl --assess --type open' \
  'hdiutil create' \
  'get-task-allow' \
  'release bundle contains non-arm64 Mach-O' \
  'release bundle architecture inventory is unexpectedly small' \
  'packet tunnel is missing its loopback listener entitlement' \
  'transparent proxy is missing its UDP receive entitlement' \
  'network.server escaped the Network Extension boundary' \
  'scripts/test.sh' \
  'scripts/test_sanitizers.sh' \
  'source tree changed during release validation'
do
  grep -F -- "$required" "$SCRIPT" >/dev/null || {
    echo "release pipeline is missing gate: $required" >&2
    exit 1
  }
done
grep -F 'scripts/test_large_import_performance.sh' \
  "$ROOT/scripts/test.sh" >/dev/null || {
    echo "release validation is missing the large import performance gate" >&2
    exit 1
  }
grep -F 'scripts/test_udp_integrity.sh' "$ROOT/scripts/test.sh" >/dev/null || {
  echo "release validation is missing the UDP integrity gate" >&2
  exit 1
}
grep -F 'scripts/test_tcp_performance.sh' "$ROOT/scripts/test.sh" >/dev/null || {
  echo "release validation is missing the TCP performance gate" >&2
  exit 1
}
for tcp_gate_requirement in \
  'minimum_direct_mibps=2048' \
  'minimum_engine_mibps=1024' \
  'TCP performance measurement environment is unsuitable' \
  'only after every release threshold is satisfied'
do
  grep -F "$tcp_gate_requirement" \
    "$ROOT/scripts/test_tcp_performance.sh" >/dev/null || {
    echo "TCP performance producer is missing gate: $tcp_gate_requirement" >&2
    exit 1
  }
done
grep -F 'require_equal minimum_direct_mibps 2048' \
  "$ROOT/scripts/verify_tcp_performance_result.sh" >/dev/null || {
  echo "TCP performance verifier does not bind the clean-host baseline" >&2
  exit 1
}
grep -F 'require_equal schema 2' \
  "$ROOT/scripts/verify_tcp_performance_result.sh" >/dev/null || {
  echo "TCP performance verifier does not bind the environment-aware schema" >&2
  exit 1
}
grep -F 'ENABLE_DEBUG_DYLIB=NO' \
  "$ROOT/scripts/test_sanitizers.sh" >/dev/null || {
  echo "sanitizer validation must disable the duplicate debug-dylib executor" >&2
  exit 1
}
for idle_gate_requirement in \
  'AETHERROUTE_PERFORMANCE_MEASUREMENT' \
  'AETHERROUTE_IDLE_USE_SAMPLE' \
  'network_sockets=none' \
  'system_proxy_state=unchanged' \
  'STATUS=provisional'
do
  grep -F "$idle_gate_requirement" \
    "$ROOT/scripts/test_disconnected_idle_performance.sh" >/dev/null || {
    echo "disconnected idle gate is missing: $idle_gate_requirement" >&2
    exit 1
  }
done
grep -F 'Performance measurement fixture escaped into the standard app build' \
  "$ROOT/scripts/test.sh" >/dev/null || {
  echo "standard product build does not reject the measurement fixture" >&2
  exit 1
}
grep -F 'macOS sample evidence cannot satisfy the final xctrace gate' \
  "$ROOT/scripts/verify_disconnected_idle_performance_result.sh" >/dev/null || {
    echo "disconnected idle verifier does not keep provisional evidence separate" >&2
    exit 1
  }
grep -F 'Recording completed. Saving output file...' \
  "$ROOT/scripts/verify_disconnected_idle_performance_result.sh" >/dev/null || {
  echo "disconnected idle verifier does not recognize current xctrace completion" >&2
  exit 1
}
grep -F 'return try await Task.detached(priority: .userInitiated)' \
  "$ROOT/Sources/AetherRouteKit/VerifiedSoftwareUpdate.swift" >/dev/null || {
  echo "verified update artifact commit must remain off the caller actor" >&2
  exit 1
}
grep -F 'testVerifiedUpdateCommitUsesDetachedTaskContext' \
  "$ROOT/Tests/AetherRouteKitTests/IndependentDistributionTests.swift" >/dev/null || {
  echo "release validation is missing the detached update commit regression test" >&2
  exit 1
}
for boundary_gate in \
  'Mac App Store signing or export setting' \
  'AETHERROUTE_INDEPENDENT' \
  'independent distribution mode'
do
  grep -F "$boundary_gate" \
    "$ROOT/scripts/verify_independent_distribution_boundary.sh" >/dev/null || {
    echo "independent distribution verifier is missing gate: $boundary_gate" >&2
    exit 1
  }
done
if grep -Eq '(apple-id|password|issuer|private-key)[[:space:]]*=' "$SCRIPT"; then
  echo "release script must not embed notarization credentials" >&2
  exit 1
fi

echo "Developer ID release pipeline static tests passed."
