#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/generate_sparkle_appcast.sh"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aether-appcast-test.XXXXXX")
cleanup() {
  find "$TEMP_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

# Generate ephemeral Ed25519 keypair in TEMP_DIR via Swift CryptoKit
swift - "$TEMP_DIR/priv.key" "$TEMP_DIR/pub.key" << 'SWIFT'
import Foundation
import CryptoKit
let priv = Curve25519.Signing.PrivateKey()
try priv.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
try priv.publicKey.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
SWIFT

GOOD_DMG="$TEMP_DIR/AetherRoute-3.0.2-build-2026111702-arm64.dmg"
BAD_DMG="$TEMP_DIR/AetherRoute-custom-preview.dmg"
printf 'dummy-dmg-payload\n' > "$GOOD_DMG"
printf 'dummy-dmg-payload\n' > "$BAD_DMG"

OUT_XML="$TEMP_DIR/appcast.xml"
WEB_XML="$TEMP_DIR/web-appcast.xml"
printf '<rss/>' > "$WEB_XML"

run_gen() {
  AETHERROUTE_SPARKLE_PRIV_KEY="$TEMP_DIR/priv.key" \
  AETHERROUTE_SPARKLE_PUB_KEY="$TEMP_DIR/pub.key" \
  AETHERROUTE_OUTPUT_APPCAST="$OUT_XML" \
  AETHERROUTE_WEB_APPCAST="$WEB_XML" \
  "$SCRIPT" "$@"
}

# 1. Version/build regex mismatch must fail closed (never fallback to 1.0.0)
if run_gen "$BAD_DMG" "" "<p>Notes</p>" >/dev/null 2>&1; then
  echo "FAIL: generate_sparkle_appcast.sh accepted filename without version/build" >&2
  exit 1
fi

# 2. Missing release notes parameter must fail closed (never emit hardcoded legacy notes)
if run_gen "$GOOD_DMG" >/dev/null 2>&1; then
  echo "FAIL: generate_sparkle_appcast.sh accepted missing release notes parameter" >&2
  exit 1
fi

if run_gen "$GOOD_DMG" "" "" >/dev/null 2>&1; then
  echo "FAIL: generate_sparkle_appcast.sh accepted empty release notes parameter" >&2
  exit 1
fi

# 3. CDATA injection sequence ']]>' must be escaped and produce valid single-item XML
INJECT_NOTES="$TEMP_DIR/notes.html"
cat > "$INJECT_NOTES" << 'EOF'
<div class="section">
  <p>Edge case payload: ]]> </description><enclosure url="https://evil.invalid/pwn.dmg" /></item><item><description><![CDATA[ tail</p>
</div>
EOF

run_gen "$GOOD_DMG" "https://downloads.aethernative.com/AetherRoute-3.0.2-build-2026111702-arm64.dmg" "$INJECT_NOTES" >/dev/null

xmllint --noout "$OUT_XML"
cmp -s "$OUT_XML" "$WEB_XML"

PYTHONDONTWRITEBYTECODE=1 python3 - "$OUT_XML" << 'PY'
import sys
import xml.etree.ElementTree as ET

tree = ET.parse(sys.argv[1])
root = tree.getroot()
items = root.findall("./channel/item")
assert len(items) == 1, f"Expected exactly 1 <item>, got {len(items)}"
enclosures = items[0].findall("enclosure")
assert len(enclosures) == 1, f"Expected exactly 1 <enclosure>, got {len(enclosures)}"
assert enclosures[0].attrib["url"] == "https://downloads.aethernative.com/AetherRoute-3.0.2-build-2026111702-arm64.dmg"
desc = items[0].findtext("description") or ""
assert "]]>" in desc, "Original literal ']]>' text was not preserved inside decoded description"
assert "3.0.2" in (items[0].findtext("{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString") or "")
assert "2026111702" == (items[0].findtext("{http://www.andymatuschak.org/xml-namespaces/sparkle}version") or "")
PY

echo "PASS: Sparkle appcast generator guards and CDATA escaping verified."
