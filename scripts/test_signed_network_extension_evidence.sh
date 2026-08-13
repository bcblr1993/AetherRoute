#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-signed-ne-evidence.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
EVIDENCE="$TEMP/evidence"
mkdir "$EVIDENCE"

hash_of() { shasum -a 256 "$1" | awk '{print $1}'; }
source_manifest_hash() {
  "$ROOT/scripts/source_manifest.sh" | awk '$1 == "MANIFEST_SHA256" {print $2}'
}
write_hashes() {
  (cd "$EVIDENCE" && shasum -a 256 \
    metadata.txt engine-tun.txt engine-transparent.txt result.txt >SHA256SUMS)
}
write_metadata() {
  manifest_hash=$1
  printf '%s\n' \
    'schema=2' \
    'product=independent' \
    'machine=arm64' \
    'os=26.5' \
    'host_name_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'engines=tun,transparent' \
    'cycles_per_engine=3' \
    'signing_identity=Apple Development' \
    'runtime_signing_identity=Developer ID Application' \
    'candidate_release_status=notarized-test-candidate' \
    'candidate_manifest_sha256=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' \
    'candidate_version=1.0.0' \
    'candidate_build=2026081001' \
    'host_bundle_id=com.aetherroute.desktop' \
    'packet_bundle_id=com.aetherroute.desktop.tunnel' \
    'transparent_bundle_id=com.aetherroute.desktop.transparent-proxy' \
    'probe_url_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    'probe_response_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
    'control_peer_sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' \
    'control_interface_sha256=1111111111111111111111111111111111111111111111111111111111111111' \
    'control_watchdog_interval_seconds=2' \
    'control_watchdog_failure_limit=5' \
    'control_watchdog_hard_timeout_seconds=540' \
    'dns_gate_schema=public-best-effort-v1' \
    'dns_claim_level=resolver-control+synthetic-stub-data-plane' \
    "dns_probe_sha256=$(hash_of "$ROOT/scripts/signed_ne_dns_probe.sh")" \
    'dns_owner_canary=not-configured' \
    'dns_upstream_path=not-verified' \
    'dns_no_leak=not-verified' \
    'network_control_before_sha256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
    "source_manifest_sha256=$manifest_hash" \
    "runner_sha256=$(hash_of "$ROOT/scripts/test_signed_network_extension.sh")" \
    "control_watchdog_sha256=$(hash_of "$ROOT/scripts/signed_ne_control_watchdog.sh")" \
    "ui_test_sha256=$(hash_of "$ROOT/Tests/AetherRouteUITests/AetherRouteUITests.swift")" \
    "flow_artifact_sha256=$(hash_of "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a")" \
    "packet_artifact_sha256=$(hash_of "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a")" \
    'network_extension_runtime=enabled' \
    'raw_xcresult_retained=no' \
    'probe_url_retained=no' \
    'control_peer_retained=no' \
    'dns_probe_host_retained=no' \
    'dns_nonce_retained=no' >"$EVIDENCE/metadata.txt"
}
write_engine() {
  engine=$1
  case "$engine" in
    tun)
      watchdog_result=passed
      dns_default_resolver=passed
      dns_connected_resolver_unchanged=not-applicable
      dns_stub_route=utun
      dns_stub_interface=198.18.0.1-present
      dns_stub_udp_passed=3
      dns_stub_tcp_passed=3
      ;;
    transparent)
      watchdog_result=not-applicable
      dns_default_resolver=not-applicable
      dns_connected_resolver_unchanged=passed
      dns_stub_route=not-applicable
      dns_stub_interface=not-applicable
      dns_stub_udp_passed=not-applicable
      dns_stub_tcp_passed=not-applicable
      ;;
  esac
  printf '%s\n' \
    'product=independent' \
    "engine=$engine" \
    'cycles=3' \
    'completed_at=20260802T000000Z' \
    'before_connection_probe=unreachable' \
    'connected_probe=matched' \
    'after_disconnect_probe=unreachable' \
    'provider_readiness=reported' \
    'control_peer_route_and_direct_ping=passed' \
    'tailscale_magic_dns_route=passed' \
    "control_peer_watchdog=$watchdog_result" \
    'dns_gate_schema=public-best-effort-v1' \
    'dns_cycles=3' \
    'dns_connected_checks=3' \
    'dns_disconnect_checks=3' \
    'dns_baseline_stub=unavailable' \
    "dns_default_resolver=$dns_default_resolver" \
    "dns_connected_resolver_unchanged=$dns_connected_resolver_unchanged" \
    "dns_stub_route=$dns_stub_route" \
    "dns_stub_interface=$dns_stub_interface" \
    "dns_stub_udp_passed=$dns_stub_udp_passed" \
    "dns_stub_tcp_passed=$dns_stub_tcp_passed" \
    'dns_disconnect_resolver_restore=passed' \
    'dns_disconnect_stub=unavailable' \
    'dns_upstream_path=not-verified' \
    'dns_no_leak=not-verified' \
    'network_control_restored=yes' \
    'result=passed' >"$EVIDENCE/engine-$engine.txt"
}
write_result() {
  printf '%s\n' \
    'engines=tun,transparent' \
    'cycles_per_engine=3' \
    'raw_xcresult_retained=no' \
    'tun_control_peer_watchdog=passed' \
    'control_peer_route_and_direct_ping_restored=yes' \
    'tailscale_magic_dns_route_restored=yes' \
    'dns_gate=passed' \
    'dns_claim_level=resolver-control+synthetic-stub-data-plane' \
    'dns_owner_canary=not-configured' \
    'dns_upstream_path=not-verified' \
    'dns_no_leak=not-verified' \
    'dns_status=passed-with-upstream-unproven' \
    'network_control_restored=yes' \
    'status=passed' >"$EVIDENCE/result.txt"
}
restore_valid_evidence() {
  write_metadata "$1"
  write_engine tun
  write_engine transparent
  write_result
}
expect_rejected() {
  rejection_message=$1
  write_hashes
  if "$ROOT/scripts/verify_signed_network_extension_evidence.sh" "$EVIDENCE" \
    >/dev/null 2>&1; then
    echo "$rejection_message" >&2
    exit 1
  fi
}

