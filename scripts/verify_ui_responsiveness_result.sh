#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EXPECTED_STATUS=passed
if [ "${1:-}" = --smoke ]; then
  EXPECTED_STATUS=smoke
  shift
fi
OUTPUT=${1:-}
if [ -z "$OUTPUT" ] || [ ! -d "$OUTPUT" ]; then
  echo "usage: $0 [--smoke] /absolute/ui-responsiveness-output" >&2
  exit 64
fi
case "$OUTPUT" in
  /*) ;;
  *) echo "UI responsiveness output path must be absolute" >&2; exit 64 ;;
esac

TASK_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-ui-response-verifier.XXXXXX")
trap 'find "$TASK_TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

for file in \
  result.txt navigation-samples.csv ui-test.log \
  network-before.txt network-after.txt \
  source-manifest.txt source-manifest-after.txt controller-result.txt \
  SHA256SUMS
do
  test -f "$OUTPUT/$file" || {
    echo "Missing UI responsiveness evidence: $file" >&2
    exit 1
  }
done
(
  cd "$OUTPUT"
  shasum -a 256 -c SHA256SUMS >/dev/null
)

value() {
  key=$1
  awk -F= -v wanted="$key" \
    '$1 == wanted {print substr($0, length($1) + 2); exit}' \
    "$OUTPUT/result.txt"
}
require_equal() {
  key=$1
  expected=$2
  actual=$(value "$key")
  if [ "$actual" != "$expected" ]; then
    echo "Invalid UI responsiveness $key: expected $expected, got $actual" >&2
    exit 1
  fi
}
require_number_at_least() {
  key=$1
  minimum=$2
  actual=$(value "$key")
  awk -v actual="$actual" -v minimum="$minimum" \
    'BEGIN { exit !(actual ~ /^[0-9]+([.][0-9]+)?$/ && actual + 0 >= minimum + 0) }' || {
      echo "UI responsiveness $key below $minimum: $actual" >&2
      exit 1
    }
}
require_number_at_most() {
  key=$1
  maximum=$2
  actual=$(value "$key")
  awk -v actual="$actual" -v maximum="$maximum" \
    'BEGIN { exit !(actual ~ /^[0-9]+([.][0-9]+)?$/ && actual + 0 <= maximum + 0) }' || {
      echo "UI responsiveness $key above $maximum: $actual" >&2
      exit 1
    }
}

require_equal schema 1
require_equal status "$EXPECTED_STATUS"
require_equal machine arm64
require_equal configuration Release
require_equal languages en,zh-Hans
require_equal main_pages 6
require_equal settings_pages 7
require_equal network_extension disabled
require_equal app_probe compiled
require_equal system_network_settings unchanged
require_equal source_unchanged true
require_equal test_status 0
require_equal maximum_p95_action_ms 120.000
require_number_at_least bilingual_cycles 1
require_number_at_least sample_count 28
require_number_at_most p95_action_ms 120

if [ "$EXPECTED_STATUS" = passed ]; then
  require_number_at_least requested_seconds 1800
  require_number_at_least elapsed_seconds 1800
else
  require_number_at_least requested_seconds 1
  require_number_at_least elapsed_seconds 1
fi

cmp -s "$OUTPUT/network-before.txt" "$OUTPUT/network-after.txt" || {
  echo "System network state changed during UI responsiveness validation" >&2
  exit 1
}
cmp -s "$OUTPUT/source-manifest.txt" "$OUTPUT/source-manifest-after.txt" || {
  echo "Source changed during UI responsiveness validation" >&2
  exit 1
}
"$ROOT/scripts/source_manifest.sh" >"$TASK_TEMP/current-source-manifest.txt"
cmp -s "$OUTPUT/source-manifest.txt" "$TASK_TEMP/current-source-manifest.txt" || {
  echo "UI responsiveness evidence does not match the current source tree" >&2
  exit 1
}
require_equal source_manifest_sha256 \
  "$(awk '$1 == "MANIFEST_SHA256" {print $2}' "$OUTPUT/source-manifest.txt")"
require_equal runner_sha256 \
  "$(shasum -a 256 "$ROOT/scripts/test_ui_responsiveness.sh" | awk '{print $1}')"
require_equal verifier_sha256 \
  "$(shasum -a 256 "$ROOT/scripts/verify_ui_responsiveness_result.sh" | awk '{print $1}')"

header=$(sed -n '1p' "$OUTPUT/navigation-samples.csv")
test "$header" = 'sequence,language,action,duration_ms' || {
  echo "Invalid UI responsiveness CSV header" >&2
  exit 1
}
awk -F, '
  NR == 1 { next }
  NF != 4 { exit 1 }
  $1 !~ /^[0-9]+$/ || $1 + 0 < 1 { exit 1 }
  $2 != "en" && $2 != "zh-Hans" { exit 1 }
  $3 !~ /^(main|settings|language)[.][A-Za-z-]+$/ { exit 1 }
  $4 !~ /^[0-9]+([.][0-9]+)?$/ || $4 + 0 < 0 { exit 1 }
  { rows += 1 }
  END { exit !(rows > 0) }
' "$OUTPUT/navigation-samples.csv" || {
  echo "Malformed UI responsiveness CSV" >&2
  exit 1
}

sample_count=$(($(wc -l <"$OUTPUT/navigation-samples.csv") - 1))
test "$sample_count" -eq "$(value sample_count)" || {
  echo "UI responsiveness sample count mismatch" >&2
  exit 1
}

for language in en zh-Hans; do
  for action in \
    main.overview main.proxies main.connections main.profiles main.rules main.dns \
    settings.general settings.privacy settings.bypass settings.diagnostics \
    settings.account settings.licenses settings.about
  do
    awk -F, -v language="$language" -v action="$action" \
      '$2 == language && $3 == action {found = 1} END {exit !found}' \
      "$OUTPUT/navigation-samples.csv" || {
        echo "Missing UI responsiveness sample: $language $action" >&2
        exit 1
      }
  done
done

LC_ALL=C awk -F, 'NR > 1 {print $4}' "$OUTPUT/navigation-samples.csv" \
  | sort -n >"$TASK_TEMP/durations.txt"
recomputed_p95=$(
  awk '
    { values[NR] = $1 }
    END {
      position = int((NR * 0.95) + 0.999999)
      if (position < 1) position = 1
      if (position > NR) position = NR
      printf "%.3f\n", values[position]
    }
  ' "$TASK_TEMP/durations.txt"
)
test "$recomputed_p95" = "$(value p95_action_ms)" || {
  echo "UI responsiveness p95 mismatch" >&2
  exit 1
}

echo "UI responsiveness evidence verified: $OUTPUT"
