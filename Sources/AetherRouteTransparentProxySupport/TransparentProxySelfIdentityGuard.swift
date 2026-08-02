import Darwin
import Foundation
import NetworkExtension
import Security

/// The only condition under which a transparent-proxy flow may bypass the
/// proxy data plane is a cryptographically verified match with this extension.
/// Every missing, malformed, stale, or unverifiable identity fails closed.
public struct TransparentProxySelfIdentityGuard: Sendable {
    public enum FailureReason: Equatable, Sendable {
        case missingAuditToken
        case invalidAuditTokenLength(expected: Int, actual: Int)
        case invalidCurrentProcessIdentifier
        case auditTokenInspectionFailed
        case processIdentifierMismatch(expected: pid_t, actual: pid_t)
        case designatedRequirementValidationFailed
    }

    public enum Evaluation: Equatable, Sendable {
        case verifiedSelfEgress
        case notVerified(FailureReason)

        public enum Disposition: Equatable, Sendable {
            /// Let the operating system carry verified extension egress
            /// directly so the provider cannot intercept itself recursively.
            case bypass
            /// A valid audit token identified a different process; proxy it.
            case proxy
            /// Identity was missing or internally inconsistent. Claim and
            /// close the flow instead of bypassing it or risking recursion.
            case reject
        }

        public var shouldBypassProxy: Bool {
            self == .verifiedSelfEgress
        }

        public var disposition: Disposition {
            switch self {
            case .verifiedSelfEgress:
                .bypass
            case .notVerified(.processIdentifierMismatch):
                .proxy
            case .notVerified:
                .reject
            }
        }
    }

    private let identityVerifier: any TransparentProxyFlowIdentityVerifying
    private let currentProcessIdentifier: @Sendable () -> pid_t

    public init() {
        self.identityVerifier = SecurityTransparentProxyFlowIdentityVerifier()
        self.currentProcessIdentifier = { getpid() }
    }

    init(
        identityVerifier: any TransparentProxyFlowIdentityVerifying,
        currentProcessIdentifier: @escaping @Sendable () -> pid_t
    ) {
        self.identityVerifier = identityVerifier
        self.currentProcessIdentifier = currentProcessIdentifier
    }

    /// Production adapter for `NEAppProxyFlow`. Tests use the Data-based entry
    /// point below and never need to manufacture an `NEFlowMetaData` instance.
    public func evaluate(flow: NEAppProxyFlow) -> Evaluation {
        evaluate(auditToken: flow.metaData.sourceAppAuditToken)
    }

    func evaluate(auditToken: Data?) -> Evaluation {
        guard let auditToken else {
            return .notVerified(.missingAuditToken)
        }

        let expectedByteCount = identityVerifier.auditTokenByteCount
        guard auditToken.count == expectedByteCount else {
            return .notVerified(
                .invalidAuditTokenLength(
                    expected: expectedByteCount,
                    actual: auditToken.count
                )
            )
        }

        let expectedPID = currentProcessIdentifier()
        guard expectedPID > 0 else {
            return .notVerified(.invalidCurrentProcessIdentifier)
        }

        let tokenPID: pid_t
        do {
            tokenPID = try identityVerifier.processIdentifier(from: auditToken)
        } catch {
            return .notVerified(.auditTokenInspectionFailed)
        }

        guard tokenPID == expectedPID else {
            return .notVerified(
                .processIdentifierMismatch(expected: expectedPID, actual: tokenPID)
            )
        }

        do {
            try identityVerifier.validateCurrentDesignatedRequirement(
                for: auditToken
            )
        } catch {
            return .notVerified(.designatedRequirementValidationFailed)
        }

        return .verifiedSelfEgress
    }
}

/// Small injection boundary: unit tests can supply deterministic PID and code
/// identity results without constructing a real kernel audit token.
protocol TransparentProxyFlowIdentityVerifying: Sendable {
    var auditTokenByteCount: Int { get }

    func processIdentifier(from auditToken: Data) throws -> pid_t

    func validateCurrentDesignatedRequirement(for auditToken: Data) throws
}

struct SecurityTransparentProxyFlowIdentityVerifier:
    TransparentProxyFlowIdentityVerifying
{
    let auditTokenByteCount = MemoryLayout<audit_token_t>.size

    func processIdentifier(from auditToken: Data) throws -> pid_t {
        guard auditToken.count == auditTokenByteCount else {
            throw IdentityError.invalidAuditTokenLength
        }

        var token = audit_token_t()
        let copiedByteCount = withUnsafeMutableBytes(of: &token) { buffer in
            auditToken.copyBytes(to: buffer)
        }
        guard copiedByteCount == auditTokenByteCount else {
            throw IdentityError.invalidAuditTokenLength
        }

        let pid = audit_token_to_pid(token)
        guard pid > 0 else {
            throw IdentityError.invalidProcessIdentifier
        }
        return pid
    }

    func validateCurrentDesignatedRequirement(for auditToken: Data) throws {
        guard auditToken.count == auditTokenByteCount else {
            throw IdentityError.invalidAuditTokenLength
        }

        let defaultFlags = SecCSFlags(rawValue: 0)
        let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate)

        var currentCode: SecCode?
        try requireSuccess(
            SecCodeCopySelf(defaultFlags, &currentCode),
            resultPresent: currentCode != nil
        )
        guard let currentCode else {
            throw IdentityError.missingSecurityObject
        }

        try requireSuccess(
            SecCodeCheckValidity(currentCode, validationFlags, nil)
        )

        var currentStaticCode: SecStaticCode?
        try requireSuccess(
            SecCodeCopyStaticCode(
                currentCode,
                defaultFlags,
                &currentStaticCode
            ),
            resultPresent: currentStaticCode != nil
        )
        guard let currentStaticCode else {
            throw IdentityError.missingSecurityObject
        }

        var designatedRequirement: SecRequirement?
        try requireSuccess(
            SecCodeCopyDesignatedRequirement(
                currentStaticCode,
                defaultFlags,
                &designatedRequirement
            ),
            resultPresent: designatedRequirement != nil
        )
        guard let designatedRequirement else {
            throw IdentityError.missingSecurityObject
        }

        let attributes = [
            kSecGuestAttributeAudit as String: auditToken as NSData,
        ] as CFDictionary
        var sourceCode: SecCode?
        try requireSuccess(
            SecCodeCopyGuestWithAttributes(
                nil,
                attributes,
                defaultFlags,
                &sourceCode
            ),
            resultPresent: sourceCode != nil
        )
        guard let sourceCode else {
            throw IdentityError.missingSecurityObject
        }

        try requireSuccess(
            SecCodeCheckValidity(
                sourceCode,
                validationFlags,
                designatedRequirement
            )
        )
    }

    private func requireSuccess(
        _ status: OSStatus,
        resultPresent: Bool = true
    ) throws {
        guard status == errSecSuccess, resultPresent else {
            throw IdentityError.securityFrameworkFailure(status)
        }
    }

    private enum IdentityError: Error {
        case invalidAuditTokenLength
        case invalidProcessIdentifier
        case missingSecurityObject
        case securityFrameworkFailure(OSStatus)
    }
}