current_manifest=$(source_manifest_hash)
restore_valid_evidence "$current_manifest"
write_hashes
"$ROOT/scripts/verify_signed_network_extension_evidence.sh" "$EVIDENCE" >/dev/null
cp "$EVIDENCE/result.txt" "$TEMP/valid-result.txt"

write_metadata dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
write_hashes
if "$ROOT/scripts/verify_signed_network_extension_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "signed Network Extension verifier accepted a stale source manifest" >&2
  exit 1
fi

write_metadata "$current_manifest"
sed -i '' 's/^raw_xcresult_retained=no$/raw_xcresult_retained=yes/' \
  "$EVIDENCE/result.txt"
write_hashes
if "$ROOT/scripts/verify_signed_network_extension_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "signed Network Extension verifier accepted retained raw xcresult" >&2
  exit 1
fi

cp "$TEMP/valid-result.txt" "$EVIDENCE/result.txt"
sed -i '' 's/^network_control_restored=yes$/network_control_restored=no/' \
  "$EVIDENCE/result.txt"
write_hashes
if "$ROOT/scripts/verify_signed_network_extension_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "signed Network Extension verifier accepted unrestored network state" >&2
  exit 1
fi

cp "$TEMP/valid-result.txt" "$EVIDENCE/result.txt"
mkdir "$EVIDENCE/raw.xcresult"
if "$ROOT/scripts/verify_signed_network_extension_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "signed Network Extension verifier accepted an extra xcresult" >&2
  exit 1
fi
find "$EVIDENCE/raw.xcresult" -depth -delete

restore_valid_evidence "$current_manifest"
sed -i '' '/^control_peer_sha256=/d' "$EVIDENCE/metadata.txt"
expect_rejected \
  "signed Network Extension verifier accepted missing control-peer evidence"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^control_interface_sha256=.*$/control_interface_sha256=not-a-sha256/' \
  "$EVIDENCE/metadata.txt"
expect_rejected \
  "signed Network Extension verifier accepted a forged control-interface hash"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^control_watchdog_sha256=.*$/control_watchdog_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$EVIDENCE/metadata.txt"
expect_rejected \
  "signed Network Extension verifier accepted a forged control-watchdog hash"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^control_watchdog_interval_seconds=2$/control_watchdog_interval_seconds=3/' \
  "$EVIDENCE/metadata.txt"
