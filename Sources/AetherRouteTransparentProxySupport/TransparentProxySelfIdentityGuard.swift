import AetherRouteKit
import Darwin
import Foundation
import NetworkExtension
import OSLog
import Security

/// Decides whether a transparent-proxy flow originated from this extension.
///
/// Platform contract this implementation relies on (macOS 15+, arm64):
///
/// - `NEFlowMetaData.sourceAppSigningIdentifier` is a **non-optional** string.
///   Apple documents it as "almost always equivalent to the bundle identifier",
///   and empty only when the flow originates from a system process. It is the
///   cheapest and most reliable self-identification signal, so it is primary.
/// - `NEFlowMetaData.sourceAppAuditToken` is **nullable** and is legitimately
///   absent for a large class of real traffic. It can therefore only ever be a
///   secondary confirmation, never the gate.
/// - An unidentifiable source means "a process we could not name", which for a
///   transparent proxy is ordinary traffic — most often a system daemon such as
///   `mDNSResponder`. Such flows are proxied, never closed. Claiming and closing
///   them takes the whole machine offline, and blanket-bypassing them breaks
///   system services that do not tolerate a refused flow.
/// - Expensive code-signature validation is performed **once per process** and
///   recorded for diagnostics only. It must never run per flow: it is a
///   significant cost on the connection hot path.
///
/// Disposition contract, matching `NEAppProxyProvider.handleNewFlow`:
/// `bypass` -> return `false` (the system carries the flow directly),
/// `proxy`  -> return `true` and claim it into the data plane,
/// `reject` -> claim and close. Reserved for genuine internal inconsistency;
/// it is never produced by identity evaluation.
public struct TransparentProxySelfIdentityGuard: Sendable {
    private static let diagnosticLog = DiagnosticLogCenter.current.log(
        category: "transparent-self-identity"
    )

    public enum Disposition: Equatable, Sendable {
        /// Verified egress from this extension. Let the OS carry it so the
        /// provider cannot intercept itself recursively.
        case bypass
        /// Any other source, including unidentifiable ones. Route it.
        case proxy
        /// Claim and close. Never produced by identity evaluation.
        case reject
    }

    /// Why a disposition was chosen. Bounded and free of addresses, ports and
    /// payload, so it is safe for the diagnostic log.
    public enum Reason: String, Equatable, Sendable {
        /// Signing identifier, PID, and code-signature anchor all match this extension.
        case signingIdentifierMatchedSelf
        /// Signing identifier was unavailable, and PID + code-signature anchor resolved to this process.
        case auditTokenMatchedSelf
        /// Another process attempted to claim this extension's signing identifier.
        case spoofedSelfSigningIdentifier
        /// PID matched, but code-signature / Team ID anchor verification failed.
        case codeSignatureAnchorMismatch
        /// A named source process that is not this extension.
        case signingIdentifierDiffers
        /// No signing identifier, but the audit token named another process.
        case auditTokenDiffers
        /// Neither signal available. Apple documents this for system-process
        /// flows. Proxied, because refusing it breaks system services.
        case systemProcessWithoutIdentity
    }

    public struct Evaluation: Equatable, Sendable {
        public let disposition: Disposition
        public let reason: Reason
        /// Empty when the platform reported no signing identifier.
        public let signingIdentifier: String
        /// `0` when no audit token was supplied.
        public let auditTokenByteCount: Int
        /// `0` when the source process could not be resolved.
        public let sourceProcessIdentifier: pid_t

        public var shouldBypassProxy: Bool { disposition == .bypass }
    }

    private let identityVerifier: any TransparentProxyFlowIdentityVerifying
    private let currentProcessIdentifier: @Sendable () -> pid_t
    private let selfSigningIdentifiers: Set<String>
    /// Result of the one-time startup code-identity check. Diagnostic only: it
    /// deliberately does not gate any flow decision.
    public let selfCodeIdentityVerified: Bool

