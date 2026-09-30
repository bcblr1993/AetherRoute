import Foundation

/// Where one network engine stands in first-run setup. Each engine needs two
/// things macOS only grants through the user: its system extension switched
/// on in System Settings, and a VPN / proxy configuration the user allowed.
public enum NetworkSetupStepState: Equatable, Sendable {
    /// Status is still being read from the system.
    case checking
    /// Nothing granted yet, or the installed extension is from another build.
    case pending
    /// The extension request was submitted and macOS has not answered yet.
    case installingExtension
    /// macOS is waiting for the user to switch the extension on.
    case awaitingApproval
    /// The configuration is being saved; macOS may be asking to allow it.
    case awaitingConfigurationConsent
    case ready
    /// The extension installs only after a restart.
    case rebootRequired
    /// `isRetryable` is false when the user cannot fix it from here, for
    /// example when an organisation's policy blocks the extension.
    case failed(reason: String, isRetryable: Bool)

    public var isReady: Bool { self == .ready }

    public var isInProgress: Bool {
        switch self {
        case .installingExtension, .awaitingApproval, .awaitingConfigurationConsent:
            true
        default:
            false
        }
    }

    public var isBlockedPermanently: Bool {
        if case let .failed(_, isRetryable) = self { return !isRetryable }
        return false
    }
}

/// What macOS reports about an engine's system extension, read without
/// prompting the user.
public enum NetworkExtensionProbe: Equatable, Sendable {
    case notInstalled
    case awaitingApproval
    case enabled(isCurrentBuild: Bool)
    case uninstalling
    /// The system did not answer in time; treated as not yet set up.
    case unknown
}

public enum NetworkSetupProgress {
    /// The state shown before the user starts setup, from what is already
    /// on the system.
    public static func detectedState(
        extension probe: NetworkExtensionProbe,
        hasConfiguration: Bool
    ) -> NetworkSetupStepState {
        switch probe {
        case .awaitingApproval:
            .awaitingApproval
        case .enabled(isCurrentBuild: true):
            hasConfiguration ? .ready : .pending
        case .enabled(isCurrentBuild: false), .notInstalled, .uninstalling, .unknown:
            .pending
        }
    }

    /// Setup is done when every engine is ready. An engine that is blocked
    /// for good (organisation policy) does not keep the user out as long as
    /// another engine works; they are told which one is unavailable.
    public static func canFinish(_ states: [NetworkSetupStepState]) -> Bool {
        guard !states.isEmpty, states.contains(where: \.isReady) else { return false }
        return states.allSatisfy { $0.isReady || $0.isBlockedPermanently }
    }

    public enum PrimaryAction: Equatable, Sendable {
        case start
        case waiting
        case retry
        case finish
        case restartRequired
    }

    public static func primaryAction(
        for states: [NetworkSetupStepState],
        isRunning: Bool
    ) -> PrimaryAction {
        if canFinish(states) { return .finish }
        if isRunning || states.contains(where: \.isInProgress) { return .waiting }
        if states.contains(where: { $0 == .checking }) { return .waiting }
        if states.contains(.rebootRequired)
            && !states.contains(where: { $0 == .pending || Self.isRetryableFailure($0) }) {
            return .restartRequired
        }
        if states.contains(where: Self.isRetryableFailure) { return .retry }
        return .start
    }

    private static func isRetryableFailure(_ state: NetworkSetupStepState) -> Bool {
        if case let .failed(_, isRetryable) = state { return isRetryable }
        return false
    }

    /// Whether first-run setup should block the main window.
    ///
    /// - Parameters:
    ///   - hasCompletedSetup: the persisted "setup finished" flag.
    ///   - isExistingInstall: the app was already in use before this version
    ///     (privacy disclosure accepted earlier). Existing users keep using
    ///     the engine they have; they are not sent back through setup.
    ///   - isAutomation: QA automation and UI review builds skip the gate.
    public static func requiresGate(
        hasCompletedSetup: Bool,
        isExistingInstall: Bool,
        isAutomation: Bool
    ) -> Bool {
        !(hasCompletedSetup || isExistingInstall || isAutomation)
    }
}
