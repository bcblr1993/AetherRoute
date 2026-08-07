import Foundation
@preconcurrency import SystemExtensions

@MainActor
protocol SystemExtensionActivating: AnyObject {
    func activate(
        identifier: String,
        onApprovalRequired: @escaping @MainActor @Sendable () -> Void
    ) async throws
}

@MainActor
final class SystemExtensionActivationCoordinator: NSObject,
    SystemExtensionActivating,
    OSSystemExtensionRequestDelegate
{
    private struct PendingActivation {
        let identifier: String
        let continuation: CheckedContinuation<Void, Error>
        let onApprovalRequired: @MainActor @Sendable () -> Void
    }

    private var pendingActivation: PendingActivation?
    private var submittedRequest: OSSystemExtensionRequest?

    func activate(
        identifier: String,
        onApprovalRequired: @escaping @MainActor @Sendable () -> Void
    ) async throws {
        guard pendingActivation == nil else {
            throw SystemExtensionActivationError.requestAlreadyInProgress
        }

        try await withCheckedThrowingContinuation { continuation in
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: identifier,
                queue: .main
            )
            pendingActivation = PendingActivation(
                identifier: identifier,
                continuation: continuation,
                onApprovalRequired: onApprovalRequired
            )
            submittedRequest = request
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(
        _ request: OSSystemExtensionRequest
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  pendingActivation?.identifier == request.identifier else {
                return
            }
            pendingActivation?.onApprovalRequired()
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  pendingActivation?.identifier == request.identifier else {
                return
            }
            switch result {
            case .completed:
                finish(.success(()))
            case .willCompleteAfterReboot:
                finish(.failure(SystemExtensionActivationError.rebootRequired))
            @unknown default:
                finish(.failure(SystemExtensionActivationError.unknownResult))
            }
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  pendingActivation?.identifier == request.identifier else {
                return
            }
            finish(.failure(SystemExtensionActivationError.framework(error)))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let pendingActivation else { return }
        self.pendingActivation = nil
        submittedRequest?.delegate = nil
        submittedRequest = nil
        pendingActivation.continuation.resume(with: result)
    }
}

private enum SystemExtensionActivationError: LocalizedError {
    case requestAlreadyInProgress
    case rebootRequired
    case unknownResult
    case framework(Error)

    var errorDescription: String? {
        switch self {
        case .requestAlreadyInProgress:
            AppLocalization.string(
                "The network extension installation is already in progress."
            )
        case .rebootRequired:
            AppLocalization.string(
                "The network extension was installed and will be available after this Mac restarts."
            )
        case .unknownResult:
            AppLocalization.string(
                "The network extension returned an unknown installation result."
            )
        case let .framework(error):
            Self.frameworkErrorDescription(error)
        }
    }

    private static func frameworkErrorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == OSSystemExtensionErrorDomain,
              let code = OSSystemExtensionError.Code(rawValue: nsError.code)
        else {
            return AppLocalization.string(
                "The network extension could not be installed. Retry once, then open Diagnostics if the problem continues."
            )
        }

        switch code {
        case .unsupportedParentBundleLocation:
            return AppLocalization.string(
                "Move AetherRoute to the Applications folder, reopen it, and try again."
            )
        case .codeSignatureInvalid, .validationFailed:
            return AppLocalization.string(
                "This copy of AetherRoute is damaged or incorrectly signed. Download a fresh official copy and try again."
            )
        case .extensionNotFound, .extensionMissingIdentifier,
             .duplicateExtensionIdentifer, .unknownExtensionCategory:
            return AppLocalization.string(
                "This AetherRoute package is incomplete. Download a fresh official copy and try again."
            )
        case .missingEntitlement:
            return AppLocalization.string(
                "This build does not have the required Network Extension permission. Install the signed official release."
            )
        case .forbiddenBySystemPolicy, .authorizationRequired:
            return AppLocalization.string(
                "macOS or your organization blocked this network extension. Review Network Extensions in System Settings or contact your administrator."
            )
        case .requestCanceled:
            return AppLocalization.string(
                "Network extension installation was canceled. Retry when you are ready."
            )
        case .requestSuperseded:
            return AppLocalization.string(
                "Another network extension request is already pending. Wait a moment, then try again."
            )
        case .unknown:
            return AppLocalization.string(
                "The network extension could not be installed. Retry once, then open Diagnostics if the problem continues."
            )
        @unknown default:
            return AppLocalization.string(
                "The network extension could not be installed. Retry once, then open Diagnostics if the problem continues."
            )
        }
    }
}