    public init() {
        let verifier = SecurityTransparentProxyFlowIdentityVerifier()
        var identifiers: Set<String> = []
        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           !bundleIdentifier.isEmpty {
            identifiers.insert(bundleIdentifier)
        }
        // Only the running transparent-proxy extension is self egress. The host
        // app deliberately performs the end-to-end readiness request, so
        // treating the host or packet-tunnel sibling as self would bypass that
        // request and turn a healthy proxy into a false timeout whenever the
        // machine's direct route cannot reach the canary.
        let info = Bundle.main.infoDictionary ?? [:]
        if let proxyIdentifier =
            info["AetherRouteTransparentProxyBundleIdentifier"] as? String,
            !proxyIdentifier.isEmpty {
            identifiers.insert(proxyIdentifier)
        }
        let codeIdentityVerified = Self.validateOwnCodeIdentity(using: verifier)
        Self.diagnosticLog.aggregate(
            """
            stage=identityGuardInit \
            selfSigningIdentifiers=\(identifiers.sorted().joined(separator: ",")) \
            selfPID=\(getpid()) \
            selfCodeIdentityVerified=\(codeIdentityVerified)
            """
        )
        self.init(
            identityVerifier: verifier,
            currentProcessIdentifier: { getpid() },
            selfSigningIdentifiers: identifiers,
            selfCodeIdentityVerified: codeIdentityVerified
        )
    }

    init(
        identityVerifier: any TransparentProxyFlowIdentityVerifying,
        currentProcessIdentifier: @escaping @Sendable () -> pid_t,
        selfSigningIdentifiers: Set<String> = [],
        selfCodeIdentityVerified: Bool = false
    ) {
        self.identityVerifier = identityVerifier
        self.currentProcessIdentifier = currentProcessIdentifier
        self.selfSigningIdentifiers = selfSigningIdentifiers
        self.selfCodeIdentityVerified = selfCodeIdentityVerified
    }

    /// Production adapter for `NEAppProxyFlow`. Tests use the value-based entry
    /// point below and never need to manufacture an `NEFlowMetaData` instance.
    public func evaluate(flow: NEAppProxyFlow) -> Evaluation {
        evaluate(
            signingIdentifier: flow.metaData.sourceAppSigningIdentifier,
            auditToken: flow.metaData.sourceAppAuditToken
        )
    }

    /// Retained for the audit-token-only call site and for regression tests
    /// that predate the signing-identifier signal.
    func evaluate(auditToken: Data?) -> Evaluation {
        evaluate(signingIdentifier: "", auditToken: auditToken)
    }

