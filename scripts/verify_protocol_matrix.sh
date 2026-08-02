#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MATRIX="$ROOT/Config/ProtocolReleaseMatrix.json"
EVIDENCE="$ROOT/Config/ProtocolCoreEvidence.json"
CATALOG="$ROOT/Sources/AetherRouteKit/ProtocolCapability.swift"
CORE_SOURCE=${AETHERROUTE_CORE_SOURCE:-"$ROOT/Core/Engine"}
INTEROP_SOURCE="$CORE_SOURCE/clash-lib/src/proxy/interop_tests.rs"
PROXY_MANAGER_SOURCE="$CORE_SOURCE/clash-lib/src/app/remote_content_manager/mod.rs"
CORE_MANIFEST="$CORE_SOURCE/clash-lib/Cargo.toml"
FFI_MANIFEST="$CORE_SOURCE/clash-ffi/Cargo.toml"
FFI_SOURCE="$CORE_SOURCE/clash-ffi/src/lib.rs"
FLOW_FFI_SOURCE="$CORE_SOURCE/clash-ffi/src/flow_ffi.rs"
FLOW_CORE="$ROOT/Core/Artifacts/macos-arm64/libclashrs.a"
PACKET_FLOW_CORE="$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a"
CORE_HEADER="$ROOT/Core/Headers/clashrs.h"
INTEROP_TEST_BINARY=${AETHERROUTE_INTEROP_TEST_BINARY:-}

for command in git jq grep shasum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "protocol matrix verification requires $command" >&2
    exit 1
  fi
done

jq -e '
  .schemaVersion == 1 and
  (.coreCommit | test("^[0-9a-f]{40}$")) and
  (.interopCases | type == "array" and length > 0) and
  (.interopTests | type == "array" and length > 0) and
  (.coreFeatures | type == "array" and length > 0) and
  (.ffiFeatures | type == "array" and length > 0) and
  all(.sourceFiles[], .artifacts[]; test("^[0-9a-f]{64}$"))
' "$EVIDENCE" >/dev/null

verify_sha256() {
  path=$1
  expected=$2
  actual=$(shasum -a 256 "$path" | awk '{print $1}')
  test "$actual" = "$expected" || {
    echo "protocol evidence SHA-256 mismatch: $path" >&2
    exit 1
  }
}

verify_sha256 "$FLOW_CORE" \
  "$(jq -r '.artifacts.flowCoreSHA256' "$EVIDENCE")"
verify_sha256 "$PACKET_FLOW_CORE" \
  "$(jq -r '.artifacts.packetFlowCoreSHA256' "$EVIDENCE")"
verify_sha256 "$CORE_HEADER" \
  "$(jq -r '.artifacts.headerSHA256' "$EVIDENCE")"
if [ -n "$INTEROP_TEST_BINARY" ]; then
  test -f "$INTEROP_TEST_BINARY" || {
    echo "configured interoperability test binary is missing" >&2
    exit 1
  }
  verify_sha256 "$INTEROP_TEST_BINARY" \
    "$(jq -r '.artifacts.interopTestBinarySHA256' "$EVIDENCE")"
fi

jq -e '
  .schemaVersion == 1 and
  .releaseStatus == "integration" and
  (.commonRemainingReleaseGates | sort) ==
    (["signed-provider", "sleep-wake", "network-change", "24h-soak"] | sort) and
  (.protocols | type == "array" and length > 0) and
  all(.protocols[];
    (.id | type == "string" and length > 0) and
    (.requiredCoreFeatures | type == "array") and
    (.interopCases | type == "array") and
    (.interopTests | type == "array") and
    (.runners | type == "array" and length > 0) and
    (.uncoveredCatalogClaims | type == "array" and length == 0) and
    ((.interopCases | length) + (.interopTests | length) > 0)
  )
' "$MATRIX" >/dev/null

duplicate_ids=$(jq -r '.protocols[].id' "$MATRIX" | sort | uniq -d)
if [ -n "$duplicate_ids" ]; then
  echo "duplicate protocol matrix IDs: $duplicate_ids" >&2
  exit 1
fi

catalog_ids=$(mktemp "${TMPDIR:-/tmp}/aetherroute-catalog-ids.XXXXXX")
matrix_ids=$(mktemp "${TMPDIR:-/tmp}/aetherroute-matrix-ids.XXXXXX")
cleanup() {
  rm -f -- "$catalog_ids" "$matrix_ids"
}
trap cleanup EXIT HUP INT TERM

grep -Eo 'id: "[a-z0-9-]+"' "$CATALOG" \
  | sed -e 's/id: "//' -e 's/"$//' \
  | sort >"$catalog_ids"
jq -r '.protocols[].id' "$MATRIX" | sort >"$matrix_ids"
if ! cmp -s "$catalog_ids" "$matrix_ids"; then
  echo "ProtocolCatalog and ProtocolReleaseMatrix IDs differ:" >&2
  diff -u "$catalog_ids" "$matrix_ids" >&2 || true
  exit 1
fi

