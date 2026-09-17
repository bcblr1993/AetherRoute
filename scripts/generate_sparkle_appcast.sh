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
WEB_APPCAST="$ROOT/Services/WebDistribution/public/appcast.xml"

# Try finding Sparkle's official sign_update binary
SIGN_UPDATE_BIN=""
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
let precomputedSig = args.count > 7 && !args[7].isEmpty ? args[7] : nil

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

guard let pubData = Data(base64Encoded: rawPub),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData) else {
    print("Error: Invalid public key")
    exit(1)
}

let finalSig: String
if let precomputedSig = precomputedSig, !precomputedSig.isEmpty {
    guard let precomputedData = Data(base64Encoded: precomputedSig),
          publicKey.isValidSignature(precomputedData, for: dmgData) else {
        print("Error: Precomputed Sparkle sign_update signature failed public key verification")
        exit(1)
    }
    finalSig = precomputedSig
} else {
    let signature = try privateKey.signature(for: dmgData)
    guard publicKey.isValidSignature(signature, for: dmgData) else {
        print("Error: CryptoKit signature verification failed")
        exit(1)
    }
    finalSig = signature.base64EncodedString()
}

let downloadURL = customReleaseURL ?? "https://github.com/bcblr1993/AetherRoute/releases/download/v\(version)/\(dmgFilename)"

let rfc822Formatter = DateFormatter()
rfc822Formatter.locale = Locale(identifier: "en_US_POSIX")
rfc822Formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
let pubDate = rfc822Formatter.string(from: Date())

func wrapWithAppleStyle(content: String, version: String, build: String) -> String {
    if content.contains("<style>") {
        return content
    }
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

<div class="release-header">
  <span class="release-title">AetherRoute \(version) 更新要点</span>
  <span class="release-badge">Build \(build) · 建议更新</span>
</div>
\(content)
<div class="footer-bar">
  <span>已通过 Apple 官方公证 · Ed25519 签名验证</span>
  <a class="footer-link" href="https://aetherroute.pages.dev/releases/\(version)/" target="_blank">查看网页完整更新日志 ↗</a>
</div>
"""
}

var rawNotesContent = customNotes
if let notesPath = customNotes, FileManager.default.fileExists(atPath: notesPath) {
    if let fileContent = try? String(contentsOfFile: notesPath, encoding: .utf8) {
        rawNotesContent = fileContent
    }
}

let defaultNotesContent = """
<div class="section">
  <span class="section-tag tag-feature">✨ 新增特性</span>
  <ul>
    <li><strong>开机自启动管理</strong>：基于 macOS 原生 SMAppService 深度集成开机自启动，支持状态动态感知与系统权限未批准引导。</li>
    <li><strong>连接意图持久化</strong>：引入独立线程安全意图存储层，严格区分用户主动操作与系统生命周期行为。</li>
    <li><strong>设置界面开机启动配置项</strong>：在通用设置中新增开机自启动切换开关与说明，中英文完备本地化。</li>
  </ul>
</div>
<div class="section">
  <span class="section-tag tag-improve">⚡️ 体验优化</span>
  <ul>
    <li><strong>退出/关机安全保护机制</strong>：退出与关机时安全切断 Network Extension 避免系统断网，同时完整保护原连接意图不被抹除。</li>
    <li><strong>冷启动与开机智能自动恢复</strong>：启动时智能检测上次连接状态，此前为连接态且满足条件时自动秒级恢复连接，此前为关闭态则保持关闭。</li>
  </ul>
</div>
<div class="section">
  <span class="section-tag tag-fix">🐞 稳定性验证</span>
  <ul>
    <li><strong>虚拟机全场景矩阵测试 100% 通过</strong>：Tart 虚拟机自动化全链路（连接-退出保护-冷启动重连-主动断开-保持断开）4 大场景 100% 通过。</li>
    <li><strong>真实硬件 Mac mini 双机测试通过</strong>：物理真机联调闭环通过，系统扩展授权与真实网络路由无缝恢复。</li>
  </ul>
</div>
"""

let releaseNotesHTML = wrapWithAppleStyle(content: rawNotesContent ?? defaultNotesContent, version: version, build: build)


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
                sparkle:edSignature="\(finalSig)"
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
print("  Ed25519: \(finalSig)")
print("  Saved to: \(appcastPath)")
SWIFT_CODE

if [ -f "$WEB_APPCAST" ] && [ "$OUTPUT_APPCAST" != "$WEB_APPCAST" ]; then
  cp "$OUTPUT_APPCAST" "$WEB_APPCAST"
  echo "Synchronized appcast to: $WEB_APPCAST"
fi

