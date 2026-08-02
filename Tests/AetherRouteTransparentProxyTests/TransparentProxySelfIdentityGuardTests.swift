import Darwin
import Foundation
import XCTest
@testable import AetherRouteTransparentProxySupport

final class TransparentProxySelfIdentityGuardTests: XCTestCase {
    private let tokenByteCount = MemoryLayout<audit_token_t>.size

    func testMissingAuditTokenFailsClosed() {
        let guardUnderTest = makeGuard(pid: 41)

        XCTAssertEqual(
            guardUnderTest.evaluate(auditToken: nil),
            .notVerified(.missingAuditToken)
        )
    }

    func testShortAuditTokenFailsClosedBeforeInspection() {
        let guardUnderTest = makeGuard(pid: 41)

        XCTAssertEqual(
            guardUnderTest.evaluate(
                auditToken: Data(repeating: 0, count: tokenByteCount - 1)
            ),
            .notVerified(
                .invalidAuditTokenLength(
                    expected: tokenByteCount,
                    actual: tokenByteCount - 1
                )
            )
        )
    }

    func testLongAuditTokenFailsClosedBeforeInspection() {
        let guardUnderTest = makeGuard(pid: 41)

        XCTAssertEqual(
            guardUnderTest.evaluate(
                auditToken: Data(repeating: 0, count: tokenByteCount + 1)
            ),
            .notVerified(
                .invalidAuditTokenLength(
                    expected: tokenByteCount,
                    actual: tokenByteCount + 1
                )
            )
        )
    }

    func testInvalidCurrentPIDFailsClosed() {
        let guardUnderTest = makeGuard(pid: 41, currentPID: 0)

        XCTAssertEqual(
            guardUnderTest.evaluate(auditToken: validLengthToken()),
            .notVerified(.invalidCurrentProcessIdentifier)
        )
    }

    func testAuditTokenInspectionFailureFailsClosed() {
        let guardUnderTest = TransparentProxySelfIdentityGuard(
            identityVerifier: StubIdentityVerifier(mode: .pidFailure),
            currentProcessIdentifier: { 41 }
        )

        XCTAssertEqual(
            guardUnderTest.evaluate(auditToken: validLengthToken()),
            .notVerified(.auditTokenInspectionFailed)
        )
    }

    func testPIDMismatchFailsClosed() {
        let guardUnderTest = makeGuard(pid: 42, currentPID: 41)

        XCTAssertEqual(
            guardUnderTest.evaluate(auditToken: validLengthToken()),
            .notVerified(.processIdentifierMismatch(expected: 41, actual: 42))
        )
    }

    func testDesignatedRequirementFailureFailsClosed() {
        let guardUnderTest = TransparentProxySelfIdentityGuard(
            identityVerifier: StubIdentityVerifier(
                mode: .signatureFailure(pid: 41)
            ),
            currentProcessIdentifier: { 41 }
        )

        XCTAssertEqual(
            guardUnderTest.evaluate(auditToken: validLengthToken()),
            .notVerified(.designatedRequirementValidationFailed)
        )
    }

    func testOnlyPIDAndDesignatedRequirementMatchCanBypass() {
        let guardUnderTest = makeGuard(pid: 41)
        let result = guardUnderTest.evaluate(
            auditToken: validLengthToken()
        )

        XCTAssertEqual(result, .verifiedSelfEgress)
        XCTAssertTrue(result.shouldBypassProxy)
        XCTAssertEqual(result.disposition, .bypass)
    }

    func testEveryFailureResultRefusesBypass() {
        let results: [TransparentProxySelfIdentityGuard.Evaluation] = [
            .notVerified(.missingAuditToken),
            .notVerified(.invalidCurrentProcessIdentifier),
            .notVerified(.auditTokenInspectionFailed),
            .notVerified(.processIdentifierMismatch(expected: 1, actual: 2)),
            .notVerified(.designatedRequirementValidationFailed),
        ]

        XCTAssertTrue(results.allSatisfy { !$0.shouldBypassProxy })
    }

    func testOnlyVerifiedExternalPIDIsEligibleForProxying() {
        XCTAssertEqual(
            TransparentProxySelfIdentityGuard.Evaluation.notVerified(
                .processIdentifierMismatch(expected: 41, actual: 42)
            ).disposition,
            .proxy
        )

        let unverifiable: [TransparentProxySelfIdentityGuard.Evaluation] = [
            .notVerified(.missingAuditToken),
            .notVerified(.invalidAuditTokenLength(expected: 32, actual: 0)),
            .notVerified(.invalidCurrentProcessIdentifier),
            .notVerified(.auditTokenInspectionFailed),
            .notVerified(.designatedRequirementValidationFailed),
        ]
        XCTAssertTrue(unverifiable.allSatisfy { $0.disposition == .reject })
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
            currentProcessIdentifier: { currentPID }
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
        case signatureFailure(pid: pid_t)
    }

    let auditTokenByteCount = MemoryLayout<audit_token_t>.size
    let mode: Mode

    func processIdentifier(from auditToken: Data) throws -> pid_t {
        switch mode {
        case let .success(pid), let .signatureFailure(pid):
            pid
        case .pidFailure:
            throw StubError.expectedFailure
        }
    }

    func validateCurrentDesignatedRequirement(for auditToken: Data) throws {
        if case .signatureFailure = mode {
            throw StubError.expectedFailure
        }
    }

    private enum StubError: Error {
        case expectedFailure
    }
}
