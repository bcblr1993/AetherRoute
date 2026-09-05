import AppKit

/// Repairs restored windows after a display disappears without resetting a
/// usable window's position or changing its size.
@MainActor
final class WindowVisibilityCoordinator: NSObject {
    private weak var window: NSWindow?

    func observe(_ window: NSWindow?) {
        stopObserving()
        self.window = window
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(recoverIfNeeded), name: name, object: window
            )
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(recoverIfNeeded),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
        window = nil
    }

    @objc func recoverIfNeeded() {
        guard let window, window.isVisible, !window.isMiniaturized,
              !window.styleMask.contains(.fullScreen),
              !window.inLiveResize, NSEvent.pressedMouseButtons == 0,
              let frame = WindowVisibilityGeometry.recoveredFrame(
                  window.frame, visibleScreens: NSScreen.screens.map(\.visibleFrame)
              ) else { return }
        window.setFrameOrigin(frame.origin)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

enum WindowVisibilityGeometry {
    static func recoveredFrame(_ frame: CGRect, visibleScreens: [CGRect]) -> CGRect? {
        guard isValid(frame) else { return nil }
        let screens = visibleScreens.filter(isValid)
        guard !screens.isEmpty else { return nil }

        // Keep normal positions, including windows spanning displays. Recovery
        // is needed only when the title-bar controls are inaccessible or most
        // of the usable window area is outside every connected display.
        let titleBar = CGRect(
            x: frame.minX, y: frame.maxY - min(22, frame.height),
            width: min(160, frame.width), height: min(22, frame.height)
        )
        let largestViewport = screens.map { min(frame.width, $0.width) * min(frame.height, $0.height) }.max() ?? 0
        let titleBarIsVisible = coveredArea(titleBar, screens: screens) >= titleBar.width * titleBar.height - 1
        if titleBarIsVisible, coveredArea(frame, screens: screens) >= largestViewport * 0.5 {
            return nil
        }

        let destination = screens.max { left, right in
            let leftArea = intersectionArea(frame, left)
            let rightArea = intersectionArea(frame, right)
            if leftArea != rightArea { return leftArea < rightArea }
            return squaredDistance(frame, left) > squaredDistance(frame, right)
        }!
        var result = frame
        result.origin.x = frame.width > destination.width
            ? destination.minX
            : min(max(frame.minX, destination.minX), destination.maxX - frame.width)
        result.origin.y = frame.height > destination.height
            ? destination.maxY - frame.height
            : min(max(frame.minY, destination.minY), destination.maxY - frame.height)
        return result == frame ? nil : result
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func squaredDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let x = lhs.midX - rhs.midX
        let y = lhs.midY - rhs.midY
        return x * x + y * y
    }

    private static func coveredArea(_ frame: CGRect, screens: [CGRect]) -> CGFloat {
        let intersections = screens.map { frame.intersection($0) }.filter { !$0.isNull && !$0.isEmpty }
        let edges = Set(intersections.flatMap { [$0.minX, $0.maxX] }).sorted()
        guard edges.count > 1 else { return 0 }
        var area: CGFloat = 0
        for (left, right) in zip(edges, edges.dropFirst()) {
            let spans = intersections.filter { $0.minX < right && $0.maxX > left }
                .sorted { $0.minY < $1.minY }
            var end = -CGFloat.infinity
            var height: CGFloat = 0
            for span in spans {
                height += max(0, span.maxY - max(end, span.minY))
                end = max(end, span.maxY)
            }
            area += (right - left) * height
        }
        return area
    }
}
