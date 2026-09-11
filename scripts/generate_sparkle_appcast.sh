#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DMG_PATH=${1:-}
RELEASE_URL=${2:-}
NOTES=${3:-}

if [ -z "$DMG_PATH" ]; then
  echo "usage: $0 /path/to/AetherRoute.dmg [release_download_url] [release_notes_html]" >&2
  exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
  echo "DMG file not found: $DMG_PATH" >&2
  exit 1
fi

PRIV_KEY="$ROOT/Config/sparkle_ed25519_priv.key"
PUB_KEY="$ROOT/Config/sparkle_ed25519_pub.key"

if [ ! -f "$PRIV_KEY" ] || [ ! -f "$PUB_KEY" ]; then
  echo "Sparkle Ed25519 keys not found. Run scripts/generate_sparkle_key.sh first." >&2
  exit 1
fi

OUTPUT_APPCAST="$ROOT/appcast.xml"

swift - "$DMG_PATH" "$PRIV_KEY" "$PUB_KEY" "$OUTPUT_APPCAST" "$RELEASE_URL" "$NOTES" << 'SWIFT_CODE'
import Foundation
import CryptoKit

let args = CommandLine.arguments
guard args.count >= 5 else {
    print("Invalid arguments passed to generator")
    exit(1)
}

let dmgPath = args[1]
let privKeyPath = args[2]
let pubKeyPath = args[3]
let appcastPath = args[4]
let customReleaseURL = args.count > 5 && !args[5].isEmpty ? args[5] : nil
let customNotes = args.count > 6 && !args[6].isEmpty ? args[6] : nil

let dmgURL = URL(fileURLWithPath: dmgPath)
let dmgFilename = dmgURL.lastPathComponent

// Extract version and build from filename or default
// Expected naming: AetherRoute-<version>-build-<build>-...
var version = "1.0.0"
var build = "2026091105"

let regex = try! NSRegularExpression(pattern: "AetherRoute-([0-9.]+)-build-([0-9]+)")
let nameRange = NSRange(dmgFilename.startIndex..<dmgFilename.endIndex, in: dmgFilename)
if let match = regex.firstMatch(in: dmgFilename, range: nameRange) {
    if let vRange = Range(match.range(at: 1), in: dmgFilename) {
        version = String(dmgFilename[vRange])
    }
    if let bRange = Range(match.range(at: 2), in: dmgFilename) {
        build = String(dmgFilename[bRange])
    }
}

let rawPriv = try String(contentsOfFile: privKeyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let rawPub = try String(contentsOfFile: pubKeyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

guard let privData = Data(base64Encoded: rawPriv),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privData) else {
    print("Error: Invalid private key")
    exit(1)
}

let dmgData = try Data(contentsOf: dmgURL)
let dmgLength = dmgData.count
let signature = try privateKey.signature(for: dmgData)
let sigBase64 = signature.base64EncodedString()

// Verify with public key
guard let pubData = Data(base64Encoded: rawPub),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData),
      publicKey.isValidSignature(signature, for: dmgData) else {
    print("Error: Signature verification failed")
    exit(1)
}

let downloadURL = customReleaseURL ?? "https://github.com/bcblr1993/AetherRoute/releases/download/v\(version)-build-\(build)/\(dmgFilename)"

let rfc822Formatter = DateFormatter()
rfc822Formatter.locale = Locale(identifier: "en_US_POSIX")
rfc822Formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
let pubDate = rfc822Formatter.string(from: Date())

let releaseNotesHTML = customNotes ?? """
<h2>AetherRoute \(version) (Build \(build))</h2>
<ul>
  <li>Hardened transparent proxy with loopback and RFC 1918 private subnet isolation.</li>
  <li>Enhanced subscription parsing with full Clash/Meta multi-node support.</li>
  <li>Modernized deep sapphire visual system and native typography.</li>
  <li>Added native Sparkle 2 automatic updates with Ed25519 signature verification.</li>
</ul>
"""

let appcastXML = """
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>AetherRoute Changelog</title>
        <link>https://github.com/bcblr1993/AetherRoute</link>
        <description>Most recent updates for AetherRoute</description>
        <language>en</language>
        <item>
            <title>Version \(version) (Build \(build))</title>
            <pubDate>\(pubDate)</pubDate>
            <sparkle:version>\(build)</sparkle:version>
            <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <description><![CDATA[
\(releaseNotesHTML)
            ]]></description>
            <enclosure
                url="\(downloadURL)"
                sparkle:edSignature="\(sigBase64)"
                length="\(dmgLength)"
                type="application/octet-stream" />
        </item>
    </channel>
</rss>
"""

try appcastXML.write(toFile: appcastPath, atomically: true, encoding: .utf8)
print("Successfully generated appcast.xml:")
print("  Version: \(version) (Build \(build))")
print("  File: \(dmgFilename) (\(dmgLength) bytes)")
print("  Download: \(downloadURL)")
print("  Ed25519: \(sigBase64)")
print("  Saved to: \(appcastPath)")
SWIFT_CODE
