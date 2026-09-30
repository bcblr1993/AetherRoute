import Foundation

/// What the menu bar knows about updates. Sparkle reports each step of a
/// check through delegate callbacks; this folds them into the one value the
/// footer and the status-item badge render.
public enum UpdateAvailability: Equatable, Sendable {
    case unknown
    case checking
    case upToDate
    case available(version: String)

    public enum Event: Equatable, Sendable {
        case checkStarted
        case foundUpdate(version: String)
        case noUpdateFound
        /// A check ended with an error (offline, bad feed). Keeps whatever
        /// was known before rather than claiming the app is current.
        case checkFailed
        /// The user skipped this version, or the update was installed.
        case updateDismissed
    }

    public func applying(_ event: Event) -> UpdateAvailability {
        switch event {
        case .checkStarted:
            // A known update stays visible while a new check runs.
            if case .available = self { return self }
            return .checking
        case let .foundUpdate(version):
            return .available(version: version)
        case .noUpdateFound, .updateDismissed:
            return .upToDate
        case .checkFailed:
            return self == .checking ? .unknown : self
        }
    }

    public var availableVersion: String? {
        if case let .available(version) = self { return version }
        return nil
    }
}
