// Builds report.html for a capture_ui_review.sh output directory. Given an
// earlier capture as a baseline, it also compares every screenshot pixel by
// pixel and writes a diff image for each one that changed.
//
//   ui_review_report <capture-dir> [<baseline-dir>]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard (2...3).contains(CommandLine.arguments.count) else {
    fputs("usage: ui_review_report <capture-dir> [<baseline-dir>]\n", stderr)
    exit(64)
}

let captureURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let baselineURL = CommandLine.arguments.count == 3
    ? URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    : nil
let fileManager = FileManager.default

func screenshotNames(in directory: URL) -> [String] {
    let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    return names
        .filter { $0.hasSuffix(".png") }
        .map { String($0.dropLast(4)) }
        .sorted()
}

/// RGBA8 pixels of an image, so two captures compare channel by channel.
struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        width = image.width
        height = image.height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !drawn { return nil }
    }

    func write(to url: URL) -> Bool {
        var copy = pixels
        return copy.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { return false }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination)
        }
    }
}

enum Status: String {
    case identical, changed, resized, new, removed, unreadable

    var label: String {
        switch self {
        case .identical: "无变化"
        case .changed: "有变化"
        case .resized: "尺寸变化"
        case .new: "新增"
        case .removed: "已移除"
        case .unreadable: "无法读取"
        }
    }
}

struct Entry {
    let name: String
    let status: Status
    let changedRatio: Double
}

/// A channel difference below this is antialiasing or color-profile noise.
let channelTolerance = 16

func compare(name: String, current: URL, baseline: URL, diffDirectory: URL) -> Entry {
    guard let now = Bitmap(url: current), let before = Bitmap(url: baseline) else {
        return Entry(name: name, status: .unreadable, changedRatio: 0)
    }
    guard now.width == before.width, now.height == before.height else {
        return Entry(name: name, status: .resized, changedRatio: 1)
    }
    var diff = now
    var changed = 0
    for index in stride(from: 0, to: now.pixels.count, by: 4) {
        var differs = false
        for channel in 0..<3 where abs(Int(now.pixels[index + channel]) - Int(before.pixels[index + channel])) > channelTolerance {
            differs = true
            break
        }
        if differs {
            changed += 1
            diff.pixels[index] = 255
            diff.pixels[index + 1] = 40
            diff.pixels[index + 2] = 40
            diff.pixels[index + 3] = 255
        } else {
            // Unchanged pixels fade to a quiet gray so the red reads at once.
            let gray = UInt8((Int(now.pixels[index]) + Int(now.pixels[index + 1]) + Int(now.pixels[index + 2])) / 3 / 4 + 160)
            diff.pixels[index] = gray
            diff.pixels[index + 1] = gray
            diff.pixels[index + 2] = gray
            diff.pixels[index + 3] = 255
        }
    }
    if changed == 0 {
        return Entry(name: name, status: .identical, changedRatio: 0)
    }
    _ = diff.write(to: diffDirectory.appendingPathComponent(name + ".png"))
    return Entry(
        name: name,
        status: .changed,
        changedRatio: Double(changed) / Double(now.width * now.height)
    )
}

let currentNames = screenshotNames(in: captureURL)
var entries: [Entry] = []
let diffDirectory = captureURL.appendingPathComponent("diff", isDirectory: true)

if let baselineURL {
    try? fileManager.createDirectory(at: diffDirectory, withIntermediateDirectories: true)
    let baselineNames = Set(screenshotNames(in: baselineURL))
    for name in currentNames {
        if baselineNames.contains(name) {
            entries.append(compare(
                name: name,
                current: captureURL.appendingPathComponent(name + ".png"),
                baseline: baselineURL.appendingPathComponent(name + ".png"),
                diffDirectory: diffDirectory
            ))
        } else {
            entries.append(Entry(name: name, status: .new, changedRatio: 0))
        }
    }
    for name in baselineNames.subtracting(currentNames).sorted() {
        entries.append(Entry(name: name, status: .removed, changedRatio: 0))
    }
} else {
    entries = currentNames.map { Entry(name: $0, status: .new, changedRatio: 0) }
}

func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

