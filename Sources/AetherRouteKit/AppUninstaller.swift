import Foundation

/// One step of removing AetherRoute from a Mac.
public enum UninstallStep: Hashable, Sendable {
    case disconnect
    /// Removes every VPN and transparent-proxy configuration the app saved.
    case removeNetworkConfigurations
    case deactivateExtension(String)
    case unregisterLoginItem
    /// Profiles, rules, settings and this Mac's own keys.
    case deleteUserData
    case moveAppToTrash
}

public enum UninstallStepOutcome: Equatable, Sendable {
    case completed
    /// macOS finishes removing a system extension at the next restart.
    case completesAfterRestart
    case failed(String)
    /// Left for the user to finish: a sandboxed app may not move itself to
    /// the Trash, so it is selected in the Finder instead.
    case handedToUser
    /// Not attempted because an earlier step failed.
    case skipped
}

public struct UninstallReport: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let step: UninstallStep
        public let outcome: UninstallStepOutcome
    }

    public let entries: [Entry]

    public var failures: [Entry] {
        entries.filter { if case .failed = $0.outcome { true } else { false } }
    }

    public var needsRestart: Bool {
        entries.contains { $0.outcome == .completesAfterRestart }
    }

    public var movedAppToTrash: Bool {
        entries.contains { $0.step == .moveAppToTrash && $0.outcome == .completed }
    }

    /// The app is selected in the Finder for the user to drag to the Trash.
    public var appHandedToUser: Bool {
        entries.contains { $0.step == .moveAppToTrash && $0.outcome == .handedToUser }
    }

    /// A configuration or extension is still there; the app was kept.
    public var networkRemovalFailed: Bool {
        failures.contains { AppUninstaller.removesSomethingThatRuns($0.step) }
    }

    /// Every step done (a pending restart or a hand-off still counts).
    public var isComplete: Bool {
        entries.allSatisfy {
            $0.outcome == .completed || $0.outcome == .completesAfterRestart || $0.outcome == .handedToUser
        }
    }
}

@MainActor
public protocol UninstallStepPerforming: AnyObject {
    func perform(_ step: UninstallStep) async -> UninstallStepOutcome
}

/// Removes the app the way dragging it to the Trash does not.
///
/// Deleting the app removes the packet tunnel's VPN configuration and
/// extension, but macOS keeps the transparent proxy's configuration, so its
/// system extension stays activated and running with no app (seen on macOS
/// 27.0.1, 1.8.7). Uninstall removes the configurations first, then asks
/// macOS to deactivate both extensions.
public enum AppUninstaller {
    /// Keys only this Mac holds. The iCloud sync key is synchronizable and is
    /// never deleted: that would delete it on the user's other devices too.
    public static let localKeychainServices = [
        DataProtectionProfileKeyStore.defaultService,
        DataProtectionProfileKeyStore.fakeIPCacheService,
    ]

    public static func plan(
        deletingUserData: Bool,
        extensionIdentifiers: [String]
    ) -> [UninstallStep] {
        var steps: [UninstallStep] = [.disconnect, .removeNetworkConfigurations]
        steps += extensionIdentifiers.map(UninstallStep.deactivateExtension)
        steps.append(.unregisterLoginItem)
        if deletingUserData {
            steps.append(.deleteUserData)
        }
        steps.append(.moveAppToTrash)
        return steps
    }

    /// Runs every step even when one fails, so the most is removed. The app
    /// goes to the Trash only when its configurations and extensions are
    /// gone; otherwise it stays so the user can run Uninstall again.
    @MainActor
    public static func run(
        _ steps: [UninstallStep],
        performer: some UninstallStepPerforming
    ) async -> UninstallReport {
        var entries: [UninstallReport.Entry] = []
        var networkRemovalFailed = false
        for step in steps {
            if step == .moveAppToTrash, networkRemovalFailed {
                entries.append(.init(step: step, outcome: .skipped))
                continue
            }
            let outcome = await performer.perform(step)
            entries.append(.init(step: step, outcome: outcome))
            if case .failed = outcome, removesSomethingThatRuns(step) {
                networkRemovalFailed = true
            }
        }
        return UninstallReport(entries: entries)
    }

    static func removesSomethingThatRuns(_ step: UninstallStep) -> Bool {
        switch step {
        case .removeNetworkConfigurations, .deactivateExtension: true
        case .disconnect, .unregisterLoginItem, .deleteUserData, .moveAppToTrash: false
        }
    }
}
