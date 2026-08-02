import Foundation

public enum ConnectionFailureContext: String, Codable, Sendable {
    case missingProfile
    case configuration
    case provider
    case unknown
}

public enum ConnectionRecoveryAction: String, Codable, Sendable {
    case retry
    case reviewProfiles
}

public struct ConnectionRecoveryPlan: Equatable, Sendable {
    public let context: ConnectionFailureContext
    public let primaryAction: ConnectionRecoveryAction
    public let secondaryAction: ConnectionRecoveryAction?

    public init(context: ConnectionFailureContext) {
        self.context = context
        switch context {
        case .missingProfile:
            primaryAction = .reviewProfiles
            secondaryAction = nil
        case .configuration, .provider, .unknown:
            primaryAction = .retry
            secondaryAction = .reviewProfiles
        }
    }
}
