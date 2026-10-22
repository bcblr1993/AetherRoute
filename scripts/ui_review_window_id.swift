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
    area: Double
)? in
    guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
          ownerPID == requestedPID,
          let layer = window[kCGWindowLayer as String] as? Int,
          layer == 0,
          let number = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double,
          width >= (panelOnly || settingsOnly ? 300 : 780),
          height >= (panelOnly || settingsOnly ? 300 : 560)
    else {
        return nil
    }
    return (number, width * height)
}

let window: (id: Int, area: Double)?
if settingsOnly {
    // Settings opens after the main window, so it carries the higher window
    // number. Matching by title or by a 960x640 size picked the main window
    // (titled after its page and sized 960x640 by the settings cases) for
    // every settings capture until 1.8.7. Wait until both windows exist.
    let settingsCandidates = candidates.sorted { $0.id < $1.id }
    window = settingsCandidates.count >= 2 ? settingsCandidates.max(by: { $0.id < $1.id }) : nil
} else {
    window = candidates.max(by: { $0.area < $1.area })
}
guard let window else {
    exit(1)
}
print(window.id)
