import AetherRouteKit
import XCTest

final class NetworkSetupProgressTests: XCTestCase {
    func testDetectedStateNeedsCurrentExtensionAndConfiguration() {
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .enabled(isCurrentBuild: true), hasConfiguration: true), .ready)
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .enabled(isCurrentBuild: true), hasConfiguration: false), .pending)
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .enabled(isCurrentBuild: false), hasConfiguration: true), .pending)
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .notInstalled, hasConfiguration: true), .pending)
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .awaitingApproval, hasConfiguration: false), .awaitingApproval)
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .uninstalling, hasConfiguration: true), .rebootRequired)
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .rebootRequired, hasConfiguration: true), .rebootRequired)
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .unknown, hasConfiguration: true), .pending)
    }

    func testFinishAllowsProceedingOnceAtLeastOneEngineIsReady() {
        XCTAssertTrue(NetworkSetupProgress.canFinish([.ready, .ready]))
        XCTAssertFalse(NetworkSetupProgress.canFinish([.ready, .pending]))
        XCTAssertTrue(NetworkSetupProgress.canFinish([.ready, .awaitingApproval]))
        XCTAssertFalse(NetworkSetupProgress.canFinish([.ready, .installingExtension]))
        XCTAssertFalse(NetworkSetupProgress.canFinish([.ready, .awaitingConfigurationConsent]))
        XCTAssertFalse(NetworkSetupProgress.canFinish([.ready, .failed(reason: "denied", isRetryable: true)]))
        XCTAssertTrue(NetworkSetupProgress.canFinish([.ready, .rebootRequired]))
        XCTAssertFalse(NetworkSetupProgress.canFinish([.rebootRequired, .rebootRequired]))
        XCTAssertFalse(NetworkSetupProgress.canFinish([]))
    }

    func testPolicyBlockedEngineDoesNotLockOutAWorkingOne() {
        let blocked = NetworkSetupStepState.failed(reason: "policy", isRetryable: false)
        XCTAssertTrue(NetworkSetupProgress.canFinish([.ready, blocked]))
        XCTAssertFalse(NetworkSetupProgress.canFinish([blocked, blocked]))
    }

    func testSingleEngineBuild() {
        XCTAssertTrue(NetworkSetupProgress.canFinish([.ready]))
        XCTAssertEqual(NetworkSetupProgress.primaryAction(for: [.pending], isRunning: false), .start)
    }

    func testPrimaryAction() {
        typealias P = NetworkSetupProgress
        XCTAssertEqual(P.primaryAction(for: [.pending, .pending], isRunning: false), .start)
        XCTAssertEqual(P.primaryAction(for: [.checking, .pending], isRunning: false), .waiting)
        XCTAssertEqual(P.primaryAction(for: [.awaitingApproval, .pending], isRunning: false), .waiting)
        XCTAssertEqual(P.primaryAction(for: [.ready, .pending], isRunning: true), .waiting)
        XCTAssertEqual(P.primaryAction(for: [.ready, .failed(reason: "denied", isRetryable: true)], isRunning: false), .retry)
        XCTAssertEqual(P.primaryAction(for: [.ready, .rebootRequired], isRunning: false), .finish)
        XCTAssertEqual(P.primaryAction(for: [.rebootRequired, .rebootRequired], isRunning: false), .restartRequired)
        XCTAssertEqual(P.primaryAction(for: [.pending, .rebootRequired], isRunning: false), .start)
        XCTAssertEqual(P.primaryAction(for: [.ready, .ready], isRunning: false), .finish)
    }

    func testGateOnlyForFreshInstalls() {
        typealias P = NetworkSetupProgress
        XCTAssertTrue(P.requiresGate(hasCompletedSetup: false, isExistingInstall: false, isAutomation: false))
        XCTAssertFalse(P.requiresGate(hasCompletedSetup: true, isExistingInstall: false, isAutomation: false))
        XCTAssertFalse(P.requiresGate(hasCompletedSetup: false, isExistingInstall: true, isAutomation: false))
        XCTAssertFalse(P.requiresGate(hasCompletedSetup: false, isExistingInstall: false, isAutomation: true))
    }

    func testRefreshedStateRecoversFromFailureAndPreservesActivePrompts() {
        typealias P = NetworkSetupProgress

        // Once the extension & config become ready (e.g. after returning from System Settings),
        // refreshing setup status must clear a prior .failed state instead of locking the user out.
        XCTAssertEqual(
            P.refreshedState(
                current: .failed(reason: "Timed out waiting for approval", isRetryable: true),
                extension: .enabled(isCurrentBuild: true),
                hasConfiguration: true
            ),
            .ready
        )
        XCTAssertEqual(
            P.refreshedState(
                current: .failed(reason: "Needs approval", isRetryable: true),
                extension: .awaitingApproval,
                hasConfiguration: false
            ),
            .awaitingApproval
        )
        XCTAssertEqual(
            P.refreshedState(
                current: .failed(reason: "Replace pending", isRetryable: true),
                extension: .rebootRequired,
                hasConfiguration: false
            ),
            .rebootRequired
        )

        // When the underlying extension is still missing/pending, retain the previous error reason.
        XCTAssertEqual(
            P.refreshedState(
                current: .failed(reason: "Activation denied", isRetryable: true),
                extension: .notInstalled,
                hasConfiguration: false
            ),
            .failed(reason: "Activation denied", isRetryable: true)
        )

        // A completed reboot should recover from .rebootRequired to .ready once enabled + configured.
        XCTAssertEqual(
            P.refreshedState(
                current: .rebootRequired,
                extension: .enabled(isCurrentBuild: true),
                hasConfiguration: true
            ),
            .ready
        )

        // Active in-flight system prompts must NOT be overwritten on foreground refresh.
        XCTAssertFalse(P.shouldProbeOnRefresh(.installingExtension))
        XCTAssertFalse(P.shouldProbeOnRefresh(.awaitingConfigurationConsent))
        XCTAssertTrue(P.shouldProbeOnRefresh(.failed(reason: "err", isRetryable: true)))
        XCTAssertTrue(P.shouldProbeOnRefresh(.rebootRequired))
        XCTAssertTrue(P.shouldProbeOnRefresh(.pending))

        XCTAssertEqual(
            P.refreshedState(
                current: .installingExtension,
                extension: .notInstalled,
                hasConfiguration: false
            ),
            .installingExtension
        )
        XCTAssertEqual(
            P.refreshedState(
                current: .awaitingConfigurationConsent,
                extension: .enabled(isCurrentBuild: true),
                hasConfiguration: true
            ),
            .awaitingConfigurationConsent
        )
    }

    func testRefreshNetworkSetupStatusDelegatesToRefreshedState() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/AetherRouteApp/TunnelManager+NetworkSetup.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("NetworkSetupProgress.shouldProbeOnRefresh("),
            "refreshNetworkSetupStatus must consult NetworkSetupProgress.shouldProbeOnRefresh so .failed is still probed"
        )
        XCTAssertTrue(
            source.contains("NetworkSetupProgress.refreshedState("),
            "refreshNetworkSetupStatus must update networkSetupStates via NetworkSetupProgress.refreshedState"
        )
    }
}
