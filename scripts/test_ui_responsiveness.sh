#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASK_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-ui-responsiveness.XXXXXX")
trap 'find "$TASK_TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

OUTPUT=${1:-}
if [ -z "$OUTPUT" ]; then
  echo "usage: $0 /absolute/ui-responsiveness-output" >&2
  exit 64
fi
case "$OUTPUT" in
  /*) ;;
  *) echo "UI responsiveness output path must be absolute" >&2; exit 64 ;;
esac
if [ -e "$OUTPUT" ]; then
  echo "Refusing to overwrite UI responsiveness output: $OUTPUT" >&2
  exit 1
fi
if [ "$(uname -m)" != arm64 ]; then
  echo "UI responsiveness validation requires Apple silicon" >&2
  exit 1
fi

for command in awk find shasum xcodebuild; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "UI responsiveness validation requires $command" >&2
    exit 1
  }
done

network_snapshot() {
  {
    /usr/sbin/scutil --proxy
    /usr/sbin/scutil --dns
    /usr/sbin/netstat -rn -f inet | awk '$1 == "default" {print}'
    /usr/sbin/netstat -rn -f inet6 | awk '$1 == "default" {print}'
    /sbin/ifconfig -l
  }
}

mkdir -p "$OUTPUT"
"$ROOT/scripts/source_manifest.sh" >"$OUTPUT/source-manifest.txt"
network_snapshot >"$OUTPUT/network-before.txt"
started_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

ui_exit=0
env \
  AETHERROUTE_RUN_UI_RESPONSIVENESS=YES \
  AETHERROUTE_UI_TEST_CONFIGURATION=Release \
  AETHERROUTE_UI_TEST_ONLY='AetherRouteUITests/AetherRouteUITests/testBilingualNavigationResponsiveness' \
  AETHERROUTE_UI_RESPONSIVENESS_SECONDS="${AETHERROUTE_UI_RESPONSIVENESS_SECONDS:-1800}" \
  AETHERROUTE_UI_RESPONSIVENESS_SMOKE="${AETHERROUTE_UI_RESPONSIVENESS_SMOKE:-NO}" \
  AETHERROUTE_UI_RESPONSIVENESS_MAX_P95_MS=120 \
  AETHERROUTE_UI_RESPONSIVENESS_EVIDENCE="$OUTPUT" \
  "$ROOT/scripts/test_ui.sh" >"$OUTPUT/ui-test.log" 2>&1 || ui_exit=$?

finished_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
network_snapshot >"$OUTPUT/network-after.txt"
"$ROOT/scripts/source_manifest.sh" >"$OUTPUT/source-manifest-after.txt"
source_unchanged=true
network_unchanged=true
cmp -s "$OUTPUT/source-manifest.txt" "$OUTPUT/source-manifest-after.txt" \
  || source_unchanged=false
cmp -s "$OUTPUT/network-before.txt" "$OUTPUT/network-after.txt" \
  || network_unchanged=false

{
  printf 'started_utc=%s\n' "$started_utc"
  printf 'finished_utc=%s\n' "$finished_utc"
  printf 'ui_test_status=%s\n' "$ui_exit"
  printf 'source_unchanged=%s\n' "$source_unchanged"
  printf 'network_unchanged=%s\n' "$network_unchanged"
} >"$OUTPUT/controller-result.txt"

if [ "$ui_exit" -eq 0 ] && [ -f "$OUTPUT/result.txt" ]; then
  {
    printf 'machine=%s\n' "$(uname -m)"
    printf 'os=%s\n' "$(sw_vers -productVersion)"
    printf 'configuration=Release\n'
    printf 'app_probe=compiled\n'
    printf 'system_network_settings=unchanged\n'
    printf 'source_unchanged=%s\n' "$source_unchanged"
    printf 'test_status=%s\n' "$ui_exit"
    printf 'source_manifest_sha256=%s\n' \
      "$(awk '$1 == "MANIFEST_SHA256" {print $2}' "$OUTPUT/source-manifest.txt")"
    printf 'runner_sha256=%s\n' \
      "$(shasum -a 256 "$ROOT/scripts/test_ui_responsiveness.sh" | awk '{print $1}')"
    printf 'verifier_sha256=%s\n' \
      "$(shasum -a 256 "$ROOT/scripts/verify_ui_responsiveness_result.sh" | awk '{print $1}')"
  } >>"$OUTPUT/result.txt"
fi

(
  cd "$OUTPUT"
  shasum -a 256 \
    result.txt navigation-samples.csv ui-test.log \
    network-before.txt network-after.txt \
    source-manifest.txt source-manifest-after.txt controller-result.txt \
    >SHA256SUMS 2>/dev/null || true
)

if [ "$ui_exit" -ne 0 ]; then
  tail -180 "$OUTPUT/ui-test.log" >&2
  echo "UI responsiveness test failed; evidence preserved at $OUTPUT" >&2
  exit "$ui_exit"
fi
test "$source_unchanged" = true || {
  echo "Source changed during UI responsiveness validation" >&2
  exit 1
}
test "$network_unchanged" = true || {
  echo "System network state changed during UI responsiveness validation" >&2
  exit 1
}

if [ "${AETHERROUTE_UI_RESPONSIVENESS_SMOKE:-NO}" = YES ]; then
  "$ROOT/scripts/verify_ui_responsiveness_result.sh" --smoke "$OUTPUT"
else
  "$ROOT/scripts/verify_ui_responsiveness_result.sh" "$OUTPUT"
fi
cat "$OUTPUT/result.txt"
echo "UI responsiveness gate passed: output=$OUTPUT"
