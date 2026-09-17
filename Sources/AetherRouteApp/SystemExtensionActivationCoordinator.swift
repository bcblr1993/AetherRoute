import Foundation
import AetherRouteKit
import OSLog
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
        let expectedVersion: SystemExtensionActivationPolicy.Version?
    }

    private var pendingActivation: PendingActivation?
    private var submittedRequest: OSSystemExtensionRequest?
    private var isCheckingProperties = false
    private var propertiesTimeout: Task<Void, Never>?
    private var activatedIdentifiers: Set<String> = []
    private let submitRequest: @MainActor (OSSystemExtensionRequest) -> Void
    private let bundledVersion: @MainActor (String) -> SystemExtensionActivationPolicy.Version?
    private let propertiesTimeoutDuration: Duration
    private static let logger = AppLog.logger(category: AppLog.Category.appActivation)

    init(
        submitRequest: @escaping @MainActor (OSSystemExtensionRequest) -> Void = {
            OSSystemExtensionManager.shared.submitRequest($0)
        },
        bundledVersion: @escaping @MainActor (String) -> SystemExtensionActivationPolicy.Version? = {
            SystemExtensionActivationCoordinator.bundledExtensionVersion(identifier: $0)
        },
        propertiesTimeoutDuration: Duration = .seconds(2)
    ) {
        self.submitRequest = submitRequest
        self.bundledVersion = bundledVersion
        self.propertiesTimeoutDuration = propertiesTimeoutDuration
        super.init()
    }

    func activate(
        identifier: String,
        onApprovalRequired: @escaping @MainActor @Sendable () -> Void
    ) async throws {
        if activatedIdentifiers.contains(identifier) {
            Self.logger.info("stage=activation cached identifier=\(identifier, privacy: .public)")
            return
        }
        guard pendingActivation == nil else {
            throw SystemExtensionActivationError.requestAlreadyInProgress
        }

        try await withCheckedThrowingContinuation { continuation in
            pendingActivation = PendingActivation(
                identifier: identifier,
                continuation: continuation,
                onApprovalRequired: onApprovalRequired,
                expectedVersion: bundledVersion(identifier)
            )
            guard pendingActivation?.expectedVersion != nil else {
                submitActivation()
                return
            }
            // In System Extension developer mode macOS calls the replacement
            // delegate even for identical versions. Query first so an ordinary
            // app restart cannot replace a healthy extension and leave another
            // copy waiting for removal after reboot.
            let request = OSSystemExtensionRequest.propertiesRequest(
                forExtensionWithIdentifier: identifier,
                queue: .main
            )
            isCheckingProperties = true
            propertiesTimeout = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: propertiesTimeoutDuration)
                } catch { return }
                guard submittedRequest === request, isCheckingProperties else {
                    return
                }
                Self.logger.info("stage=properties timeout; falling back to activation")
                submitActivation()
            }
            submit(request)
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        let installations = properties.map {
            SystemExtensionActivationPolicy.Installation(
                version: .init(
                    identifier: $0.bundleIdentifier,
                    build: $0.bundleVersion,
                    release: $0.bundleShortVersion
                ),
                isEnabled: $0.isEnabled,
                isAwaitingUserApproval: $0.isAwaitingUserApproval,
                isUninstalling: $0.isUninstalling
            )
        }
        Task { @MainActor [weak self] in
            guard let self, submittedRequest === request,
                  isCheckingProperties,
                  let expected = pendingActivation?.expectedVersion else { return }
            if SystemExtensionActivationPolicy.canReuse(
                expected: expected,
                installations: installations
            ) {
                Self.logger.info("stage=activation reuse identifier=\(expected.identifier, privacy: .public) build=\(expected.build, privacy: .public)")
                finish(.success(()))
            } else {
                submitActivation()
            }
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
                  submittedRequest === request, !isCheckingProperties else {
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
                  submittedRequest === request else {
                return
            }
            guard !isCheckingProperties else {
                submitActivation()
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
                  submittedRequest === request else {
                return
            }
            guard !isCheckingProperties else {
                Self.logger.info("stage=properties failed; falling back to activation")
                submitActivation()
                return
            }
            finish(.failure(SystemExtensionActivationError.framework(error)))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let pendingActivation else { return }
        if case .success = result {
            activatedIdentifiers.insert(pendingActivation.identifier)
        }
        self.pendingActivation = nil
        propertiesTimeout?.cancel()
        propertiesTimeout = nil
        isCheckingProperties = false
        submittedRequest?.delegate = nil
        submittedRequest = nil
        pendingActivation.continuation.resume(with: result)
    }

    private func submitActivation() {
        guard let pendingActivation else { return }
        propertiesTimeout?.cancel()
        propertiesTimeout = nil
        isCheckingProperties = false
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: pendingActivation.identifier,
            queue: .main
        )
        Self.logger.info("stage=activation submit identifier=\(pendingActivation.identifier, privacy: .public)")
        submit(request)
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        submittedRequest?.delegate = nil
        submittedRequest = request
        request.delegate = self
        submitRequest(request)
    }

    nonisolated private static func bundledExtensionVersion(
        identifier: String
    ) -> SystemExtensionActivationPolicy.Version? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(identifier).systemextension")
        guard let bundle = Bundle(url: url),
              bundle.bundleIdentifier == identifier,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let release = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !build.isEmpty, !release.isEmpty else { return nil }
        return .init(identifier: identifier, build: build, release: release)
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
