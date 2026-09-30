import AetherRouteKit
import XCTest

final class NetworkSetupProgressTests: XCTestCase {
    func testDetectedStateNeedsCurrentExtensionAndConfiguration() {
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .enabled(isCurrentBuild: true), hasConfiguration: true), .ready)
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .enabled(isCurrentBuild: true), hasConfiguration: false), .pending)
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .enabled(isCurrentBuild: false), hasConfiguration: true), .pending)
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .notInstalled, hasConfiguration: true), .pending)
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .awaitingApproval, hasConfiguration: false), .awaitingApproval)
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .uninstalling, hasConfiguration: true), .pending)
        XCTAssertEqual(NetworkSetupProgress.detectedState(extension: .unknown, hasConfiguration: true), .pending)
    }

    func testFinishRequiresEveryEngineReady() {
        XCTAssertTrue(NetworkSetupProgress.canFinish([.ready, .ready]))
        XCTAssertFalse(NetworkSetupProgress.canFinish([.ready, .pending]))
        XCTAssertFalse(NetworkSetupProgress.canFinish([.ready, .awaitingApproval]))
        XCTAssertFalse(NetworkSetupProgress.canFinish([.ready, .failed(reason: "denied", isRetryable: true)]))
        XCTAssertFalse(NetworkSetupProgress.canFinish([.ready, .rebootRequired]))
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
        XCTAssertEqual(P.primaryAction(for: [.ready, .rebootRequired], isRunning: false), .restartRequired)
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
}
