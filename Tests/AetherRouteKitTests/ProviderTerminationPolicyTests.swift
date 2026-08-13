import Foundation
import Testing
@testable import AetherRouteKit

@Suite("Provider termination policy")
struct ProviderTerminationPolicyTests {
    @Test("startup returning to a terminal state is unexpected")
    func startupTerminationIsUnexpected() {
        #expect(
            ProviderTerminationPolicy.isUnexpectedTerminalState(
                currentIsTerminal: true,
                previousWasActive: true,
                connectionAttemptPending: true,
                disconnectionAttemptPending: false
            )
        )
    }

    @Test("an explicit cancellation reaches the terminal state normally")
    func explicitCancellationIsNormal() {
        #expect(
            !ProviderTerminationPolicy.isUnexpectedTerminalState(
                currentIsTerminal: true,
                previousWasActive: true,
                connectionAttemptPending: false,
                disconnectionAttemptPending: true
            )
        )
    }

    @Test("the initial disconnected state is normal")
    func initialDisconnectedStateIsNormal() {
        #expect(
            !ProviderTerminationPolicy.isUnexpectedTerminalState(
                currentIsTerminal: true,
                previousWasActive: false,
                connectionAttemptPending: false,
                disconnectionAttemptPending: false
            )
        )
    }

    @Test("a nonterminal provider status is never a termination")
    func activeStateIsNotTermination() {
        #expect(
            !ProviderTerminationPolicy.isUnexpectedTerminalState(
                currentIsTerminal: false,
                previousWasActive: true,
                connectionAttemptPending: true,
                disconnectionAttemptPending: false
            )
        )
    }

    @Test("nested POSIX busy identifies a competing network extension")
    func nestedBusyErrorIsClassified() {
        let busy = NSError(domain: NSPOSIXErrorDomain, code: 16)
        let wrapper = NSError(
            domain: "ProviderWrapper",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: busy]
        )

        #expect(
            ProviderDisconnectErrorClassifier.classify(wrapper)
                == .competingNetworkExtension
        )
    }

    @Test("missing and ordinary errors remain generic")
    func genericErrorClassification() {
        #expect(
            ProviderDisconnectErrorClassifier.classify(nil) == .unavailable
        )
        #expect(
            ProviderDisconnectErrorClassifier.classify(
                NSError(domain: "Provider", code: 12)
            ) == .other
        )
    }
}
