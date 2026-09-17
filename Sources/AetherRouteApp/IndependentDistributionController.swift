import AetherRouteKit
import Foundation
import Combine

@MainActor
final class IndependentDistributionController: ObservableObject {
    enum LicenseState: Equatable {
        case notConfigured
        case inactive
        case active(LicenseEntitlement)
        case restricted(LicenseEntitlement)
        case failure(String)
    }

    @Published private(set) var licenseState: LicenseState = .notConfigured
    @Published private(set) var connectionAccess:
        DistributionConnectionAccess = .verificationUnavailable
    private(set) var distributionMode: IndependentDistributionMode = .licensed
    @Published private(set) var licenseMessage: String?
    @Published private(set) var isActivating = false

    private let client: IndependentDistributionClient?
    private let credentialStore: any DistributionCredentialStoring
    private let appVersion: String
    private let appBuild: String
    private var hasLoaded = false
    private var expiryTask: Task<Void, Never>?
    private var verifiedReceipt: LicenseEntitlement?
    private var now: () -> Date = { Date() }

    init(
        client: IndependentDistributionClient,
        credentialStore: any DistributionCredentialStoring,
        now: @escaping () -> Date = { Date() }
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.appVersion = "1"
        self.appBuild = "1"
        self.now = now
        licenseState = .inactive
        connectionAccess = .activationRequired
    }

    deinit { expiryTask?.cancel() }

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
        } catch {
            client = nil
            let message = Self.safeMessage(error)
            licenseState = .failure(message)
            connectionAccess = .verificationUnavailable
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
                verifiedReceipt = nil
                expiryTask?.cancel()
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
            // A verified restriction takes effect even if Keychain persistence fails.
            if result.entitlement.state != .active { apply(result.entitlement) }
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
                verifiedReceipt = nil
                expiryTask?.cancel()
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
            // A verified restriction takes effect even if Keychain persistence fails.
            if result.entitlement.state != .active { apply(result.entitlement) }
            try credentialStore.saveReceipt(result.signedReceipt)
            apply(result.entitlement)
        } catch {
            // Keep a previously verified, unexpired receipt authorized across
            // transient refresh failures. Without one, fail closed.
            revalidateLicense()
            if connectionAccess.permitsNewConnection, Self.isTransientRefreshFailure(error) {
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
                verifiedReceipt = nil
                expiryTask?.cancel()
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
            verifiedReceipt = nil
            expiryTask?.cancel()
            licenseState = .inactive
            connectionAccess = .activationRequired
            licenseMessage = nil
        } catch {
            // Deactivation is confirmed only by the service. Keep the local
            // signed receipt and its access decision when the request fails.
            licenseMessage = Self.safeMessage(error)
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
        expiryTask?.cancel()
        expiryTask = nil
        licenseMessage = nil
        verifiedReceipt = entitlement
        if entitlement.state == .active {
            licenseState = .active(entitlement)
            connectionAccess = entitlement.expiresAt.map { .authorizedUntil($0) } ?? .authorized
            revalidateLicense()
            if let expiry = entitlement.expiresAt, expiry > now() {
                expiryTask = Task { [weak self] in
                    // Recheck wall time after wake and after clock changes.
                    // Connection admission also checks expiry synchronously.
                    while !Task.isCancelled {
                        guard let currentDate = self?.now() else { return }
                        let remaining = expiry.timeIntervalSince(currentDate)
                        if remaining <= 0 { self?.revalidateLicense(); return }
                        do { try await Task.sleep(for: .seconds(min(remaining, 30))) }
                        catch { return }
                    }
                }
            }
        } else {
            licenseState = .restricted(entitlement)
            connectionAccess = .restricted(entitlement.state)
        }
    }

    func revalidateLicense() {
        guard let entitlement = verifiedReceipt, entitlement.state == .active,
              let expiry = entitlement.expiresAt, expiry <= now() else { return }
        licenseState = .restricted(LicenseEntitlement(
            schemaVersion: entitlement.schemaVersion,
            productID: entitlement.productID, licenseID: entitlement.licenseID,
            deviceID: entitlement.deviceID, state: .expired,
            issuedAt: entitlement.issuedAt, expiresAt: entitlement.expiresAt
        ))
        connectionAccess = .restricted(.expired)
    }

    private static func isTransientRefreshFailure(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .notConnectedToInternet, .networkConnectionLost,
                    .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
        }
        if case let .httpStatus(status) = error as? IndependentDistributionError {
            return status == 429 || (500...599).contains(status)
        }
        return false
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
