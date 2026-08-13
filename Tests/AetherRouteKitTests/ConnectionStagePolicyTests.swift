import Testing
@testable import AetherRouteKit

@Suite("Connection stage policy")
struct ConnectionStagePolicyTests {
    @Test("an idle provider is still waiting on authorization")
    func inactiveProviderReportsAuthorization() {
        #expect(
            ConnectionStagePolicy.stage(
                providerPhase: .inactive,
                isVerifyingReadiness: false
            ) == .systemAuthorization
        )
    }

    @Test("a launching provider reports extension startup")
    func startingProviderReportsExtensionStartup() {
        #expect(
            ConnectionStagePolicy.stage(
                providerPhase: .starting,
                isVerifyingReadiness: false
            ) == .extensionStartup
        )
    }

    @Test("an established tunnel means the handshake already completed")
    func establishedProviderReportsHandshake() {
        #expect(
            ConnectionStagePolicy.stage(
                providerPhase: .established,
                isVerifyingReadiness: false
            ) == .protocolHandshake
        )
    }

    @Test("readiness verification is only reachable once the tunnel is up")
    func readinessRequiresAnEstablishedTunnel() {
        #expect(
            ConnectionStagePolicy.stage(
                providerPhase: .established,
                isVerifyingReadiness: true
            ) == .readinessCheck
        )
        // A readiness flag cannot drag the display ahead of the provider: the
        // fail-closed check runs after the tunnel, never before it.
        #expect(
            ConnectionStagePolicy.stage(
                providerPhase: .inactive,
                isVerifyingReadiness: true
            ) == .systemAuthorization
        )
        #expect(
            ConnectionStagePolicy.stage(
                providerPhase: .starting,
                isVerifyingReadiness: true
            ) == .extensionStartup
        )
    }

    @Test("stages advance monotonically as the provider comes up")
    func stagesAdvanceInOrder() {
        let progression = [
            ConnectionStagePolicy.stage(
                providerPhase: .inactive,
                isVerifyingReadiness: false
            ),
            ConnectionStagePolicy.stage(
                providerPhase: .starting,
                isVerifyingReadiness: false
            ),
            ConnectionStagePolicy.stage(
                providerPhase: .established,
                isVerifyingReadiness: false
            ),
            ConnectionStagePolicy.stage(
                providerPhase: .established,
                isVerifyingReadiness: true
            ),
        ]
        #expect(progression == ConnectionStage.allCases)
        #expect(progression.map(\.rawValue) == [0, 1, 2, 3])
    }
}
