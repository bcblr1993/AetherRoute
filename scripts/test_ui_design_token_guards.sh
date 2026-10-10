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
.width(min: 56, ideal: 60, max: 100)
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
.width(min: 56, ideal: 60, max: 100)
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

write_valid_source
printf '\n.font(.system(size: 12.5, weight: .medium))\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'literal font sizes are forbidden' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_valid_source
printf '\n.fill(Color(red: 0.2, green: 0.8, blue: 0.4))\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'custom RGB colors are forbidden outside AetherVisual' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_valid_source
printf '\n.shadow(color: .black, radius: 4)\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'shadows and glows are forbidden' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

# A size relative to its container is how a scalable icon is drawn, not a
# stray literal, and must keep passing.
write_valid_source
printf '\n.font(.system(size: size * 0.44, weight: .semibold))\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
"$FIXTURE/scripts/verify_ui_design_tokens.sh" >"$TEMP/output.log"
grep -Fq 'UI design tokens verified.' "$TEMP/output.log"

write_unlocalized_source
expect_failure 1 'localized Duration header needs its 56...100pt column budget' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

printf 'Text("Duration")\n' >"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'localized Duration header needs its 56...100pt column budget' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_valid_source
printf '\nSpacer(minLength: 12)\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'spacer minimums must use AetherVisual spacing tokens' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_valid_source
printf '\n.background(.red, in: RoundedRectangle(cornerRadius: AetherVisual.s3))\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'corner radii must use a radius token' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_valid_source
printf '\nAetherIconTile(symbol: "x", color: .blue, size: 28)\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'icon tiles take one of the five AetherVisual tile sizes' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_valid_source
printf '\n.background(Color.secondary.opacity(0.1), in: Capsule())\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'drawn grey backgrounds use AetherVisual' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_valid_source
printf '\nButton("Cancel") {}\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'interface copy goes through AppLocalization.string' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_valid_source
printf '\nText(rate).contentTransition(.numericText())\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'rolling digits use aetherNumericValue' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_valid_source
printf '\nToggle("", isOn: $isOn)\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'interface copy goes through AppLocalization.string' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_valid_source
printf '\nCommandMenu("Navigate") {}\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'interface copy goes through AppLocalization.string' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_valid_source
printf '\nText(isTCP ? "TCP" : "UDP")\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'a ternary of literals is a LocalizedStringKey too' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

# Verbatim text is how names and protocol labels are drawn and must pass.
write_valid_source
printf '\nText(verbatim: isTCP ? "TCP" : "UDP")\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
"$FIXTURE/scripts/verify_ui_design_tokens.sh" >"$TEMP/output.log"
grep -Fq 'UI design tokens verified.' "$TEMP/output.log"

write_valid_source
printf '\n.fill(Color.red.opacity(0.3))\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'colour opacities come from AetherVisual fills' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_valid_source
printf '\nDivider().opacity(0.4)\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'dividers use the system separator' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_valid_source
printf '\n.frame(minHeight: 44)\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'row heights use AetherVisual' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

write_valid_source
printf '\nText("x").foregroundStyle(.red)\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'state colours on text and symbols use AetherReadableTint' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"

# Two violations of different rules must both be reported, not just the
# first one found.
write_valid_source
printf '\n.padding(15)\n.shadow(color: .black, radius: 4)\n' >>"$FIXTURE/Sources/AetherRouteApp/ConnectionsPageView.swift"
expect_failure 1 'shadows and glows are forbidden' \
  "$FIXTURE/scripts/verify_ui_design_tokens.sh"
grep -Fq 'off-grid 15/18/22/26/28pt padding is forbidden' "$TEMP/output.log" || {
  cat "$TEMP/output.log" >&2
  echo 'Design-token guard regression: only the first violated rule was reported' >&2
  exit 1
}
grep -Fq '3 rule(s) violated' "$TEMP/output.log" || {
  cat "$TEMP/output.log" >&2
  echo 'Design-token guard regression: violation count missing' >&2
  exit 1
}

echo 'UI design-token guards passed: valid source, missing rg, scan failure, PCRE2 failure, forbidden token, literal font size, custom RGB colour, shadow, relative icon size, unlocalized header, missing column budget, spacer minimum, spacing token as radius, tile size, grey fill, literal copy, raw rolling digits, empty toggle label, literal command menu, literal ternary, verbatim ternary, colour opacity, faded divider, row height, raw state colour and multiple violations reported together.'
