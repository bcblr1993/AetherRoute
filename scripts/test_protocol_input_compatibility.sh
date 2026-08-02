#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MATRIX="$ROOT/Config/ProtocolInputCompatibility.json"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-protocol-inputs.XXXXXX")
chmod 700 "$TEMP_DIR"
cleanup() {
  find "$TEMP_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

jq -e '
  . as $matrix
  | .schemaVersion == 1
  and (.cases | length >= 48)
  and ([.cases[].protocol] | unique | length) == 12
  and (([.cases[].id] | length) == ([$matrix.cases[].id] | unique | length))
  and all(.cases[];
    (.id | test("^[a-z0-9]+(-[a-z0-9]+)*$"))
    and (.variant | length > 0)
    and (.source | startswith("https://")))
' "$MATRIX" >/dev/null

swiftc -parse-as-library \
  "$ROOT/Sources/AetherRouteKit/ProfileImportValidator.swift" \
  "$ROOT/Sources/AetherRouteKit/AetherNode.swift" \
  "$ROOT/Sources/AetherRouteKit/SubscriptionPayloadNormalizer.swift" \
  "$ROOT/Tests/ProtocolInputs/main.swift" \
  -o "$TEMP_DIR/protocol_input_verifier"

mkdir -m 700 "$TEMP_DIR/profiles"
"$TEMP_DIR/protocol_input_verifier" "$MATRIX" "$TEMP_DIR/profiles"

COMMON_FLAGS="-std=c17 -Wall -Wextra -Werror -mmacosx-version-min=14.0"
clang $COMMON_FLAGS \
  -DAETHER_EXTERNAL_FLOW_ONLY \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/external_profile_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" \
  -framework Security \
  -framework SystemConfiguration \
  -framework CoreFoundation \
  -framework CoreServices \
  -lresolv \
  -o "$TEMP_DIR/flow_profile_smoke"

clang $COMMON_FLAGS \
  -DAETHER_EXTERNAL_PACKET \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/external_profile_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" \
  -framework Security \
  -framework SystemConfiguration \
  -framework CoreFoundation \
  -framework CoreServices \
  -lresolv \
  -o "$TEMP_DIR/packet_profile_smoke"

mkdir -m 700 "$TEMP_DIR/runtime"
failures=0
count=0
for profile in "$TEMP_DIR"/profiles/*.yaml; do
  count=$((count + 1))
  case_id=$(basename "$profile" .yaml)
  if ! /usr/bin/sandbox-exec \
    -p '(version 1) (allow default) (deny network*)' \
    "$TEMP_DIR/flow_profile_smoke" "$profile" "$TEMP_DIR/runtime" \
    >/dev/null; then
    echo "$case_id flow-only=fail" >&2
    failures=$((failures + 1))
  fi
  if ! /usr/bin/sandbox-exec \
    -p '(version 1) (allow default) (deny network*)' \
    "$TEMP_DIR/packet_profile_smoke" "$profile" "$TEMP_DIR/runtime" \
    >/dev/null; then
    echo "$case_id packet-tunnel=fail" >&2
    failures=$((failures + 1))
  fi
done

expected=$(jq '.cases | length' "$MATRIX")
test "$count" -eq "$expected" || {
  echo "protocol input gate expected $expected cases, found $count" >&2
  exit 1
}
test "$failures" -eq 0 || {
  echo "protocol input gate failed on $failures core surface(s)" >&2
  exit 1
}
echo "Protocol input compatibility verified: cases=$count core_surfaces=$((count * 2)) network=denied"
