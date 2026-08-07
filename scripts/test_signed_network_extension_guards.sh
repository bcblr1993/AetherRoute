#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/test_signed_network_extension.sh"

sh -n "$SCRIPT"
for required in \
  'AETHERROUTE_SIGNED_NE_ENGINES' \
  'AETHERROUTE_SIGNED_NE_ENGINE' \
  'AETHERROUTE_SIGNED_PROBE_URL' \
  'AETHERROUTE_SIGNED_PROBE_SHA256' \
  'AETHERROUTE_SIGNED_NE_EVIDENCE_DIRECTORY' \
  'source_manifest_sha256' \
  'raw_xcresult_retained=no' \
  'probe_url_retained=no' \
  'System proxy/DNS/default-route/interface state was not restored' \
  'signed Network Extension gate always uses disposable DerivedData' \
  '$EXPECTED_PACKET_BUNDLE.systemextension' \
  '$EXPECTED_TRANSPARENT_BUNDLE.systemextension' \
  'packet-tunnel-provider' \
  'app-proxy-provider' \
  'signed host must not carry network.server' \
  'network.server escaped the signed packet tunnel boundary'
do
  grep -F "$required" "$SCRIPT" >/dev/null || {
    echo "signed Network Extension gate is missing guard: $required" >&2
    exit 1
  }
done
grep -F 'must include both tun and transparent' "$SCRIPT" >/dev/null || {
  echo "signed Network Extension gate does not require both engines" >&2
  exit 1
}

if AETHERROUTE_ALLOW_REAL_NETWORK_TEST=NO \
  AETHERROUTE_SIGNED_PROBE_URL=https://canary.example/proxy-only \
  AETHERROUTE_SIGNED_PROBE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$SCRIPT" /nonexistent/signing.json >/dev/null 2>&1; then
  echo "signed Network Extension gate ran without explicit real-network opt-in" >&2
  exit 1
fi

echo "Signed dual-engine Network Extension guard tests passed."
