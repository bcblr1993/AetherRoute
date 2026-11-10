import AetherRouteKit
import Foundation
@preconcurrency import SystemExtensions

// Keep the actual coordinator under test without launching the app or loading
// UI localization. No request is submitted to the real system manager.
enum AppLocalization {
    static func string(_ value: String) -> String { value }
}

@main
@MainActor
enum SystemExtensionActivationRegression {
    static let version = SystemExtensionActivationPolicy.Version(
        identifier: "com.aetherroute.desktop.tunnel", build: "1470", release: "1.0.0"
    )

    static func main() async {
        do {
            try policyChecks()
            try await queryFailureAndStaleCallbacks()
            try await queryTimeoutFallsBack()
            try await missingMetadataUsesActivation()
            print("System extension regression passed: reuse policy, query failure/timeout fallback, request identity, authorization, and missing metadata. No system requests submitted.")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    static func policyChecks() throws {
        func installation(
            _ expected: SystemExtensionActivationPolicy.Version = version,
            enabled: Bool = true,
            awaiting: Bool = false,
            uninstalling: Bool = false
        ) -> SystemExtensionActivationPolicy.Installation {
            .init(version: expected, isEnabled: enabled,
                  isAwaitingUserApproval: awaiting, isUninstalling: uninstalling)
        }
        try expect(SystemExtensionActivationPolicy.canReuse(
            expected: version, installations: [installation()]
        ), "The exact active version was not reusable.")
        for installations in [
            [], [installation(enabled: false)], [installation(awaiting: true)],
            [installation(uninstalling: true)],
            [installation(.init(identifier: version.identifier, build: "1469", release: version.release))],
            [installation(.init(identifier: version.identifier, build: version.build, release: "0.9.0"))],
        ] {
            try expect(!SystemExtensionActivationPolicy.canReuse(
                expected: version, installations: installations
            ), "An absent, inactive, unapproved, retiring, or old extension was reused.")
        }
        try expect(SystemExtensionActivationPolicy.requiresRebootBeforeReinstall(
            expected: version,
            installations: [
                installation(enabled: false, uninstalling: true),
                installation(enabled: false, awaiting: true),
            ]
        ), "Same-build uninstalling state did not require reboot before reinstall.")
        try expect(SystemExtensionActivationPolicy.requiresRebootBeforeReinstall(
            expected: version,
            installations: [
                installation(
                    .init(identifier: version.identifier, build: "1469", release: "0.9.9"),
                    enabled: false,
                    uninstalling: true
                ),
                installation(enabled: false, awaiting: true),
            ]
        ), "Older build uninstalling state without an enabled copy did not require reboot before reinstall.")
        try expect(!SystemExtensionActivationPolicy.requiresRebootBeforeReinstall(
            expected: version,
            installations: [
                installation(
                    .init(identifier: version.identifier, build: "1469", release: "0.9.9"),
                    enabled: false,
                    uninstalling: true
                ),
                installation(
                    .init(identifier: version.identifier, build: "1469", release: "0.9.9"),
                    enabled: true
                ),
            ]
        ), "In-place upgrade over an enabled older build falsely required reboot.")
        try expect(
            NetworkSetupProgress.detectedState(extension: .rebootRequired, hasConfiguration: true) == .rebootRequired
                && NetworkSetupProgress.detectedState(extension: .uninstalling, hasConfiguration: true) == .rebootRequired,
            "Uninstalling / rebootRequired probe did not map to .rebootRequired setup state."
        )
        try expect(
            NetworkSetupProgress.canFinish([.ready, .rebootRequired])
                && NetworkSetupProgress.primaryAction(for: [.ready, .rebootRequired], isRunning: false) == .finish,
            "A ready engine was blocked by the other engine awaiting restart."
        )
        try expect(
            NetworkSetupProgress.canFinish([.ready, .awaitingApproval])
                && NetworkSetupProgress.primaryAction(for: [.ready, .awaitingApproval], isRunning: true) == .finish,
            "A ready engine was blocked while the other engine still waited for System Settings approval."
        )
        try expect(
            !NetworkSetupProgress.canFinish([.rebootRequired, .rebootRequired])
                && NetworkSetupProgress.primaryAction(for: [.rebootRequired, .rebootRequired], isRunning: false) == .restartRequired,
            "Both engines awaiting restart should still require restart."
        )
    }

    static func queryFailureAndStaleCallbacks() async throws {
        let recorder = Recorder()
        let coordinator = SystemExtensionActivationCoordinator(
            submitRequest: { recorder.requests.append($0) },
            bundledVersion: { _ in version }
        )
        let operation = Task {
            try await coordinator.activate(identifier: version.identifier) {
                recorder.approvals += 1
            }
            recorder.completed = true
        }
        try await waitUntil { recorder.requests.count == 1 }
        let query = recorder.requests[0]
        coordinator.request(query, didFailWithError: Failure(message: "Query unavailable"))
        try await waitUntil { recorder.requests.count == 2 }
        let activation = recorder.requests[1]
        try expect(query !== activation, "Fallback did not create a distinct activation request.")

        coordinator.request(query, didFinishWithResult: .completed)
        coordinator.request(query, didFailWithError: Failure(message: "Stale query failure"))
        coordinator.requestNeedsUserApproval(query)
        try await Task.sleep(for: .milliseconds(20))
        try expect(!recorder.completed && recorder.approvals == 0 && recorder.requests.count == 2,
                   "A stale query callback changed the live activation.")

        coordinator.requestNeedsUserApproval(activation)
        try await waitUntil { recorder.approvals == 1 }
        coordinator.request(activation, didFinishWithResult: .completed)
        try await operation.value
        try expect(recorder.completed, "Activation never completed.")
    }

    static func queryTimeoutFallsBack() async throws {
        let recorder = Recorder()
        let coordinator = SystemExtensionActivationCoordinator(
            submitRequest: { recorder.requests.append($0) },
            bundledVersion: { _ in version },
            propertiesTimeoutDuration: .milliseconds(10)
        )
        let operation = Task {
            try await coordinator.activate(identifier: version.identifier) {}
        }
        try await waitUntil { recorder.requests.count == 2 }
        coordinator.request(recorder.requests[1], didFinishWithResult: .completed)
        try await operation.value
        try expect(recorder.requests.count == 2, "A timed-out query submitted repeated activations.")
    }

    static func missingMetadataUsesActivation() async throws {
        let recorder = Recorder()
        let coordinator = SystemExtensionActivationCoordinator(
            submitRequest: { recorder.requests.append($0) },
            bundledVersion: { _ in nil }
        )
        let operation = Task {
            try await coordinator.activate(identifier: version.identifier) {}
        }
        try await waitUntil { recorder.requests.count == 1 }
        coordinator.request(recorder.requests[0], didFinishWithResult: .completed)
        try await operation.value
        try expect(recorder.requests.count == 1, "Missing metadata introduced a property-query dependency.")
    }

    static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw Failure(message: "Timed out waiting for a coordinator callback.")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    @MainActor
    final class Recorder {
        var requests: [OSSystemExtensionRequest] = []
        var approvals = 0
        var completed = false
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
