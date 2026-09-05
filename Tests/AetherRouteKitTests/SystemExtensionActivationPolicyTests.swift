import Testing
@testable import AetherRouteKit

@Suite("System extension activation policy")
struct SystemExtensionActivationPolicyTests {
    private let current = SystemExtensionActivationPolicy.Version(
        identifier: "com.aetherroute.desktop.tunnel", build: "1470", release: "1.0.0"
    )

    @Test("exact enabled version can be reused across app restarts")
    func reuseActiveVersion() {
        #expect(SystemExtensionActivationPolicy.canReuse(
            expected: current,
            installations: [installation()]
        ))
    }

    @Test("inactive, unapproved, and retiring versions still require activation")
    func lifecycleStatesRequireActivation() {
        for existing in [
            installation(enabled: false),
            installation(awaitingApproval: true),
            installation(uninstalling: true),
        ] {
            #expect(!SystemExtensionActivationPolicy.canReuse(
                expected: current, installations: [existing]
            ))
        }
        #expect(!SystemExtensionActivationPolicy.canReuse(
            expected: current, installations: []
        ))
    }

    @Test("both version fields and the extension identifier must match")
    func upgradeAndOtherEngineRequireActivation() {
        for version in [
            SystemExtensionActivationPolicy.Version(
                identifier: current.identifier, build: "1469", release: current.release
            ),
            .init(identifier: current.identifier, build: current.build, release: "0.9.0"),
            .init(identifier: "com.aetherroute.desktop.transparent-proxy", build: current.build, release: current.release),
            .init(identifier: current.identifier, build: "", release: current.release),
        ] {
            #expect(!SystemExtensionActivationPolicy.canReuse(
                expected: current, installations: [installation(version: version)]
            ))
        }
    }

    @Test("retired copies do not conceal the current healthy installation")
    func reuseCurrentAlongsideRetiredCopy() {
        #expect(SystemExtensionActivationPolicy.canReuse(
            expected: current,
            installations: [installation(uninstalling: true), installation()]
        ))
    }

    private func installation(
        version: SystemExtensionActivationPolicy.Version? = nil,
        enabled: Bool = true,
        awaitingApproval: Bool = false,
        uninstalling: Bool = false
    ) -> SystemExtensionActivationPolicy.Installation {
        .init(
            version: version ?? current,
            isEnabled: enabled,
            isAwaitingUserApproval: awaitingApproval,
            isUninstalling: uninstalling
        )
    }
}