jq -r '.protocols[].runners[]' "$MATRIX" | sort -u | while IFS= read -r runner; do
  case "$runner" in
    Tests/Interop/*.sh|scripts/*.sh) ;;
    *)
      echo "protocol runner must stay inside Tests/Interop or scripts: $runner" >&2
      exit 1
      ;;
  esac
  if [ ! -f "$ROOT/$runner" ]; then
    echo "missing protocol runner: $runner" >&2
    exit 1
  fi
done

jq -r '.protocols[].interopCases[]' "$MATRIX" | while IFS= read -r case_name; do
  if ! jq -e --arg value "$case_name" \
    '.interopCases | index($value) != null' "$EVIDENCE" >/dev/null; then
    echo "protocol matrix references an unknown interop case: $case_name" >&2
    exit 1
  fi
done

jq -r '.protocols[].interopTests[]' "$MATRIX" | while IFS= read -r test_name; do
  if ! jq -e --arg value "$test_name" \
    '.interopTests | index($value) != null' "$EVIDENCE" >/dev/null; then
    echo "protocol matrix references an unknown interop test: $test_name" >&2
    exit 1
  fi
done

jq -r '.protocols[].requiredCoreFeatures[]' "$MATRIX" \
  | sort -u | while IFS= read -r feature; do
  if ! jq -e --arg value "$feature" \
    '.coreFeatures | index($value) != null' "$EVIDENCE" >/dev/null; then
    echo "protocol matrix references an unknown core feature: $feature" >&2
    exit 1
  fi
  if ! jq -e --arg value "$feature" \
    '.ffiFeatures | index($value) != null' "$EVIDENCE" >/dev/null; then
    echo "clash-ffi release graph does not enable required core feature: $feature" >&2
    exit 1
  fi
done

if [ -d "$CORE_SOURCE" ]; then
  for source_file in \
    "$INTEROP_SOURCE" \
    "$PROXY_MANAGER_SOURCE" \
    "$CORE_MANIFEST" \
    "$FFI_MANIFEST" \
    "$FFI_SOURCE" \
    "$FLOW_FFI_SOURCE"
  do
    test -f "$source_file" || {
      echo "external core source checkout is incomplete: $source_file" >&2
      exit 1
    }
  done
  test "$(git -C "$CORE_SOURCE" rev-parse HEAD)" = \
    "$(jq -r '.coreCommit' "$EVIDENCE")" || {
      echo "external core source commit differs from protocol evidence" >&2
      exit 1
    }
  verify_sha256 "$INTEROP_SOURCE" \
    "$(jq -r '.sourceFiles.interopTestsSHA256' "$EVIDENCE")"
  verify_sha256 "$PROXY_MANAGER_SOURCE" \
    "$(jq -r '.sourceFiles.proxyManagerSHA256' "$EVIDENCE")"
  verify_sha256 "$CORE_MANIFEST" \
    "$(jq -r '.sourceFiles.coreManifestSHA256' "$EVIDENCE")"
  verify_sha256 "$FFI_MANIFEST" \
    "$(jq -r '.sourceFiles.ffiManifestSHA256' "$EVIDENCE")"
  verify_sha256 "$FFI_SOURCE" \
    "$(jq -r '.sourceFiles.ffiSourceSHA256' "$EVIDENCE")"
  verify_sha256 "$FLOW_FFI_SOURCE" \
    "$(jq -r '.sourceFiles.flowFFISourceSHA256' "$EVIDENCE")"

  jq -r '.interopCases[]' "$EVIDENCE" | while IFS= read -r case_name; do
    grep -F "name: \"$case_name\"" "$INTEROP_SOURCE" >/dev/null || {
      echo "core source is missing interop case: $case_name" >&2
      exit 1
    }
  done
  jq -r '.interopTests[]' "$EVIDENCE" | while IFS= read -r test_name; do
    grep -F "async fn $test_name" "$INTEROP_SOURCE" >/dev/null || {
      echo "core source is missing interop test: $test_name" >&2
      exit 1
    }
  done
  jq -r '.coreFeatures[]' "$EVIDENCE" | while IFS= read -r feature; do
    grep -F "$feature =" "$CORE_MANIFEST" >/dev/null || {
      echo "core source is missing feature: $feature" >&2
      exit 1
    }
  done
  jq -r '.ffiFeatures[]' "$EVIDENCE" | while IFS= read -r feature; do
    grep -F "\"$feature\"" "$FFI_MANIFEST" >/dev/null || {
      echo "clash-ffi source is missing feature: $feature" >&2
      exit 1
    }
  done
fi

if grep -F 'readiness: .verified' "$CATALOG" >/dev/null; then
  echo "ProtocolCatalog cannot be verified while common release gates remain" >&2
  exit 1
fi

protocol_count=$(jq '.protocols | length' "$MATRIX")
case_count=$(jq '[.protocols[].interopCases[]] | length' "$MATRIX")
test_count=$(jq '[.protocols[].interopTests[]] | length' "$MATRIX")
gap_count=$(jq '[.protocols[].uncoveredCatalogClaims[]] | length' "$MATRIX")
echo "Protocol release matrix verified: protocols=$protocol_count interop_cases=$case_count independent_tests=$test_count uncovered_claims=$gap_count status=integration"
