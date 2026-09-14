#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-design-token-guards.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
REAL_RG=$(command -v rg)
FIXTURE="$TEMP/repository"
mkdir -p "$FIXTURE/scripts" "$FIXTURE/Sources/AetherRouteApp" "$TEMP/bin"
cp "$ROOT/scripts/verify_ui_design_tokens.sh" "$FIXTURE/scripts/"
ln -s "$(command -v dirname)" "$TEMP/bin/dirname"
printf '.padding(size * 0.097)\n' >"$FIXTURE/Sources/AetherRouteApp/AetherRouteVisualSystem.swift"

write_valid_source() {
  cat >"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift" <<'SWIFT'
TableColumn(AppLocalization.string("Duration")) { connection in
    Text(connection.duration)
}
.width(min: 64, ideal: 68, max: 76)
SWIFT
}

# A header that kept the budget but lost its localization must still fail: the
# guard exists to protect both properties, and the fixture above is the only
# thing that proves it.
write_unlocalized_source() {
  cat >"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift" <<'SWIFT'
TableColumn("Duration") { connection in
    Text(connection.duration)
}
.width(min: 64, ideal: 68, max: 76)
SWIFT
}

expect_failure() {
  expected_status=$1
  expected_message=$2
  shift 2
  status=0
  "$@" >"$TEMP/output.log" 2>&1 || status=$?
  if [ "$status" -ne "$expected_status" ] ||
    ! grep -Fq "$expected_message" "$TEMP/output.log"; then
    cat "$TEMP/output.log" >&2
    echo "Design-token guard regression: expected status $expected_status and $expected_message; got $status" >&2
    exit 1
  fi
}

write_valid_source
"$FIXTURE/scripts/verify_ui_design_tokens.sh" >"$TEMP/output.log"
grep -Fq 'UI design tokens verified.' "$TEMP/output.log"

expect_failure 1 'requires ripgrep (rg)' \
  env PATH="$TEMP/bin" /bin/sh "$FIXTURE/scripts/verify_ui_design_tokens.sh"

cat >"$TEMP/bin/rg" <<'SH'
#!/bin/sh
echo 'simulated ripgrep scan failure' >&2
exit 2
SH
chmod +x "$TEMP/bin/rg"
expect_failure 2 'rg exited with status 2' \
  env PATH="$TEMP/bin:$PATH" /bin/sh "$FIXTURE/scripts/verify_ui_design_tokens.sh"

cat >"$TEMP/bin/rg" <<'SH'
#!/bin/sh
for argument do
  if [ "$argument" = --pcre2 ]; then
    echo 'simulated PCRE2 unavailable' >&2
    exit 2
  fi
done
exec "$AETHERROUTE_TEST_REAL_RG" "$@"
SH
expect_failure 2 'rg exited with status 2' \
  env PATH="$TEMP/bin:$PATH" AETHERROUTE_TEST_REAL_RG="$REAL_RG" \
  /bin/sh "$FIXTURE/scripts/verify_ui_design_tokens.sh"

printf '\n.padding(15)\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'UI design-token violation:' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_unlocalized_source
expect_failure 1 'localized Duration header needs its 64...76pt column budget' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

printf 'Text("Duration")\n' >"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'localized Duration header needs its 64...76pt column budget' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

echo 'UI design-token guards passed: valid source, missing rg, scan failure, PCRE2 failure, forbidden token, unlocalized header and missing column budget.'