    func evaluate(signingIdentifier: String, auditToken: Data?) -> Evaluation {
        let sourcePID = resolveProcessIdentifier(from: auditToken)
        let tokenByteCount = auditToken?.count ?? 0
        let selfPID = currentProcessIdentifier()
        let signingMatchesSelf = !signingIdentifier.isEmpty
            && selfSigningIdentifiers.contains(signingIdentifier)

        // 1. Self-bypass strictly requires:
        //    (a) a kernel-supplied audit token whose PID equals `currentProcessIdentifier()`,
        //    (b) if `signingIdentifier` is non-empty, it must match our own extension ID, and
        //    (c) code-signature / Team ID anchor verification on the audit token must succeed.
        //    This completely blocks local processes using `codesign -s - -i <BundleID>`
        //    from spoofing `sourceAppSigningIdentifier` to bypass the global proxy.
        if sourcePID > 0, selfPID > 0, sourcePID == selfPID {
            if !signingIdentifier.isEmpty, !signingMatchesSelf {
                return finish(
                    .proxy,
                    .signingIdentifierDiffers,
                    signingIdentifier: signingIdentifier,
                    auditTokenByteCount: tokenByteCount,
                    sourceProcessIdentifier: sourcePID
                )
            }
            guard let auditToken,
                  identityVerifier.verifySelfCodeIdentity(for: auditToken) else {
                return finish(
                    .proxy,
                    .codeSignatureAnchorMismatch,
                    signingIdentifier: signingIdentifier,
                    auditTokenByteCount: tokenByteCount,
                    sourceProcessIdentifier: sourcePID
                )
            }
            return finish(
                .bypass,
                signingMatchesSelf ? .signingIdentifierMatchedSelf : .auditTokenMatchedSelf,
                signingIdentifier: signingIdentifier,
                auditTokenByteCount: tokenByteCount,
                sourceProcessIdentifier: sourcePID
            )
        }

        // 2. Spoofed self signing identifier (missing audit token or different PID).
        if signingMatchesSelf {
            return finish(
                .proxy,
                .spoofedSelfSigningIdentifier,
                signingIdentifier: signingIdentifier,
                auditTokenByteCount: tokenByteCount,
                sourceProcessIdentifier: sourcePID
            )
        }

        // 3. A named source that is not us.
        if !signingIdentifier.isEmpty {
            return finish(
                .proxy,
                .signingIdentifierDiffers,
                signingIdentifier: signingIdentifier,
                auditTokenByteCount: tokenByteCount,
                sourceProcessIdentifier: sourcePID
            )
        }
        if sourcePID > 0 {
            return finish(
                .proxy,
                .auditTokenDiffers,
                signingIdentifier: signingIdentifier,
                auditTokenByteCount: tokenByteCount,
                sourceProcessIdentifier: sourcePID
            )
        }

        // 4. Neither signal. Apple documents this for system-process flows.
        //    Proxy it: refusing here is what takes the machine offline.
        return finish(
            .proxy,
            .systemProcessWithoutIdentity,
            signingIdentifier: signingIdentifier,
            auditTokenByteCount: tokenByteCount,
            sourceProcessIdentifier: sourcePID
        )
    }

    private func resolveProcessIdentifier(from auditToken: Data?) -> pid_t {
        guard let auditToken,
              auditToken.count == identityVerifier.auditTokenByteCount,
              let pid = try? identityVerifier.processIdentifier(from: auditToken),
              pid > 0
        else { return 0 }
        return pid
    }

    private func finish(
        _ disposition: Disposition,
        _ reason: Reason,
        signingIdentifier: String,
        auditTokenByteCount: Int,
        sourceProcessIdentifier: pid_t
    ) -> Evaluation {
        Self.diagnosticLog.verbose(
            """
            stage=identityEvaluate \
            disposition=\(String(describing: disposition)) \
            reason=\(reason.rawValue) \
            signingIdentifier=\(signingIdentifier.isEmpty ? "<empty>" : signingIdentifier) \
            auditTokenBytes=\(auditTokenByteCount) \
            sourcePID=\(sourceProcessIdentifier)
            """
        )
        return Evaluation(
            disposition: disposition,
            reason: reason,
            signingIdentifier: signingIdentifier,
            auditTokenByteCount: auditTokenByteCount,
            sourceProcessIdentifier: sourceProcessIdentifier
        )
    }

    /// Runs the strict code-signature check once, at construction. The result
    /// is recorded for diagnostics and never gates a flow: the audit token is
    /// supplied by the kernel through NetworkExtension, so re-validating a
    /// signature per flow buys no security and costs a great deal of time.
    private static func validateOwnCodeIdentity(
        using verifier: SecurityTransparentProxyFlowIdentityVerifier
    ) -> Bool {
        do {
            try verifier.validateRunningCodeAgainstDesignatedRequirement()
            return true
        } catch {
            diagnosticLog.failure(
                "stage=identityGuardInit selfCodeIdentityValidationFailed"
            )
            return false
        }
    }
}

/// Small injection boundary: unit tests can supply deterministic PID results
/// without constructing a real kernel audit token.
protocol TransparentProxyFlowIdentityVerifying: Sendable {
    var auditTokenByteCount: Int { get }

    func processIdentifier(from auditToken: Data) throws -> pid_t
    func verifySelfCodeIdentity(for auditToken: Data) -> Bool
}

