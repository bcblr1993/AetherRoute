import Foundation

// Test helper for the isolated VM only. QA power events are deliberately
// distinct from real lock/unlock, which must never request network recovery.
let allowed = [
    "com.apple.screenIsLocked", "com.apple.screenIsUnlocked",
    "com.aetherroute.qa.systemWillSleep", "com.aetherroute.qa.systemDidWake",
]
guard CommandLine.arguments.count == 2,
      allowed.contains(CommandLine.arguments[1]) else {
    fatalError("Expected one supported runtime test notification")
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(CommandLine.arguments[1]),
    object: nil, userInfo: nil, deliverImmediately: true
)
