import CoreGraphics
import Foundation
import AppKit

guard (2...3).contains(CommandLine.arguments.count) else {
    fputs("usage: ui_review_window_id --preflight|[--settings|--panel] <pid>\n", stderr)
    exit(64)
}

if CommandLine.arguments[1] == "--preflight" {
    exit(CGPreflightScreenCaptureAccess() ? 0 : 77)
}

let settingsOnly = CommandLine.arguments.count == 3
    && CommandLine.arguments[1] == "--settings"
// The menu bar panel review renders the real panel in its own narrow window.
let panelOnly = CommandLine.arguments.count == 3
    && CommandLine.arguments[1] == "--panel"
let pidArgument = CommandLine.arguments.count == 3
    ? CommandLine.arguments[2]
    : CommandLine.arguments[1]

guard
      let requestedPID = Int(pidArgument),
      requestedPID > 0
else {
    fputs("usage: ui_review_window_id --preflight|[--settings|--panel] <pid>\n", stderr)
    exit(64)
}
guard CommandLine.arguments.count == 2 || settingsOnly || panelOnly else {
    fputs("usage: ui_review_window_id --preflight|[--settings|--panel] <pid>\n", stderr)
    exit(64)
}

if let application = NSRunningApplication(
    processIdentifier: pid_t(requestedPID)
) {
    _ = application.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 0.08)
}

let options: CGWindowListOption = [
    .optionOnScreenOnly,
    .excludeDesktopElements,
]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
    as? [[String: Any]]
else {
    exit(1)
}

let candidates = windows.compactMap { window -> (
    id: Int,
    area: Double,
    settingsDistance: Double
)? in
    guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
          ownerPID == requestedPID,
          let layer = window[kCGWindowLayer as String] as? Int,
          layer == 0,
          let number = window[kCGWindowNumber as String] as? Int,
          let name = window[kCGWindowName as String] as? String,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double,
          width >= (panelOnly ? 300 : (settingsOnly ? 900 : 780)),
          height >= (panelOnly ? 300 : (settingsOnly ? 620 : 560))
    else {
        return nil
    }
    if settingsOnly {
        // Settings titles itself after the open pane ("Network", "网络"),
        // so any titled window other than the main one ("AetherRoute") is a
        // Settings candidate; the size check below picks the right one.
        let isSettingsWindow =
            name.localizedCaseInsensitiveContains("settings")
            || name.contains("设置")
            || (!name.isEmpty && name != "AetherRoute")
        guard isSettingsWindow else {
            return nil
        }
    }
    let settingsDistance = abs(width - 960) + abs(height - 640)
    return (number, width * height, settingsDistance)
}

let window = settingsOnly
    ? candidates.min(by: { $0.settingsDistance < $1.settingsDistance })
    : candidates.max(by: { $0.area < $1.area })
guard let window else {
    exit(1)
}
print(window.id)
