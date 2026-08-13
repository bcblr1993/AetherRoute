import Darwin
import Foundation
import XCTest
@testable import AetherRouteTransparentProxySupport

final class TransparentProxySelfIdentityGuardTests: XCTestCase {
    private let tokenByteCount = MemoryLayout<audit_token_t>.size
    private let selfIdentifier = "com.aetherroute.desktop.transparent-proxy"

    // MARK: - Self egress must bypass

    func testMatchingSigningIdentifierBypassesWithoutAuditToken() {
        let guardUnderTest = makeGuard(pid: 41)

        let result = guardUnderTest.evaluate(
            signingIdentifier: selfIdentifier,
            auditToken: nil
        )

        XCTAssertEqual(result.disposition, .bypass)
        XCTAssertEqual(result.reason, .signingIdentifierMatchedSelf)
        XCTAssertTrue(result.shouldBypassProxy)
    }

    func testMatchingAuditTokenPIDBypassesWithoutSigningIdentifier() {
        let guardUnderTest = makeGuard(pid: 41, currentPID: 41)

        let result = guardUnderTest.evaluate(
            signingIdentifier: "",
            auditToken: validLengthToken()
        )

        XCTAssertEqual(result.disposition, .bypass)
        XCTAssertEqual(result.reason, .auditTokenMatchedSelf)
    }

    /// Upstream egress can carry the identifier of any bundle in the product.
    /// Missing a sibling re-proxies our own connection to the node, which is an
    /// infinite loop that leaves the tunnel unable to reach its server at all.
    func testSiblingProductBundlesAreTreatedAsSelfEgress() {
        let guardUnderTest = TransparentProxySelfIdentityGuard(
            identityVerifier: StubIdentityVerifier(mode: .success(pid: 99)),
            currentProcessIdentifier: { 41 },
            selfSigningIdentifiers: [
                "com.aetherroute.desktop",
                "com.aetherroute.desktop.tunnel",
                "com.aetherroute.desktop.transparent-proxy",
            ]
        )

        for identifier in [
            "com.aetherroute.desktop",
            "com.aetherroute.desktop.tunnel",
            "com.aetherroute.desktop.transparent-proxy",
        ] {
            let result = guardUnderTest.evaluate(
                signingIdentifier: identifier,
                auditToken: nil
            )
            XCTAssertEqual(
                result.disposition,
                .bypass,
                "\(identifier) must bypass to break upstream recursion"
            )
            XCTAssertEqual(result.reason, .signingIdentifierMatchedSelf)
        }

        // A lookalike outside the product must still be proxied.
        XCTAssertEqual(
            guardUnderTest.evaluate(
                signingIdentifier: "com.aetherroute.desktop.evil.example",
                auditToken: nil
            ).disposition,
            .proxy
        )
    }

    // MARK: - Everything else must be proxied, never closed

    /// The regression that took the product offline: a nil audit token is
    /// normal for system-process flows and must not close the connection.
    func testMissingAuditTokenIsProxiedNotRejected() {
        let guardUnderTest = makeGuard(pid: 41)

        let result = guardUnderTest.evaluate(auditToken: nil)

        XCTAssertEqual(result.disposition, .proxy)
        XCTAssertEqual(result.reason, .systemProcessWithoutIdentity)
        XCTAssertNotEqual(result.disposition, .reject)
    }

    func testShortAuditTokenIsProxiedNotRejected() {
        let guardUnderTest = makeGuard(pid: 41)

        let result = guardUnderTest.evaluate(
            auditToken: Data(repeating: 0, count: tokenByteCount - 1)
        )

        XCTAssertEqual(result.disposition, .proxy)
        XCTAssertEqual(result.auditTokenByteCount, tokenByteCount - 1)
    }

    func testLongAuditTokenIsProxiedNotRejected() {
        let guardUnderTest = makeGuard(pid: 41)

        let result = guardUnderTest.evaluate(
            auditToken: Data(repeating: 0, count: tokenByteCount + 1)
        )

        XCTAssertEqual(result.disposition, .proxy)
    }

    func testAuditTokenInspectionFailureIsProxiedNotRejected() {
        let guardUnderTest = TransparentProxySelfIdentityGuard(
            identityVerifier: StubIdentityVerifier(mode: .pidFailure),
            currentProcessIdentifier: { 41 },
            selfSigningIdentifiers: [selfIdentifier]
        )

        let result = guardUnderTest.evaluate(auditToken: validLengthToken())

        XCTAssertEqual(result.disposition, .proxy)
        XCTAssertEqual(result.reason, .systemProcessWithoutIdentity)
    }