expect_rejected \
  "signed Network Extension verifier accepted a slower control-watchdog interval"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^control_watchdog_failure_limit=5$/control_watchdog_failure_limit=4/' \
  "$EVIDENCE/metadata.txt"
expect_rejected \
  "signed Network Extension verifier accepted the wrong watchdog failure limit"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^control_watchdog_hard_timeout_seconds=540$/control_watchdog_hard_timeout_seconds=179/' \
  "$EVIDENCE/metadata.txt"
expect_rejected \
  "signed Network Extension verifier accepted an unsafe watchdog timeout"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^control_peer_retained=no$/control_peer_retained=yes/' \
  "$EVIDENCE/metadata.txt"
expect_rejected \
  "signed Network Extension verifier accepted retained control-peer data"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^control_peer_watchdog=passed$/control_peer_watchdog=not-applicable/' \
  "$EVIDENCE/engine-tun.txt"
expect_rejected \
  "signed Network Extension verifier accepted a skipped TUN watchdog"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^control_peer_watchdog=not-applicable$/control_peer_watchdog=passed/' \
  "$EVIDENCE/engine-transparent.txt"
expect_rejected \
  "signed Network Extension verifier accepted a transparent watchdog claim"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^control_peer_route_and_direct_ping=passed$/control_peer_route_and_direct_ping=failed/' \
  "$EVIDENCE/engine-transparent.txt"
expect_rejected \
  "signed Network Extension verifier accepted a failed control route"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^tailscale_magic_dns_route=passed$/tailscale_magic_dns_route=failed/' \
  "$EVIDENCE/engine-tun.txt"
expect_rejected \
  "signed Network Extension verifier accepted a failed MagicDNS route"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^tun_control_peer_watchdog=passed$/tun_control_peer_watchdog=failed/' \
  "$EVIDENCE/result.txt"
expect_rejected \
  "signed Network Extension verifier accepted a failed combined TUN watchdog"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^control_peer_route_and_direct_ping_restored=yes$/control_peer_route_and_direct_ping_restored=no/' \
  "$EVIDENCE/result.txt"
expect_rejected \
  "signed Network Extension verifier accepted an unrestored control route"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^tailscale_magic_dns_route_restored=yes$/tailscale_magic_dns_route_restored=no/' \
  "$EVIDENCE/result.txt"
expect_rejected \
  "signed Network Extension verifier accepted an unrestored MagicDNS route"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^dns_probe_sha256=.*$/dns_probe_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$EVIDENCE/metadata.txt"
expect_rejected \
  "signed Network Extension verifier accepted a forged DNS probe hash"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^dns_no_leak=not-verified$/dns_no_leak=passed/' \
  "$EVIDENCE/metadata.txt"
expect_rejected \
  "signed Network Extension verifier accepted an unsupported DNS no-leak claim"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^dns_stub_udp_passed=3$/dns_stub_udp_passed=2/' \
  "$EVIDENCE/engine-tun.txt"
expect_rejected \
  "signed Network Extension verifier accepted incomplete TUN DNS UDP checks"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^dns_connected_resolver_unchanged=passed$/dns_connected_resolver_unchanged=failed/' \
  "$EVIDENCE/engine-transparent.txt"
expect_rejected \
  "signed Network Extension verifier accepted a changed transparent resolver"

restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^dns_status=passed-with-upstream-unproven$/dns_status=passed/' \
  "$EVIDENCE/result.txt"
expect_rejected \
  "signed Network Extension verifier accepted an overclaimed DNS result"

current_manifest=$(source_manifest_hash)
restore_valid_evidence "$current_manifest"
sed -i '' \
  's/^candidate_release_status=notarized-test-candidate$/candidate_release_status=signed-local-test-candidate/' \
  "$EVIDENCE/metadata.txt"
write_hashes
if "$ROOT/scripts/verify_signed_network_extension_evidence.sh" "$EVIDENCE" \
  >/dev/null 2>&1; then
  echo "signed Network Extension verifier accepted local QA evidence for release" >&2
  exit 1
fi
AETHERROUTE_ALLOW_LOCAL_SIGNED_NE_EVIDENCE=YES \
  "$ROOT/scripts/verify_signed_network_extension_evidence.sh" "$EVIDENCE" \
  >/dev/null

echo "Signed Network Extension evidence verifier tests passed."
