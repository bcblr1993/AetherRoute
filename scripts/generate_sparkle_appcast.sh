#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DMG_PATH=${1:-}
RELEASE_URL=${2:-}
NOTES=${3:-}

if [ -z "$DMG_PATH" ] || [ -z "$NOTES" ]; then
  echo "usage: $0 /path/to/AetherRoute-<version>-build-<build>-arm64.dmg [release_download_url] <release_notes_html_or_file>" >&2
  exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
  echo "DMG file not found: $DMG_PATH" >&2
  exit 1
fi

DMG_BASENAME=$(basename "$DMG_PATH")
if ! printf '%s\n' "$DMG_BASENAME" | grep -Eq '^AetherRoute-[0-9]+\.[0-9]+(\.[0-9]+)?-build-[0-9]+'; then
  echo "DMG filename does not match required pattern 'AetherRoute-<version>-build-<build>-...': $DMG_BASENAME" >&2
  exit 1
fi

PRIV_KEY=${AETHERROUTE_SPARKLE_PRIV_KEY:-"$ROOT/Config/sparkle_ed25519_priv.key"}
PUB_KEY=${AETHERROUTE_SPARKLE_PUB_KEY:-"$ROOT/Config/sparkle_ed25519_pub.key"}

if [ ! -f "$PRIV_KEY" ] || [ ! -f "$PUB_KEY" ]; then
  echo "Sparkle Ed25519 keys not found. Run scripts/generate_sparkle_key.sh first." >&2
  exit 1
fi

OUTPUT_APPCAST=${AETHERROUTE_OUTPUT_APPCAST:-"$ROOT/appcast.xml"}
WEB_APPCAST=${AETHERROUTE_WEB_APPCAST:-"$ROOT/Services/WebDistribution/public/appcast.xml"}

# Try finding Sparkle's official sign_update binary when using standard keys
SIGN_UPDATE_BIN=""
if [ -z "${AETHERROUTE_SPARKLE_PRIV_KEY:-}" ]; then
  for candidate in \
    "$ROOT/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
    "$ROOT/build/Debug/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
    "$ROOT/.build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
    "$ROOT/.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
  do
    if [ -x "$candidate" ]; then
      SIGN_UPDATE_BIN="$candidate"
      break
    fi
  done
fi

PRECOMPUTED_SIG=""
if [ -n "$SIGN_UPDATE_BIN" ]; then
  echo "Found official Sparkle sign_update tool: $SIGN_UPDATE_BIN"
  PRECOMPUTED_SIG=$("$SIGN_UPDATE_BIN" -p -f "$PRIV_KEY" "$DMG_PATH")
  "$SIGN_UPDATE_BIN" --verify "$DMG_PATH" "$PRECOMPUTED_SIG" -f "$PRIV_KEY"
  echo "Verified signature with official Sparkle tool: $PRECOMPUTED_SIG"
fi

swift - "$DMG_PATH" "$PRIV_KEY" "$PUB_KEY" "$OUTPUT_APPCAST" "$RELEASE_URL" "$NOTES" "$PRECOMPUTED_SIG" << 'SWIFT_CODE'
import Foundation
import CryptoKit

let args = CommandLine.arguments
guard args.count >= 7 else {
    fputs("Error: Invalid arguments passed to Sparkle appcast generator\n", stderr)
    exit(1)
}

let dmgPath = args[1]
let privKeyPath = args[2]
let pubKeyPath = args[3]
let appcastPath = args[4]
let customReleaseURL = !args[5].isEmpty ? args[5] : nil
let notesInput = args[6].trimmingCharacters(in: .whitespacesAndNewlines)
let precomputedSig = args.count > 7 && !args[7].isEmpty ? args[7] : nil

guard !notesInput.isEmpty else {
    fputs("Error: Release notes HTML or file path is required and cannot be empty\n", stderr)
    exit(1)
}

let dmgURL = URL(fileURLWithPath: dmgPath)
let dmgFilename = dmgURL.lastPathComponent