extension TransparentProxyFlowIdentityVerifying {
    func verifySelfCodeIdentity(for auditToken: Data) -> Bool {
        true
    }
}

final class SecurityTransparentProxyFlowIdentityVerifier:
    TransparentProxyFlowIdentityVerifying,
    @unchecked Sendable
{
    let auditTokenByteCount = MemoryLayout<audit_token_t>.size

    private let cacheLock = NSLock()
    private var verifiedSelfAuditToken: Data?
    private let selfAnchor: SelfCodeSignatureAnchor?

    init() {
        self.selfAnchor = Self.captureOwnSignatureAnchor()
    }

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

    func verifySelfCodeIdentity(for auditToken: Data) -> Bool {
        guard auditToken.count == auditTokenByteCount else { return false }
        if cacheLock.withLock({ verifiedSelfAuditToken == auditToken }) {
            return true
        }
        guard let anchor = selfAnchor else { return false }

        let attributes = [
            kSecGuestAttributeAudit as String: auditToken as NSData
        ] as CFDictionary
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(rawValue: 0),
            &guestCode
        ) == errSecSuccess, let guestCode else {
            return false
        }

        guard SecCodeCheckValidity(
            guestCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            anchor.designatedRequirement
        ) == errSecSuccess else {
            return false
        }

        var guestStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            guestCode,
            SecCSFlags(rawValue: 0),
            &guestStaticCode
        ) == errSecSuccess, let guestStaticCode else {
            return false
        }

        var rawInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            guestStaticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInfo
        ) == errSecSuccess,
              let info = rawInfo as? [String: Any] else {
            return false
        }

        let guestTeamID = (info[kSecCodeInfoTeamIdentifier as String] as? String) ?? ""
        if !anchor.teamIdentifier.isEmpty {
            guard guestTeamID == anchor.teamIdentifier else {
                return false
            }
        }
        if let expectedCDHash = anchor.cdHash {
            let guestCDHash = info[kSecCodeInfoUnique as String] as? Data
            guard guestCDHash == expectedCDHash else {
                return false
            }
        }

        cacheLock.withLock {
            verifiedSelfAuditToken = auditToken
        }
        return true
    }

    /// One-time startup self check. Confirms this running extension satisfies
    /// its own designated requirement.
    func validateRunningCodeAgainstDesignatedRequirement() throws {
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

        var currentStaticCode: SecStaticCode?
        try requireSuccess(
            SecCodeCopyStaticCode(currentCode, defaultFlags, &currentStaticCode),
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

        try requireSuccess(
            SecCodeCheckValidity(
                currentCode,
                validationFlags,
                designatedRequirement
            )
        )
    }

    private struct SelfCodeSignatureAnchor: @unchecked Sendable {
        let designatedRequirement: SecRequirement
        let teamIdentifier: String
        let cdHash: Data?
    }

    private static func captureOwnSignatureAnchor() -> SelfCodeSignatureAnchor? {
        let defaultFlags = SecCSFlags(rawValue: 0)
        var currentCode: SecCode?
        guard SecCodeCopySelf(defaultFlags, &currentCode) == errSecSuccess,
              let currentCode else {
            return nil
        }
        var currentStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(currentCode, defaultFlags, &currentStaticCode) == errSecSuccess,
              let currentStaticCode else {
            return nil
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(
            currentStaticCode,
            defaultFlags,
            &requirement
        ) == errSecSuccess, let requirement else {
            return nil
        }
        guard SecCodeCheckValidity(
            currentCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            requirement
        ) == errSecSuccess else {
            return nil
        }
        var rawInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            currentStaticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInfo
        ) == errSecSuccess,
              let info = rawInfo as? [String: Any] else {
            return nil
        }
        let teamID = (info[kSecCodeInfoTeamIdentifier as String] as? String) ?? ""
        let cdHash = info[kSecCodeInfoUnique as String] as? Data
        return SelfCodeSignatureAnchor(
            designatedRequirement: requirement,
            teamIdentifier: teamID,
            cdHash: cdHash
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

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
