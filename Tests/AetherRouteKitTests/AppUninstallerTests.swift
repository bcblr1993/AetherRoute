import XCTest
@testable import AetherRouteKit

@MainActor
final class AppUninstallerTests: XCTestCase {
    private final class RecordingPerformer: UninstallStepPerforming {
        var outcomes: [UninstallStep: UninstallStepOutcome] = [:]
        private(set) var performed: [UninstallStep] = []

        func perform(_ step: UninstallStep) async -> UninstallStepOutcome {
            performed.append(step)
            return outcomes[step] ?? .completed
        }
    }

    private let extensions = ["com.example.tunnel", "com.example.transparent-proxy"]

    func testPlanRemovesConfigurationsBeforeExtensionsAndTrashesLast() {
        // Configurations first: an extension whose configuration remains is
        // what macOS left running after the app was deleted (1.8.7).
        XCTAssertEqual(AppUninstaller.plan(deletingUserData: false, extensionIdentifiers: extensions), [
            .disconnect,
            .removeNetworkConfigurations,
            .deactivateExtension("com.example.tunnel"),
            .deactivateExtension("com.example.transparent-proxy"),
            .unregisterLoginItem,
            .moveAppToTrash,
        ])
        XCTAssertEqual(
            AppUninstaller.plan(deletingUserData: true, extensionIdentifiers: extensions).suffix(3),
            [.unregisterLoginItem, .deleteUserData, .moveAppToTrash]
        )
    }

    func testCleanRunPerformsEveryStep() async {
        let performer = RecordingPerformer()
        let plan = AppUninstaller.plan(deletingUserData: true, extensionIdentifiers: extensions)
        let report = await AppUninstaller.run(plan, performer: performer)
        XCTAssertEqual(performer.performed, plan)
        XCTAssertTrue(report.isComplete)
        XCTAssertFalse(report.needsRestart)
        XCTAssertTrue(report.movedAppToTrash)
    }

    func testRestartIsReportedButStillCountsAsRemoved() async {
        let performer = RecordingPerformer()
        performer.outcomes[.deactivateExtension("com.example.transparent-proxy")] = .completesAfterRestart
        let report = await AppUninstaller.run(
            AppUninstaller.plan(deletingUserData: false, extensionIdentifiers: extensions),
            performer: performer
        )
        XCTAssertTrue(report.needsRestart)
        XCTAssertTrue(report.isComplete)
        XCTAssertTrue(report.movedAppToTrash)
    }

    func testFailedStepDoesNotStopTheOthersButKeepsTheApp() async {
        // A cancelled administrator prompt must not leave an orphaned
        // extension behind a trashed app: keep the app so the user can retry.
        let performer = RecordingPerformer()
        performer.outcomes[.deactivateExtension("com.example.tunnel")] = .failed("cancelled")
        let plan = AppUninstaller.plan(deletingUserData: true, extensionIdentifiers: extensions)
        let report = await AppUninstaller.run(plan, performer: performer)
        XCTAssertEqual(performer.performed, Array(plan.dropLast()))
        XCTAssertFalse(report.isComplete)
        XCTAssertFalse(report.movedAppToTrash)
        XCTAssertEqual(report.failures.map(\.step), [.deactivateExtension("com.example.tunnel")])
        XCTAssertEqual(report.entries.last?.step, .moveAppToTrash)
        XCTAssertEqual(report.entries.last?.outcome, .skipped)
    }

    func testFailureAfterTheExtensionsStillTrashesTheApp() async {
        // Leftover data or a login item cannot keep anything running.
        let performer = RecordingPerformer()
        performer.outcomes[.deleteUserData] = .failed("busy")
        let plan = AppUninstaller.plan(deletingUserData: true, extensionIdentifiers: extensions)
        let report = await AppUninstaller.run(plan, performer: performer)
        XCTAssertEqual(performer.performed, plan)
        XCTAssertTrue(report.movedAppToTrash)
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.failures.map(\.step), [.deleteUserData])
    }

    func testOnlyLocalKeychainServicesAreDeleted() {
        // The iCloud sync key is synchronizable: deleting it here would
        // delete it on the user's other devices too.
        XCTAssertFalse(AppUninstaller.localKeychainServices.contains(ProfileCloudSyncManager.cloudSyncService))
        XCTAssertTrue(AppUninstaller.localKeychainServices.contains(DataProtectionProfileKeyStore.defaultService))
    }

    func testSandboxedAppIsHandedToTheUserAfterTheNetworkIsClean() async {
        // Seen on the Mac mini: a sandboxed app may not move itself to the
        // Trash. With every network component gone that is a hand-off, not a
        // network failure.
        let performer = RecordingPerformer()
        performer.outcomes[.moveAppToTrash] = .handedToUser
        let report = await AppUninstaller.run(
            AppUninstaller.plan(deletingUserData: false, extensionIdentifiers: extensions),
            performer: performer
        )
        XCTAssertTrue(report.isComplete)
        XCTAssertTrue(report.appHandedToUser)
        XCTAssertFalse(report.movedAppToTrash)
        XCTAssertFalse(report.networkRemovalFailed)
    }

    func testNetworkFailureIsToldApartFromOtherFailures() async {
        let performer = RecordingPerformer()
        performer.outcomes[.unregisterLoginItem] = .failed("denied")
        let other = await AppUninstaller.run(
            AppUninstaller.plan(deletingUserData: false, extensionIdentifiers: extensions),
            performer: performer
        )
        XCTAssertFalse(other.networkRemovalFailed)

        performer.outcomes[.removeNetworkConfigurations] = .failed("denied")
        let network = await AppUninstaller.run(
            AppUninstaller.plan(deletingUserData: false, extensionIdentifiers: extensions),
            performer: performer
        )
        XCTAssertTrue(network.networkRemovalFailed)
    }
}