let regex = try! NSRegularExpression(pattern: #"^AetherRoute-([0-9]+\.[0-9]+(?:\.[0-9]+)?)-build-([0-9]+)"#)
let nameRange = NSRange(dmgFilename.startIndex..<dmgFilename.endIndex, in: dmgFilename)
guard let match = regex.firstMatch(in: dmgFilename, range: nameRange),
      let vRange = Range(match.range(at: 1), in: dmgFilename),
      let bRange = Range(match.range(at: 2), in: dmgFilename) else {
    fputs("Error: Could not extract version and build from DMG filename '\(dmgFilename)'\n", stderr)
    exit(1)
}
let version = String(dmgFilename[vRange])
let build = String(dmgFilename[bRange])

let rawPriv = try String(contentsOfFile: privKeyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let rawPub = try String(contentsOfFile: pubKeyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

guard let privData = Data(base64Encoded: rawPriv),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privData) else {
    fputs("Error: Invalid private key\n", stderr)
    exit(1)
}

let dmgData = try Data(contentsOf: dmgURL)
let dmgLength = dmgData.count

guard let pubData = Data(base64Encoded: rawPub),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData) else {
    fputs("Error: Invalid public key\n", stderr)
    exit(1)
}

let finalSig: String
if let precomputedSig = precomputedSig, !precomputedSig.isEmpty {
    guard let precomputedData = Data(base64Encoded: precomputedSig),
          publicKey.isValidSignature(precomputedData, for: dmgData) else {
        fputs("Error: Precomputed Sparkle sign_update signature failed public key verification\n", stderr)
        exit(1)
    }
    finalSig = precomputedSig
} else {
    let signature = try privateKey.signature(for: dmgData)
    guard publicKey.isValidSignature(signature, for: dmgData) else {
        fputs("Error: CryptoKit signature verification failed\n", stderr)
        exit(1)
    }
    finalSig = signature.base64EncodedString()
}

let downloadURL = customReleaseURL ?? "https://github.com/bcblr1993/AetherRoute/releases/download/v\(version)/\(dmgFilename)"

let rfc822Formatter = DateFormatter()
rfc822Formatter.locale = Locale(identifier: "en_US_POSIX")
rfc822Formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
let pubDate = rfc822Formatter.string(from: Date())

func xmlEscapeAttribute(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

func escapeCDATA(_ value: String) -> String {
    value.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
}

func wrapWithAppleStyle(content: String, version: String, build: String) -> String {
    if content.contains("<style>") {
        return content
    }
    let hasHeader = content.contains("release-header")
    let hasFooter = content.contains("footer-bar")

    let headerBlock = hasHeader ? "" : """
<div class="release-header">
  <span class="release-title">AetherRoute \(version) 更新要点</span>
  <span class="release-badge">Build \(build) · 正式发布</span>
</div>

"""
    let footerBlock = hasFooter ? "" : """

<div class="footer-bar">
  <span>已通过 Apple 官方公证 · Ed25519 签名验证</span>
  <a class="footer-link" href="https://aethernative.com/apps/aetherroute/releases/\(version)/" target="_blank">查看网页完整更新日志 ↗</a>
</div>
"""

    return """
<style>
  :root {
    color-scheme: light dark;
    --font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif;
    --border-color: rgba(0, 0, 0, 0.08);
    --text-main: #111827;
    --text-sub: #374151;
    --text-muted: #6B7280;
    --tag-bg-blue: #EFF6FF; --tag-text-blue: #1D4ED8; --tag-border-blue: #DBEAFE;
    --tag-bg-green: #ECFDF5; --tag-text-green: #047857; --tag-border-green: #D1FAE5;
    --tag-bg-red: #FEF2F2; --tag-text-red: #B91C1C; --tag-border-red: #FEE2E2;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --border-color: rgba(255, 255, 255, 0.1);
      --text-main: #F9FAFB;
      --text-sub: #D1D5DB;
      --text-muted: #9CA3AF;
      --tag-bg-blue: rgba(59, 130, 246, 0.18); --tag-text-blue: #60A5FA; --tag-border-blue: rgba(96, 165, 250, 0.3);
      --tag-bg-green: rgba(16, 185, 129, 0.18); --tag-text-green: #34D399; --tag-border-green: rgba(52, 211, 153, 0.3);
      --tag-bg-red: rgba(239, 68, 68, 0.18); --tag-text-red: #F87171; --tag-border-red: rgba(248, 113, 113, 0.3);
    }
  }
  body {
    font-family: var(--font);
    font-size: 13px;
    line-height: 1.55;
    color: var(--text-sub);
    margin: 0;
    padding: 12px 14px;
    background: transparent;
    -webkit-font-smoothing: antialiased;
  }
  .release-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 12px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--border-color);
  }
  .release-title {
    font-size: 14px;
    font-weight: 700;
    color: var(--text-main);
  }
  .release-badge {
    font-size: 11px;
    color: var(--text-muted);
  }
  .section {
    margin-bottom: 14px;
  }
  .section-tag {
    display: inline-block;
    padding: 1px 7px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 700;
    margin-bottom: 6px;
    border: 1px solid transparent;
  }
  .tag-feature { background: var(--tag-bg-blue); color: var(--tag-text-blue); border-color: var(--tag-border-blue); }
  .tag-improve { background: var(--tag-bg-green); color: var(--tag-text-green); border-color: var(--tag-border-green); }
  .tag-fix { background: var(--tag-bg-red); color: var(--tag-text-red); border-color: var(--tag-border-red); }
  ul {
    margin: 0;
    padding-left: 16px;
  }
  li {
    margin-bottom: 6px;
  }
  li:last-child {
    margin-bottom: 0;
  }
  li strong {
    color: var(--text-main);
    font-weight: 600;
  }
  code {
    font-size: 11px;
    padding: 1px 4px;
    border-radius: 3px;
    background: rgba(127, 127, 127, 0.12);
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
  }
  .footer-bar {
    margin-top: 14px;
    padding-top: 10px;
    border-top: 1px solid var(--border-color);
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 11px;
    color: var(--text-muted);
  }
  .footer-link {
    color: #0066FF;
    text-decoration: none;
    font-weight: 600;
  }
  .footer-link:hover {
    text-decoration: underline;
  }
</style>

\(headerBlock)\(content)\(footerBlock)
"""
}

let rawNotesContent: String
let looksLikeFilePath = !notesInput.contains("<") && (
    notesInput.hasPrefix("/") ||
    notesInput.hasPrefix("./") ||
    notesInput.hasPrefix("../") ||
    notesInput.hasSuffix(".html") ||
    notesInput.hasSuffix(".md") ||
    notesInput.hasSuffix(".txt")
)
if FileManager.default.fileExists(atPath: notesInput) {
    rawNotesContent = try String(contentsOfFile: notesInput, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawNotesContent.isEmpty else {
        fputs("Error: Release notes file is empty: \(notesInput)\n", stderr)
        exit(1)
    }
} else if looksLikeFilePath {
    fputs("Error: Release notes file not found: \(notesInput)\n", stderr)
    exit(1)
} else {
    rawNotesContent = notesInput
}

let releaseNotesHTML = escapeCDATA(
    wrapWithAppleStyle(content: rawNotesContent, version: version, build: build)
)
let safeDownloadURL = xmlEscapeAttribute(downloadURL)
let safeSig = xmlEscapeAttribute(finalSig)

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
            <sparkle:fullReleaseNotesLink xml:lang="en">https://aethernative.com/apps/aetherroute/releases/\(version)/</sparkle:fullReleaseNotesLink>
            <description xml:lang="en"><![CDATA[
\(releaseNotesHTML)
            ]]></description>
            <enclosure
                url="\(safeDownloadURL)"
                sparkle:edSignature="\(safeSig)"
                length="\(dmgLength)"
                type="application/octet-stream" />
        </item>
    </channel>
</rss>
"""

_ = try XMLDocument(xmlString: appcastXML, options: [])
try appcastXML.write(toFile: appcastPath, atomically: true, encoding: .utf8)
print("Successfully generated appcast.xml:")
print("  Version: \(version) (Build \(build))")
print("  File: \(dmgFilename) (\(dmgLength) bytes)")
print("  Download: \(downloadURL)")
print("  Ed25519: \(finalSig)")
print("  Saved to: \(appcastPath)")
SWIFT_CODE

xmllint --noout "$OUTPUT_APPCAST"

if [ -f "$WEB_APPCAST" ] && [ "$OUTPUT_APPCAST" != "$WEB_APPCAST" ]; then
  cp "$OUTPUT_APPCAST" "$WEB_APPCAST"
  echo "Synchronized appcast to: $WEB_APPCAST"
fi
