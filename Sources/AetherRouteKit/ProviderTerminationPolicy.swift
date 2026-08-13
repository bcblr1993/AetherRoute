import Foundation

public enum ProviderTerminationPolicy {
    public static func isUnexpectedTerminalState(
        currentIsTerminal: Bool,
        previousWasActive: Bool,
        connectionAttemptPending: Bool,
        disconnectionAttemptPending: Bool
    ) -> Bool {
        currentIsTerminal
            && !disconnectionAttemptPending
            && (connectionAttemptPending || previousWasActive)
    }
}

public enum ProviderDisconnectErrorKind: Sendable, Equatable {
    case unavailable
    case competingNetworkExtension
    case other
}

public enum ProviderDisconnectErrorClassifier {
    public static func classify(_ error: NSError?)
        -> ProviderDisconnectErrorKind
    {
        guard let error else { return .unavailable }
        var visited: Set<ObjectIdentifier> = []
        return containsBusyPOSIXError(
            error,
            remainingDepth: 8,
            visited: &visited
        ) ? .competingNetworkExtension : .other
    }

    private static func containsBusyPOSIXError(
        _ error: NSError,
        remainingDepth: Int,
        visited: inout Set<ObjectIdentifier>
    ) -> Bool {
        guard remainingDepth > 0 else { return false }
        let identifier = ObjectIdentifier(error)
        guard visited.insert(identifier).inserted else { return false }
        if error.domain == NSPOSIXErrorDomain, error.code == 16 {
            return true
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey]
            as? NSError else {
            return false
        }
        return containsBusyPOSIXError(
            underlying,
            remainingDepth: remainingDepth - 1,
            visited: &visited
        )
    }
}
