#!/bin/sh
set -eu

# Shared build/verification policy for signed test candidates. Every variant
# first verifies the normal production archives against protocol evidence.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ACTION=${1:-}
VARIANT=${2:-}
APP=${3:-}
case "$ACTION:$VARIANT" in build:normal|build:diagnostics|built:normal|built:diagnostics|bind:normal|bind:diagnostics) ;;
  *) echo 'usage: test_candidate_core.sh build|built|bind normal|diagnostics [app|source-manifest] [core-json]' >&2; exit 64 ;;
esac
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-test-core.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
FLOW="$ROOT/Core/Artifacts/macos-arm64/libclashrs.a"
PACKET="$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a"

if [ "$ACTION" = bind ]; then
  manifest_hash() {
    awk -v path="$1" '$2==path {n++; hash=$1} END{if(n!=1)exit 1; print hash}' "$APP"
  }
  flow=$(manifest_hash Core/Artifacts/macos-arm64/libclashrs.a)
  packet=$(manifest_hash Core/Artifacts/macos-arm64/libclashrs-direct.a)
  evidence=$(manifest_hash Config/ProtocolCoreEvidence.json)
  printf '%s\n' "${4:-}" | jq -e --arg variant "$VARIANT" \
    --arg flow "$flow" --arg packet "$packet" --arg evidence "$evidence" '
    .variant==$variant and .flow.artifactSHA256==$flow and
    .packet.artifactSHA256==$packet and .protocolReference.evidenceSHA256==$evidence and
    (.protocolReference.flowArtifactSHA256 | test("^[0-9a-f]{64}$")) and
    (.protocolReference.packetArtifactSHA256 | test("^[0-9a-f]{64}$")) and
    (if $variant=="normal" then
      .diagnosticsIncluded==false and .protocolReference.matchesCandidateArtifacts==true and
      .flow.features=="aether-flow-only" and .packet.features=="aether-embedded" and
      .protocolReference.flowArtifactSHA256==$flow and .protocolReference.packetArtifactSHA256==$packet
    else
      .diagnosticsIncluded==true and .protocolReference.matchesCandidateArtifacts==false and
      .flow.features=="aether-flow-only,aether-diagnostics" and .packet.features=="aether-embedded,aether-diagnostics" and
      .protocolReference.flowArtifactSHA256!=$flow and .protocolReference.packetArtifactSHA256!=$packet
    end)' >/dev/null || {
      echo 'test candidate core metadata differs from its variant or frozen source manifest' >&2; exit 1;
    }
  exit 0
fi

check_markers() {
  artifact=$1
  variant=$2
  expected_marker=$3
  strings "$artifact" >"$TEMP/strings.txt" || {
    echo "cannot inspect test candidate core: $artifact" >&2; exit 1;
  }
  if [ "$variant" = normal ]; then
    if grep -E 'aether_(flow|packet) stage=' "$TEMP/strings.txt" >/dev/null; then
      echo "normal test candidate contains diagnostic core markers: $artifact" >&2
      exit 1
    fi
  else
    grep -F "$expected_marker" "$TEMP/strings.txt" >/dev/null || {
      echo "diagnostics test candidate is missing $expected_marker in $artifact" >&2; exit 1;
    }
  fi
}

if [ "$ACTION" = built ]; then
  case "$APP" in /*.app) ;; *) exit 64 ;; esac
  test -d "$APP" || exit 1
  if [ "$VARIANT" = normal ]; then
    find "$APP" -type f >"$TEMP/files.txt"
    macho_count=0
    while IFS= read -r executable; do
      description=$(file -b "$executable") || {
        echo "cannot classify test candidate file: $executable" >&2; exit 1;
      }
      case "$description" in Mach-O*)
        check_markers "$executable" normal unused
        macho_count=$((macho_count + 1)) ;;
      esac
    done <"$TEMP/files.txt"
    test "$macho_count" -gt 0 || { echo 'normal test candidate has no Mach-O files' >&2; exit 1; }
  else
    find "$APP" -type f -name AetherRouteFlowCoreBridge >"$TEMP/flow-bridges.txt"
    test -s "$TEMP/flow-bridges.txt" || { echo 'test candidate has no Flow core bridge' >&2; exit 1; }
    while IFS= read -r bridge; do
      check_markers "$bridge" diagnostics 'aether_flow stage='
    done <"$TEMP/flow-bridges.txt"
  fi
  exit 0
fi

# Explicit values prevent an inherited QA feature override from changing what
# "normal" means. The existing protocol verifier binds the actual normal bytes.
AETHERROUTE_CORE_FEATURES='aether-flow-only' "$ROOT/scripts/build_core.sh" >/dev/null
AETHERROUTE_DIRECT_CORE_FEATURES='aether-embedded' "$ROOT/scripts/build_direct_core.sh" >/dev/null
check_markers "$FLOW" normal unused
check_markers "$PACKET" normal unused
"$ROOT/scripts/verify_protocol_matrix.sh" >&2
reference_flow=$(shasum -a 256 "$FLOW" | awk '{print $1}')
reference_packet=$(shasum -a 256 "$PACKET" | awk '{print $1}')
protocol_evidence=$(shasum -a 256 "$ROOT/Config/ProtocolCoreEvidence.json" | awk '{print $1}')

flow_features=aether-flow-only
packet_features=aether-embedded
diagnostics=false
if [ "$VARIANT" = diagnostics ]; then
  flow_features=aether-flow-only,aether-diagnostics
  packet_features=aether-embedded,aether-diagnostics
  AETHERROUTE_CORE_FEATURES='aether-flow-only,aether-diagnostics' "$ROOT/scripts/build_core.sh" >/dev/null
  AETHERROUTE_DIRECT_CORE_FEATURES='aether-embedded,aether-diagnostics' "$ROOT/scripts/build_direct_core.sh" >/dev/null
  check_markers "$FLOW" diagnostics 'aether_flow stage='
  check_markers "$PACKET" diagnostics 'aether_packet stage='
  diagnostics=true
fi
actual_flow=$(shasum -a 256 "$FLOW" | awk '{print $1}')
actual_packet=$(shasum -a 256 "$PACKET" | awk '{print $1}')
jq -n --arg variant "$VARIANT" --argjson diagnostics "$diagnostics" \
  --arg flowFeatures "$flow_features" --arg packetFeatures "$packet_features" \
  --arg flow "$actual_flow" --arg packet "$actual_packet" \
  --arg referenceFlow "$reference_flow" --arg referencePacket "$reference_packet" \
  --arg evidence "$protocol_evidence" \
  '{variant:$variant, diagnosticsIncluded:$diagnostics,
    flow:{features:$flowFeatures, artifactSHA256:$flow},
    packet:{features:$packetFeatures, artifactSHA256:$packet},
    protocolReference:{evidenceSHA256:$evidence,
      flowArtifactSHA256:$referenceFlow, packetArtifactSHA256:$referencePacket,
      matchesCandidateArtifacts:($flow==$referenceFlow and $packet==$referencePacket)}}'
