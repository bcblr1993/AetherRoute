import AppKit

let builtIn = CGRect(x: 54, y: 0, width: 1674, height: 1084)
let external = CGRect(x: -1920, y: -120, width: 1920, height: 1057)

func expectUnchanged(_ frame: CGRect, screens: [CGRect], _ reason: String) {
    precondition(WindowVisibilityGeometry.recoveredFrame(frame, visibleScreens: screens) == nil, reason)
}

func expectRecovery(_ frame: CGRect, screens: [CGRect], _ expected: CGRect, _ reason: String) {
    let recovered = WindowVisibilityGeometry.recoveredFrame(frame, visibleScreens: screens)
    precondition(recovered == expected, "\(reason): \(String(describing: recovered))")
    precondition(recovered?.size == frame.size, "Recovery must preserve window size")
    expectUnchanged(expected, screens: screens, "Recovered position must be stable")
}

expectUnchanged(CGRect(x: 120, y: 200, width: 960, height: 662), screens: [builtIn], "Normal settings position")
expectUnchanged(CGRect(x: -1800, y: 0, width: 960, height: 662), screens: [builtIn, external], "Negative-coordinate external display")
expectUnchanged(CGRect(x: -500, y: 100, width: 960, height: 662), screens: [builtIn, external], "A window spanning connected displays")
expectUnchanged(CGRect(x: 900, y: 200, width: 960, height: 662), screens: [builtIn], "A usable partly clipped position must not move")
expectRecovery(
    CGRect(x: 1284, y: -371, width: 960, height: 662), screens: [builtIn],
    CGRect(x: 768, y: 0, width: 960, height: 662), "Observed offscreen settings window"
)
expectRecovery(
    CGRect(x: -1800, y: 0, width: 960, height: 662), screens: [builtIn],
    CGRect(x: 54, y: 0, width: 960, height: 662), "Disconnected external display"
)
expectRecovery(
    CGRect(x: -2200, y: 300, width: 960, height: 662), screens: [builtIn, external],
    CGRect(x: -1920, y: 275, width: 960, height: 662), "Recover onto the intersecting negative-coordinate screen"
)
expectRecovery(
    CGRect(x: 2000, y: 400, width: 2200, height: 1400), screens: [builtIn],
    CGRect(x: 54, y: -316, width: 2200, height: 1400), "Oversized window preserves size and exposes titlebar"
)
expectRecovery(
    CGRect(x: 100, y: 750, width: 960, height: 662), screens: [builtIn],
    CGRect(x: 100, y: 422, width: 960, height: 662), "Inaccessible titlebar above visible frame"
)
expectRecovery(
    CGRect(x: 1284, y: -371, width: 960, height: 662), screens: [builtIn, builtIn],
    CGRect(x: 768, y: 0, width: 960, height: 662), "Mirrored displays must not double-count visible area"
)
expectUnchanged(CGRect(x: 0, y: 0, width: 960, height: 662), screens: [], "No available display")
expectUnchanged(.zero, screens: [builtIn], "An empty transient frame")
expectUnchanged(CGRect(x: CGFloat.infinity, y: 0, width: 960, height: 662), screens: [builtIn], "An invalid frame")
print("Window visibility: 13 geometry scenarios passed")
