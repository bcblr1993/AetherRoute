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
    'schema=1' \
    'product=independent' \
    'machine=arm64' \
    'os=26.5' \
    'host_name_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'engines=tun,transparent' \
    'cycles_per_engine=3' \
    'signing_identity=Apple Development' \
    'host_bundle_id=com.aetherroute.desktop' \
    'packet_bundle_id=com.aetherroute.desktop.tunnel' \
    'transparent_bundle_id=com.aetherroute.desktop.transparent-proxy' \
    'probe_url_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    'probe_response_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
    'network_control_before_sha256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
    "source_manifest_sha256=$manifest_hash" \
    "runner_sha256=$(hash_of "$ROOT/scripts/test_signed_network_extension.sh")" \
    "ui_test_sha256=$(hash_of "$ROOT/Tests/AetherRouteUITests/AetherRouteUITests.swift")" \
    "flow_artifact_sha256=$(hash_of "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a")" \
    "packet_artifact_sha256=$(hash_of "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a")" \
    'network_extension_runtime=enabled' \
    'raw_xcresult_retained=no' \
    'probe_url_retained=no' >"$EVIDENCE/metadata.txt"
}
write_engine() {
  engine=$1
  printf '%s\n' \
    'product=independent' \
    "engine=$engine" \
    'cycles=3' \
    'completed_at=20260802T000000Z' \
    'before_connection_probe=unreachable' \
    'connected_probe=matched' \
    'after_disconnect_probe=unreachable' \
    'provider_readiness=reported' \
    'network_control_restored=yes' \
    'result=passed' >"$EVIDENCE/engine-$engine.txt"
}
write_engine tun
write_engine transparent
printf '%s\n' \
  'engines=tun,transparent' \
  'cycles_per_engine=3' \
  'raw_xcresult_retained=no' \
  'network_control_restored=yes' \
  'status=passed' >"$EVIDENCE/result.txt"

current_manifest=$(source_manifest_hash)
write_metadata "$current_manifest"
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

echo "Signed Network Extension evidence verifier tests passed."
