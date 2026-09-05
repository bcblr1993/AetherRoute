import AetherRouteKit
import Foundation

@MainActor
final class IndependentDistributionController: ObservableObject {
    enum LicenseState: Equatable {
        case notConfigured
        case inactive
        case active(LicenseEntitlement)
        case restricted(LicenseEntitlement)
        case failure(String)
    }

    enum UpdateState: Equatable {
        case notConfigured
        case idle
        case current(Date)
        case available(SoftwareUpdateManifest)
        case failure(String)
    }

    @Published private(set) var licenseState: LicenseState = .notConfigured
    @Published private(set) var updateState: UpdateState = .notConfigured
    @Published private(set) var connectionAccess:
        DistributionConnectionAccess = .verificationUnavailable
    private(set) var distributionMode: IndependentDistributionMode = .licensed
    @Published private(set) var licenseMessage: String?
    @Published private(set) var isActivating = false
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var isDownloadingUpdate = false
    @Published private(set) var updateDownloadMessage: String?
    @Published private(set) var updateDownloadSucceeded = false

    private let client: IndependentDistributionClient?
    private let credentialStore: any DistributionCredentialStoring
    private let appVersion: String
    private let appBuild: String
    private var hasLoaded = false

    init(
        bundle: Bundle = .main,
        credentialStore: any DistributionCredentialStoring =
            DataProtectionDistributionCredentialStore()
    ) {
        self.credentialStore = credentialStore
        appVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        appBuild = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "0"

        do {
            let policy = try Self.policy(bundle: bundle)
            distributionMode = policy.mode
            guard let configuration = policy.configuration
            else {
                client = nil
                connectionAccess = policy.mode == .free
                    ? .free : .unrestrictedDevelopment
                return
            }
            client = try IndependentDistributionClient.live(
                configuration: configuration
            )
            licenseState = .inactive
            connectionAccess = .activationRequired
            updateState = .idle
        } catch {
            client = nil
            let message = Self.safeMessage(error)
            licenseState = .failure(message)
            connectionAccess = .verificationUnavailable
            updateState = .failure(message)
        }
    }

    var isConfigured: Bool { client != nil }
    var isFreeDistribution: Bool { distributionMode == .free }