    func testDifferentSigningIdentifierIsProxied() {
        let guardUnderTest = makeGuard(pid: 42, currentPID: 41)

        let result = guardUnderTest.evaluate(
            signingIdentifier: "com.apple.Safari",
            auditToken: validLengthToken()
        )

        XCTAssertEqual(result.disposition, .proxy)
        XCTAssertEqual(result.reason, .signingIdentifierDiffers)
        XCTAssertEqual(result.sourceProcessIdentifier, 42)
    }

    func testDifferentPIDWithoutSigningIdentifierIsProxied() {
        let guardUnderTest = makeGuard(pid: 42, currentPID: 41)

        let result = guardUnderTest.evaluate(
            signingIdentifier: "",
            auditToken: validLengthToken()
        )

        XCTAssertEqual(result.disposition, .proxy)
        XCTAssertEqual(result.reason, .auditTokenDiffers)
    }

    /// An invalid current PID must not turn ordinary traffic into a closed
    /// flow. The source is simply unidentifiable and gets proxied.
    func testInvalidCurrentPIDStillProxies() {
        let guardUnderTest = makeGuard(pid: 41, currentPID: 0)

        let result = guardUnderTest.evaluate(auditToken: validLengthToken())

        XCTAssertEqual(result.disposition, .proxy)
    }

    // MARK: - Contract guarantees

    /// Identity evaluation must never close a flow. `reject` stays in the
    /// enum for genuine internal inconsistency handled elsewhere.
    func testIdentityEvaluationNeverRejects() {
        let guardUnderTest = makeGuard(pid: 42, currentPID: 41)

        let evaluations = [
            guardUnderTest.evaluate(signingIdentifier: "", auditToken: nil),
            guardUnderTest.evaluate(
                signingIdentifier: "",
                auditToken: validLengthToken()
            ),
            guardUnderTest.evaluate(
                signingIdentifier: "com.apple.Safari",
                auditToken: nil
            ),
            guardUnderTest.evaluate(
                signingIdentifier: selfIdentifier,
                auditToken: nil
            ),
            guardUnderTest.evaluate(
                signingIdentifier: "",
                auditToken: Data(repeating: 0, count: 3)
            ),
        ]

        XCTAssertTrue(evaluations.allSatisfy { $0.disposition != .reject })
    }

    func testOnlySelfMatchesReportBypass() {
        let guardUnderTest = makeGuard(pid: 41, currentPID: 41)

        XCTAssertTrue(
            guardUnderTest.evaluate(
                signingIdentifier: selfIdentifier,
                auditToken: nil
            ).shouldBypassProxy
        )
        XCTAssertFalse(
            guardUnderTest.evaluate(
                signingIdentifier: "com.apple.Safari",
                auditToken: nil
            ).shouldBypassProxy
        )
    }

    /// The signing identifier is the primary signal, so a self match must win
    /// even when the audit token names a different process.
    func testSigningIdentifierTakesPrecedenceOverAuditToken() {
        let guardUnderTest = makeGuard(pid: 999, currentPID: 41)

        let result = guardUnderTest.evaluate(
            signingIdentifier: selfIdentifier,
            auditToken: validLengthToken()
        )

        XCTAssertEqual(result.disposition, .bypass)
        XCTAssertEqual(result.reason, .signingIdentifierMatchedSelf)
    }

    func testProductionVerifierUsesKernelAuditTokenSize() {
        XCTAssertEqual(
            SecurityTransparentProxyFlowIdentityVerifier().auditTokenByteCount,
            MemoryLayout<audit_token_t>.size
        )
        XCTAssertEqual(MemoryLayout<audit_token_t>.size, 32)
    }

    private func makeGuard(
        pid: pid_t,
        currentPID: pid_t = 41
    ) -> TransparentProxySelfIdentityGuard {
        TransparentProxySelfIdentityGuard(
            identityVerifier: StubIdentityVerifier(mode: .success(pid: pid)),
            currentProcessIdentifier: { currentPID },
            selfSigningIdentifiers: [selfIdentifier]
        )
    }

    private func validLengthToken() -> Data {
        Data(repeating: 0xA5, count: tokenByteCount)
    }
}

private struct StubIdentityVerifier: TransparentProxyFlowIdentityVerifying {
    enum Mode: Sendable {
        case success(pid: pid_t)
        case pidFailure
    }

    let auditTokenByteCount = MemoryLayout<audit_token_t>.size
    let mode: Mode

    func processIdentifier(from auditToken: Data) throws -> pid_t {
        switch mode {
        case let .success(pid):
            pid
        case .pidFailure:
            throw StubError.expectedFailure
        }
    }

    private enum StubError: Error {
        case expectedFailure
    }
}
