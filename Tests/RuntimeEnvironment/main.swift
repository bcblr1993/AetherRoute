import AppKit
import AetherRouteKit

// Exercise the production observer with an isolated notification center and a
// recording tunnel. No real provider, power state or host networking is touched.
@MainActor
final class TunnelManager {
    var events: [RuntimeEnvironmentEvent] = []

    func handleRuntimeEnvironmentEvent(_ event: RuntimeEnvironmentEvent) async {
        events.append(event)
    }
}

@main
struct RuntimeEnvironmentRegression {
    @MainActor
    static func main() async throws {
        let center = NotificationCenter()
        let tunnel = TunnelManager()
        let controller = AppRuntimeEnvironmentController(
            tunnel: tunnel,
            environment: [:],
            workspaceCenter: center
        )

        func post(_ name: Notification.Name) async throws {
            center.post(name: name, object: nil)
            // Observer callbacks enqueue MainActor tasks.
            try await Task.sleep(for: .milliseconds(50))
        }

        for _ in 0..<3 {
            try await post(NSWorkspace.screensDidSleepNotification)
            try await post(NSWorkspace.screensDidWakeNotification)
        }
        precondition(tunnel.events.filter { $0 != .networkPathChanged }.isEmpty,
                     "Display sleep/wake must not pause monitoring or reset connections")

        try await post(NSWorkspace.willSleepNotification)
        try await post(NSWorkspace.screensDidSleepNotification)
        try await post(NSWorkspace.screensDidWakeNotification)
        precondition(tunnel.events.filter { $0 != .networkPathChanged } == [.systemWillSleep],
                     "Lighting a display must not prematurely wake the tunnel")

        try await post(NSWorkspace.didWakeNotification)
        precondition(tunnel.events.filter { $0 != .networkPathChanged } == [
            .systemWillSleep, .systemDidWake,
        ], "Actual system sleep/wake must still reach recovery")
        withExtendedLifetime(controller) {}
        print("Runtime environment: display continuity and real sleep/wake passed")
    }
}