let baselinePrefix = baselineURL.map { $0.standardizedFileURL.path } ?? ""
var cards = ""
for entry in entries {
    let name = escape(entry.name)
    var images = ""
    if baselineURL != nil, entry.status != .new {
        let baselineImage = "file://" + escape(baselinePrefix) + "/" + name + ".png"
        images += "<figure><figcaption>基线</figcaption><a href=\"\(baselineImage)\"><img loading=\"lazy\" src=\"\(baselineImage)\" alt=\"\(name) 基线\"></a></figure>"
    }
    if entry.status != .removed {
        images += "<figure><figcaption>当前</figcaption><a href=\"\(name).png\"><img loading=\"lazy\" src=\"\(name).png\" alt=\"\(name) 当前\"></a></figure>"
    }
    if entry.status == .changed {
        images += "<figure><figcaption>差异</figcaption><a href=\"diff/\(name).png\"><img loading=\"lazy\" src=\"diff/\(name).png\" alt=\"\(name) 差异\"></a></figure>"
    }
    let ratio = entry.status == .changed
        ? String(format: " · %.2f%% 像素", entry.changedRatio * 100)
        : ""
    cards += """
    <article class="card" data-status="\(entry.status.rawValue)">
      <header><h2>\(name)</h2><span class="tag \(entry.status.rawValue)">\(entry.status.label)\(ratio)</span></header>
      <div class="images">\(images)</div>
    </article>

    """
}

var counts: [Status: Int] = [:]
for entry in entries { counts[entry.status, default: 0] += 1 }
let filterOrder: [Status] = baselineURL == nil
    ? []
    : [.changed, .resized, .new, .removed, .identical, .unreadable]
var filters = "<button type=\"button\" class=\"on\" data-filter=\"all\">全部 \(entries.count)</button>"
for status in filterOrder where (counts[status] ?? 0) > 0 {
    filters += "<button type=\"button\" data-filter=\"\(status.rawValue)\">\(status.label) \(counts[status]!)</button>"
}
let subtitle = baselineURL == nil
    ? "\(entries.count) 个画面"
    : "对比基线 \(escape(baselinePrefix))"

let html = """
<!doctype html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AetherRoute 界面截图报告</title>
<style>
:root { color-scheme: light dark; --bg: #f5f5f7; --card: #fff; --text: #1d1d1f; --muted: #6e6e73; --line: rgba(0,0,0,.1); --red: #c4281c; --green: #1e8e3e; --blue: #0064d2; }
@media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --card: #2a2a2d; --text: #f2f2f7; --muted: #8e8e93; --line: rgba(255,255,255,.1); --red: #ff6961; --green: #30d158; --blue: #409cff; } }
body { margin: 0; background: var(--bg); color: var(--text); font: 13px -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
main { max-width: 1600px; margin: 0 auto; padding: 24px 16px 48px; }
h1 { margin: 0 0 4px; font-size: 22px; }
.sub { margin: 0 0 16px; color: var(--muted); word-break: break-all; }
.filters { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 16px; }
.filters button { font: inherit; color: var(--text); background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 4px 12px; cursor: pointer; }
.filters button.on { background: var(--blue); border-color: var(--blue); color: #fff; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 12px; margin-bottom: 12px; }
.card header { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
.card h2 { margin: 0; font-size: 13px; font-weight: 600; font-family: ui-monospace, monospace; flex: 1; word-break: break-all; }
.tag { font-size: 11px; padding: 2px 8px; border-radius: 10px; border: 1px solid var(--line); color: var(--muted); white-space: nowrap; }
.tag.changed, .tag.resized, .tag.unreadable { color: var(--red); border-color: var(--red); }
.tag.new { color: var(--blue); border-color: var(--blue); }
.tag.identical { color: var(--green); border-color: var(--green); }
.images { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 10px; }
figure { margin: 0; }
figcaption { font-size: 11px; color: var(--muted); margin-bottom: 4px; }
img { width: 100%; height: auto; border-radius: 6px; border: 1px solid var(--line); display: block; }
.hidden { display: none; }
</style>
</head>
<body>
<main>
<h1>AetherRoute 界面截图报告</h1>
<p class="sub">\(subtitle)</p>
<nav class="filters" aria-label="按状态筛选">\(filters)</nav>
\(cards)
</main>
<script>
document.querySelectorAll('.filters button').forEach(function (button) {
  button.addEventListener('click', function () {
    document.querySelectorAll('.filters button').forEach(function (b) { b.classList.toggle('on', b === button); });
    var filter = button.getAttribute('data-filter');
    document.querySelectorAll('.card').forEach(function (card) {
      card.classList.toggle('hidden', filter !== 'all' && card.getAttribute('data-status') !== filter);
    });
  });
});
</script>
</body>
</html>

"""

let reportURL = captureURL.appendingPathComponent("report.html")
do {
    try html.write(to: reportURL, atomically: true, encoding: .utf8)
} catch {
    fputs("Could not write \(reportURL.path): \(error)\n", stderr)
    exit(1)
}

let changedCount = (counts[.changed] ?? 0) + (counts[.resized] ?? 0) + (counts[.unreadable] ?? 0)
print("UI review report: cases=\(entries.count) changed=\(changedCount) new=\(counts[.new] ?? 0) removed=\(counts[.removed] ?? 0) identical=\(counts[.identical] ?? 0) report=\(reportURL.path)")