    func loadLocalReceipt() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let client else { return }
        do {
            let deviceID = try credentialStore.loadOrCreateDeviceID()
            guard let receipt = try credentialStore.loadReceipt() else {
                licenseState = .inactive
                connectionAccess = .activationRequired
                licenseMessage = nil
                return
            }
            let entitlement = try client.verifiedEntitlement(
                from: receipt,
                deviceID: deviceID
            )
            apply(entitlement)
        } catch {
            licenseState = .failure(Self.safeMessage(error))
            connectionAccess = Self.connectionAccess(for: error)
        }
    }

    func activate(licenseKey: String) async -> Bool {
        guard let client, !isActivating else { return false }
        isActivating = true
        defer { isActivating = false }
        do {
            let deviceID = try credentialStore.loadOrCreateDeviceID()
            let result = try await client.activateLicense(
                key: licenseKey,
                deviceID: deviceID,
                appVersion: appVersion,
                appBuild: appBuild
            )
            try credentialStore.saveReceipt(result.signedReceipt)
            apply(result.entitlement)
            return true
        } catch {
            licenseState = .failure(Self.safeMessage(error))
            licenseMessage = nil
            if !connectionAccess.permitsNewConnection {
                connectionAccess = Self.connectionAccess(for: error)
            }
            return false
        }
    }

    func refreshLicense() async {
        guard let client, !isActivating else { return }
        isActivating = true
        defer { isActivating = false }
        do {
            let deviceID = try credentialStore.loadOrCreateDeviceID()
            guard let receipt = try credentialStore.loadReceipt() else {
                licenseState = .inactive
                connectionAccess = .activationRequired
                licenseMessage = nil
                return
            }
            let result = try await client.refreshLicense(
                signedReceipt: receipt,
                deviceID: deviceID,
                appVersion: appVersion,
                appBuild: appBuild
            )
            try credentialStore.saveReceipt(result.signedReceipt)
            apply(result.entitlement)
        } catch {
            // Keep a previously verified, unexpired receipt authorized across
            // transient refresh failures. Without one, fail closed.
            if connectionAccess.permitsNewConnection {
                licenseMessage = Self.safeMessage(error)
            } else {
                licenseState = .failure(Self.safeMessage(error))
                connectionAccess = Self.connectionAccess(for: error)
            }
        }
    }

    func deactivate() async {
        guard let client, !isActivating else { return }
        isActivating = true
        defer { isActivating = false }
        do {
            let deviceID = try credentialStore.loadOrCreateDeviceID()
            guard let receipt = try credentialStore.loadReceipt() else {
                licenseState = .inactive
                connectionAccess = .activationRequired
                licenseMessage = nil
                return
            }
            try await client.deactivateLicense(
                signedReceipt: receipt,
                deviceID: deviceID,
                appVersion: appVersion,
                appBuild: appBuild
            )
            try credentialStore.deleteReceipt()
            licenseState = .inactive
            connectionAccess = .activationRequired
            licenseMessage = nil
        } catch {
            // Deactivation is confirmed only by the service. Keep the local
            // signed receipt and its access decision when the request fails.
            licenseMessage = Self.safeMessage(error)
        }
    }

    func checkForUpdates() async {
        guard let client, !isCheckingForUpdates else { return }
        guard let currentBuild = Int(appBuild), currentBuild > 0 else {
            updateState = .failure(
                AppLocalization.string("The current build number is invalid.")
            )
            return
        }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        do {
            switch try await client.checkForUpdates(currentBuild: currentBuild) {
            case let .current(checkedAt):
                updateState = .current(checkedAt)
            case let .available(manifest):
                updateState = .available(manifest)
            }
        } catch {
            updateState = .failure(Self.safeMessage(error))
        }
    }

    func downloadUpdate(
        _ manifest: SoftwareUpdateManifest,
        to destinationURL: URL
    ) async -> URL? {
        guard !isDownloadingUpdate,
              case let .available(availableManifest) = updateState,
              availableManifest == manifest else {
            return nil
        }
        isDownloadingUpdate = true
        updateDownloadMessage = nil
        updateDownloadSucceeded = false
        defer { isDownloadingUpdate = false }
        do {
            let artifact = try await VerifiedSoftwareUpdateDownloader.live()
                .download(manifest: manifest, to: destinationURL)
            updateDownloadMessage = String.localizedStringWithFormat(
                AppLocalization.string("Downloaded and verified %lld bytes."),
                artifact.byteCount
            )
            updateDownloadSucceeded = true
            return artifact.fileURL
        } catch {
            updateDownloadMessage = Self.safeMessage(error)
            updateDownloadSucceeded = false
            return nil
        }
    }

    private static func policy(
        bundle: Bundle
    ) throws -> IndependentDistributionPolicy {
        func value(_ key: String) -> String? {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String
            else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  !value.contains("$("),
                  !value.contains("${") else { return nil }
            return value
        }

        return try IndependentDistributionPolicy(
            mode: value("AetherRouteDistributionMode"),
            releaseChannel: value("AetherRouteReleaseChannel") ?? "stable",
            productID: value("AetherRouteDistributionProductIdentifier"),
            licenseServiceURL: value("AetherRouteLicenseServiceURL"),
            updateManifestURL: value("AetherRouteUpdateManifestURL"),
            signingPublicKeyBase64: value("AetherRouteDistributionSigningPublicKey")
        )
    }

    private func apply(_ entitlement: LicenseEntitlement) {
        licenseMessage = nil
        if entitlement.state == .active {
            licenseState = .active(entitlement)
            connectionAccess = .authorized
        } else {
            licenseState = .restricted(entitlement)
            connectionAccess = .restricted(entitlement.state)
        }
    }

    private static func connectionAccess(
        for error: Error
    ) -> DistributionConnectionAccess {
        guard let error = error as? IndependentDistributionError else {
            return .verificationUnavailable
        }
        switch error {
        case .expiredEntitlement:
            return .restricted(.expired)
        case .invalidLicenseKey, .httpStatus:
            return .activationRequired
        default:
            return .verificationUnavailable
        }
    }

    private static func safeMessage(_ error: Error) -> String {
        if let error = error as? IndependentDistributionError {
            switch error {
            case .invalidProductID:
                return AppLocalization.string("The distribution product identifier is invalid.")
            case .invalidServiceURL:
                return AppLocalization.string("License and update services must use credential-free HTTPS URLs.")
            case .invalidPublicKey:
                return AppLocalization.string("The distribution signing public key is invalid.")
            case .invalidEnvelope, .invalidPayload:
                return AppLocalization.string("The service returned an invalid signed response.")
            case .invalidSignature:
                return AppLocalization.string("The service response signature could not be verified.")
            case .invalidEntitlement:
                return AppLocalization.string("The license does not match this product or Mac.")
            case .expiredEntitlement:
                return AppLocalization.string("The license has expired.")
            case .invalidUpdateManifest:
                return AppLocalization.string("The signed update manifest is invalid.")
            case .invalidUpdateArtifact:
                return AppLocalization.string("The downloaded update is not a valid file.")
            case .invalidUpdateDestination:
                return AppLocalization.string("Choose a valid DMG destination.")
            case let .updateArtifactTooLarge(bytes):
                return String.localizedStringWithFormat(
                    AppLocalization.string("The downloaded update is too large (%lld bytes)."),
                    bytes
                )
            case .updateArtifactHashMismatch:
                return AppLocalization.string("The downloaded update failed its integrity check.")
            case .invalidLicenseKey:
                return AppLocalization.string("Enter a valid license key without spaces.")
            case .invalidClientIdentity:
                return AppLocalization.string("The local licensing identity is invalid.")
            case .invalidCurrentBuild:
                return AppLocalization.string("The current build number is invalid.")
            case .invalidHTTPResponse:
                return AppLocalization.string("The distribution service returned an invalid response.")
            case .redirectRejected:
                return AppLocalization.string("The distribution service attempted an unexpected redirect.")
            case let .responseTooLarge(bytes):
                return String.localizedStringWithFormat(
                    AppLocalization.string("The distribution response is too large (%lld bytes)."),
                    Int64(bytes)
                )
            case let .httpStatus(status):
                return String.localizedStringWithFormat(
                    AppLocalization.string("The distribution service returned HTTP %lld."),
                    Int64(status)
                )
            case let .keychain(status):
                return String.localizedStringWithFormat(
                    AppLocalization.string("License data could not be accessed in Keychain (Security status %lld)."),
                    Int64(status)
                )
            }
        }
        if let error = error as? LocalizedError,
           let description = error.errorDescription,
           !description.isEmpty {
            return description
        }
        return AppLocalization.string("The distribution service is unavailable.")
    }
}
