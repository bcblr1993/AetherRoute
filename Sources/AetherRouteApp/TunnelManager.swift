import AetherRouteKit
import Foundation
import NetworkExtension
import OSLog

enum NetworkEngineMode: String, CaseIterable, Identifiable, Sendable {
    case transparent
#if AETHERROUTE_INDEPENDENT
    case tun
#endif

    var id: Self { self }

    var localizedTitle: String {
        switch self {
        case .transparent: AppLocalization.string("Transparent Proxy")
#if AETHERROUTE_INDEPENDENT
        case .tun: AppLocalization.string("TUN")
#endif
        }
    }

    var localizedDetail: String {
        switch self {
        case .transparent:
            AppLocalization.string("Routes supported app traffic as TCP and UDP flows")
#if AETHERROUTE_INDEPENDENT
        case .tun:
            AppLocalization.string("Routes IPv4 and IPv6 packets through Packet Tunnel")
#endif
        }
    }

    var localizedCompactDetail: String {
        switch self {
        case .transparent: AppLocalization.string("TCP + UDP flows")
#if AETHERROUTE_INDEPENDENT
        case .tun: AppLocalization.string("IPv4 + IPv6 packets")
#endif
        }
    }

    var providerBundleIdentifier: String {
        switch self {
        case .transparent: AppConstants.transparentProxyBundleIdentifier
#if AETHERROUTE_INDEPENDENT
        case .tun: AppConstants.tunnelBundleIdentifier
#endif
        }
    }

    var serverAddress: String {
        switch self {
        case .transparent: "Local transparent proxy"
#if AETHERROUTE_INDEPENDENT
        case .tun: "Local packet tunnel"
#endif
        }
    }

    init?(providerBundleIdentifier: String?) {
        guard let providerBundleIdentifier else { return nil }
        switch providerBundleIdentifier {
        case AppConstants.transparentProxyBundleIdentifier:
            self = .transparent
#if AETHERROUTE_INDEPENDENT
        case AppConstants.tunnelBundleIdentifier:
            self = .tun
#endif
        default:
            return nil
        }
    }
}

private struct ProfileCatalogProjection: Sendable {
    let catalog: ProfileCatalog
    let summary: ProfileConfigurationSummary?
    let dnsPolicy: DNSRuntimePolicy
    let dnsErrorDescription: String?
}

private enum ProfileCatalogProjectionBuilder {
    static func production(
        _ catalog: ProfileCatalog
    ) -> ProfileCatalogProjection {
        let active = catalog.activeProfile?.profile
        let summary = active.map {
            ProfileConfigurationInspector.inspect(yaml: $0.yaml)
        }
        guard let active else {
            return ProfileCatalogProjection(
                catalog: catalog,
                summary: summary,
                dnsPolicy: .inherited,
                dnsErrorDescription: nil
            )
        }
        do {
            let compatibilityDefault = summary.map {
                DNSRuntimePolicy.packetTunnelCompatibilityDefault(
                    for: $0.dns
                )
            } ?? .inherited
            return ProfileCatalogProjection(
                catalog: catalog,
                summary: summary,
                dnsPolicy: try DNSRuntimePolicyStore.applicationGroup()
                    .loadIfPresent(forProfileYAML: active.yaml)
                    ?? compatibilityDefault,
                dnsErrorDescription: nil
            )
        } catch {
            return ProfileCatalogProjection(
                catalog: catalog,
                summary: summary,
                dnsPolicy: .inherited,
                dnsErrorDescription: error.localizedDescription
            )
        }
    }

    static func review(
        _ catalog: ProfileCatalog
    ) -> ProfileCatalogProjection {
        ProfileCatalogProjection(
            catalog: catalog,
            summary: catalog.activeProfile.map {
                ProfileConfigurationInspector.inspect(yaml: $0.profile.yaml)
            },
            dnsPolicy: DNSRuntimePolicy(
                resolutionMode: .fakeIP,
                ipv6: .disabled,
                respectsRules: .enabled
            ),
            dnsErrorDescription: nil
        )
    }
}

private struct ProductionStartupState: Sendable {
    let bypassPolicy: BypassPolicy?
    let profileProjection: ProfileCatalogProjection
}

private struct LocalizedConnectionError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private enum ProductionStartupLoader {
    static func load(shouldLoadBypassPolicy: Bool) throws
        -> ProductionStartupState
    {
        let bypassPolicy = shouldLoadBypassPolicy
            ? try BypassPolicyStore.applicationGroup().load()
            : nil
        let catalog = try ProfileCatalogStore.applicationGroup().loadOrMigrate()
        return ProductionStartupState(
            bypassPolicy: bypassPolicy,
            profileProjection: ProfileCatalogProjectionBuilder.production(catalog)
        )
    }
}

@MainActor
final class TunnelManager: ObservableObject {
    private static let runtimeLogger = Logger(
        subsystem: "com.aetherroute.desktop",
        category: "host-lifecycle"
    )

    enum State: Equatable {
        case privacyConsentRequired
        case loading
        case disconnected
        case connecting
        case connected
        case disconnecting
        case failed(String)
    }

    @Published private(set) var state: State = .loading {
        didSet {
            if case .failed = state {
                // Retain the context installed immediately before the state.
            } else {
                failureContext = nil
            }
            let previous = Self.diagnosticEventCode(for: oldValue)
            let current = Self.diagnosticEventCode(for: state)
            guard previous != current else { return }
            Self.runtimeLogger.info(
                "stage=stateTransition from=\(previous.rawValue, privacy: .public) to=\(current.rawValue, privacy: .public)"
            )
            diagnosticEvents.record(current)
        }
    }
    @Published private(set) var distributionConnectionAccess:
        DistributionConnectionAccess = .unrestrictedDevelopment
    @Published private(set) var profiles: [ManagedProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var activeProfile: ActiveProfile?
    @Published private(set) var activeProfileSummary: ProfileConfigurationSummary?
    @Published private(set) var profileMessage: String?
    @Published private(set) var profileMessageIsError = false
    @Published private(set) var pendingExternalSubscription:
        ExternalSubscriptionImportRequest?
    @Published private(set) var externalSubscriptionLinkError: String?
    @Published private(set) var bypassPolicy: BypassPolicy = .empty
    @Published private(set) var bypassPolicyMessage: String?
    @Published private(set) var bypassPolicyMessageIsError = false
    @Published private(set) var dnsRuntimePolicy: DNSRuntimePolicy = .inherited
    @Published private(set) var dnsRuntimePolicyMessage: String?
    @Published private(set) var dnsRuntimePolicyMessageIsError = false
    @Published private(set) var isRefreshingSubscription = false
    @Published private(set) var isImportingProfile = false
    @Published private(set) var isUpdatingProfiles = false
    @Published private(set) var isUpdatingBypassPolicy = false
    @Published private(set) var isUpdatingDNSRuntimePolicy = false
    @Published private(set) var isTransferringProfiles = false
    @Published private(set) var routingResourceStatuses:
        [RoutingResourceKind: RoutingResourceStatus] = [:]
    @Published private(set) var isUpdatingRoutingResources = false
    @Published private(set) var routingResourceMessage: String?
    @Published private(set) var routingResourceMessageIsError = false
    @Published private(set) var hasAcceptedPrivacyDisclosure: Bool
    @Published private(set) var connectedSince: Date?
    @Published private(set) var sessionRoutingMode: RoutingMode?
    @Published private(set) var sessionNetworkEngineMode: NetworkEngineMode?
    @Published private(set) var networkEngineMode: NetworkEngineMode
    @Published private(set) var systemExtensionApprovalRequired = false
    @Published private(set) var proxySelections: [String: ProxySelectionState] = [:]
    @Published private(set) var proxySelectionMessages: [String: String] = [:]
    @Published private(set) var proxySelectionRequests: Set<String> = []
    @Published private(set) var proxyLatencies: [String: ProxyLatencyState] = [:]
    @Published private(set) var proxyLatencyRequests: Set<String> = []
    @Published private(set) var isVerifyingProxyReadiness = false
    @Published private(set) var connectionStage: ConnectionStage = .systemAuthorization
    @Published private(set) var telemetry: NetworkTelemetrySnapshot = .empty
    @Published private(set) var telemetryUpdatedAt: Date?
    @Published private(set) var localProxySettings: LocalProxySettings
    @Published private(set) var localProxySettingsMessage: String? = nil
    @Published var routingMode: RoutingMode {
        didSet {
            guard persistsRoutingModeSelection else { return }
            routingModePreferenceStore.save(routingMode)
        }
    }

    private let isUIReviewMode: Bool
    private let privacyConsentStore: PrivacyConsentStore
    private let routingModePreferenceStore: RoutingModePreferenceStore
    private let localProxySettingsStore: LocalProxySettingsStore
    private let userDefaults: UserDefaults
    private let subscriptionClient: ProfileSubscriptionClient
    private let routingResourceDownloadClient: RoutingResourceDownloadClient
    private let systemExtensionActivator: any SystemExtensionActivating
    private let routingResourceStoreFactory:
        @Sendable () throws -> RoutingResourceStore
    private let diagnosticEvents = DiagnosticEventBuffer()
    private var manager: NEVPNManager?
    private var statusObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?
    private var isPreparing = false
    private var isPersistingConfiguration = false
    private var isReloadingConfiguration = false
    private var persistsRoutingModeSelection = false
    private var hasLoadedBypassPolicy = false
    private var telemetryPollingTask: Task<Void, Never>?
    private var profileImportTask: Task<Void, Never>?
    private var routingResourceStatusTask: Task<Void, Never>?
    private var connectionWatchdogTask: Task<Void, Never>?
    private var disconnectionWatchdogTask: Task<Void, Never>?
    private var connectionReadinessTask: Task<Void, Never>?
    private var connectionRequestID: UUID?
    private var connectionAttemptID: UUID?
    private var disconnectionAttemptID: UUID?
    private var providerConnectionID: UUID?
    private var readinessVerifiedConnectionID: UUID?
    private var lastObservedProviderStatus: NEVPNStatus?
    private var disconnectErrorLookupID: UUID?
    private var failureContext: ConnectionFailureContext?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        privacyConsentStore: PrivacyConsentStore = PrivacyConsentStore(),
        routingModePreferenceStore: RoutingModePreferenceStore =
            RoutingModePreferenceStore(),
        userDefaults: UserDefaults = .standard,
        subscriptionClient: ProfileSubscriptionClient = .live(),
        routingResourceDownloadClient: RoutingResourceDownloadClient = .live(),
        systemExtensionActivator: any SystemExtensionActivating =
            SystemExtensionActivationCoordinator(),
        routingResourceStoreFactory:
            @escaping @Sendable () throws -> RoutingResourceStore = {
                try RoutingResourceStore.applicationGroup()
            }
    ) {
        self.privacyConsentStore = privacyConsentStore
        self.routingModePreferenceStore = routingModePreferenceStore
        self.userDefaults = userDefaults
        self.subscriptionClient = subscriptionClient
        self.routingResourceDownloadClient = routingResourceDownloadClient
        self.systemExtensionActivator = systemExtensionActivator
        self.routingResourceStoreFactory = routingResourceStoreFactory
        localProxySettingsStore = LocalProxySettingsStore(defaults: userDefaults)
        localProxySettings = localProxySettingsStore.load()

        var initialNetworkEngine: NetworkEngineMode = .transparent
#if AETHERROUTE_INDEPENDENT
        if let saved = userDefaults.string(forKey: Self.networkEnginePreferenceKey),
           let mode = NetworkEngineMode(rawValue: saved) {
            initialNetworkEngine = mode
        }
#endif
#if DEBUG || AETHERROUTE_PERFORMANCE_MEASUREMENT || AETHERROUTE_UI_RESPONSIVENESS || AETHERROUTE_DEVELOPMENT_PREVIEW
        let reviewState: String?
        let startsWithEmptyReviewProfile: Bool
#if AETHERROUTE_DEVELOPMENT_PREVIEW
        reviewState = environment["AETHERROUTE_UI_REVIEW"] ?? "disconnected"
        startsWithEmptyReviewProfile =
            environment["AETHERROUTE_UI_REVIEW"] == nil
#elseif AETHERROUTE_PERFORMANCE_MEASUREMENT
        startsWithEmptyReviewProfile = false
        if environment["AETHERROUTE_PERFORMANCE_MEASUREMENT"] == "1" {
            reviewState = "disconnected"
        } else {
            reviewState = environment["AETHERROUTE_UI_REVIEW"]
        }
#else
        reviewState = environment["AETHERROUTE_UI_REVIEW"]
        startsWithEmptyReviewProfile = false
#endif
        if reviewState != nil,
           let requestedEngine = environment["AETHERROUTE_UI_REVIEW_ENGINE"],
           let mode = NetworkEngineMode(rawValue: requestedEngine) {
            initialNetworkEngine = mode
        }
        networkEngineMode = initialNetworkEngine
        isUIReviewMode = reviewState != nil
        routingMode = reviewState == nil
            ? routingModePreferenceStore.load()
            : .rule
        persistsRoutingModeSelection = reviewState == nil
        if let reviewState {
            hasAcceptedPrivacyDisclosure =
                environment["AETHERROUTE_UI_REVIEW_PRIVACY"] != "pending"
            guard hasAcceptedPrivacyDisclosure else {
                state = .privacyConsentRequired
                return
            }
            installReviewBypassPolicy()
            if startsWithEmptyReviewProfile
                || environment["AETHERROUTE_UI_REVIEW_PROFILE"] == "none" {
                state = .disconnected
                connectedSince = nil
                return
            }

            let reviewSubscription: ProfileSubscription?
            if environment["AETHERROUTE_UI_REVIEW_SUBSCRIPTION"] == "1",
               let url = URL(string: "https://profiles.example/config.yaml") {
                reviewSubscription = try? ProfileSubscription(
                    url: url,
                    etag: "\"review-7\"",
                    lastCheckedAt: Date(timeIntervalSince1970: 1_775_003_300),
                    lastUpdatedAt: Date(timeIntervalSince1970: 1_775_000_000)
                )
            } else {
                reviewSubscription = nil
            }

            let profile = ActiveProfile(
                name: "Balanced · Singapore",
                yaml: """
                dns:
                  enable: true
                  ipv6: true
                  use-hosts: true
                  respect-rules: true
                  enhanced-mode: fake-ip
                  fake-ip-range: 198.18.0.1/16
                  fake-ip-filter: ['*.lan', localhost]
                  nameserver:
                    - https://1.1.1.1/dns-query
                    - tls://9.9.9.9:853
                  fallback: [tcp://8.8.8.8:53]
                  default-nameserver: [1.0.0.1]
                  proxy-server-nameserver: [9.9.9.9]
                  nameserver-policy:
                    '+.internal.example': 192.0.2.53
                  fallback-filter:
                    geoip: true
                proxies:
                  - {name: Singapore Edge, type: vmess}
                  - {name: Tokyo Direct, type: direct}
                proxy-groups:
                  - {name: Balanced, type: select, proxies: [Singapore Edge, Tokyo Direct]}
                rules:
                  - GEOSITE,github,Balanced
                  - GEOIP,CN,DIRECT,no-resolve
                  - DOMAIN-SUFFIX,example.com,Balanced
                  - MATCH,DIRECT
                """,
                importedAt: Date(timeIntervalSince1970: 1_775_000_000),
                subscription: reviewSubscription
            )
            let managed = ManagedProfile(profile: profile)
            let fallback = ManagedProfile(
                profile: ActiveProfile(
                    name: "Tokyo · Low Latency",
                    yaml: "proxies:\n  - {name: Tokyo Edge, type: trojan}\n",
                    importedAt: Date(timeIntervalSince1970: 1_774_900_000)
                )
            )
            let office = ManagedProfile(
                profile: ActiveProfile(
                    name: "Office · Automatic",
                    yaml: "proxies:\n  - {name: Office Edge, type: vless}\n",
                    importedAt: Date(timeIntervalSince1970: 1_774_800_000)
                )
            )
            installReviewProfileCatalog(
                ProfileCatalog(
                    activeProfileID: managed.id,
                    profiles: [managed, fallback, office]
                )
            )
            if reviewState == "failed" || reviewState == "error" {
                failureContext = .provider
            }
            if reviewState == "extension-approval" {
                systemExtensionApprovalRequired = true
                failureContext = .configuration
            }
            state = switch reviewState {
            case "loading": .loading
            case "connecting": .connecting
            case "connected": .connected
            case "disconnecting": .disconnecting
            case "failed", "error":
                .failed(
                    AppLocalization.string("The secure connection could not start. Review the profile and try again.")
                )
            case "extension-approval":
                .failed(
                    AppLocalization.string(
                        "Approve the AetherRoute network extension to continue."
                    )
                )
            default: .disconnected
            }
            connectedSince = state == .connected
                ? Date(timeIntervalSince1970: 1_775_003_600)
                : nil
            sessionRoutingMode = state == .connected ? routingMode : nil
            if state == .connected {
                proxySelections["Balanced"] = ProxySelectionState(
                    selectedMember: "Singapore Edge",
                    members: ["Singapore Edge", "Tokyo Direct"]
                )
                proxyLatencies["Balanced"] = ProxyLatencyState(
                    results: [
                        ProxyLatencyResult(
                            member: "Singapore Edge",
                            delayMilliseconds: 24
                        ),
                        ProxyLatencyResult(
                            member: "Tokyo Direct",
                            delayMilliseconds: 57
                        ),
                    ]
                )
                installReviewTelemetry()
            }
            return
        }
#else
        networkEngineMode = initialNetworkEngine
        isUIReviewMode = false
        routingMode = routingModePreferenceStore.load()
        persistsRoutingModeSelection = true
#endif

        hasAcceptedPrivacyDisclosure =
            privacyConsentStore.hasAcceptedCurrentDisclosure
        state = hasAcceptedPrivacyDisclosure ? .loading : .privacyConsentRequired
    }

    func acceptPrivacyDisclosure() async {
        if !isUIReviewMode {
            privacyConsentStore.acceptCurrentDisclosure()
        }
        hasAcceptedPrivacyDisclosure = true
        state = .loading
        await prepare()
    }

    func prepare() async {
        guard ensurePrivacyConsent() else { return }
        guard !isUIReviewMode else { return }
        guard !rejectDevelopmentPreviewStart() else { return }
        guard manager == nil, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        do {
            let shouldLoadBypassPolicy = !hasLoadedBypassPolicy
            let startup = try await Task.detached(priority: .userInitiated) {
                try ProductionStartupLoader.load(
                    shouldLoadBypassPolicy: shouldLoadBypassPolicy
                )
            }.value
            if let loadedBypassPolicy = startup.bypassPolicy {
                bypassPolicy = loadedBypassPolicy
                hasLoadedBypassPolicy = true
            }
            installProfileProjection(startup.profileProjection)
            try await systemExtensionActivator.activate(
                identifier: networkEngineMode.providerBundleIdentifier
            ) { [weak self] in
                guard let self else { return }
                failureContext = .configuration
                systemExtensionApprovalRequired = true
                state = .failed(
                    AppLocalization.string(
                        "Approve the AetherRoute network extension to continue."
                    )
                )
            }
            systemExtensionApprovalRequired = false
            installManager(try await loadOrCreateManager())
            observeConfigurationChanges()
            updateState()
            if state == .disconnected {
                await refreshSubscriptionIfDue()
            }
        } catch {
            systemExtensionApprovalRequired = false
            recordFailure(error, context: .configuration)
        }
    }

    /// Re-runs preparation after the user returns from System Settings. When
    /// the original activation request is still pending, `prepare()` safely
    /// coalesces this call through `isPreparing`; macOS will complete that
    /// request as soon as approval is granted.
    func recheckSystemExtensionApproval() async {
        guard systemExtensionApprovalRequired else { return }
        await prepare()
    }

    private func rejectDevelopmentPreviewStart() -> Bool {
#if DEBUG || AETHERROUTE_DEVELOPMENT_PREVIEW
        failureContext = .configuration
        state = .failed(
            AppLocalization.string(
                "This preview can import and inspect profiles, but it cannot enable system routing."
            )
        )
        return true
#else
        return false
#endif
    }

    func setEnabled(_ enabled: Bool) async {
        Self.runtimeLogger.info(
            "stage=setEnabled request=\(enabled ? "connect" : "disconnect", privacy: .public) state=\(Self.diagnosticEventCode(for: self.state).rawValue, privacy: .public) engine=\(self.networkEngineMode.rawValue, privacy: .public) routing=\(self.routingMode.rawValue, privacy: .public)"
        )
        if !enabled {
            // Invalidate before any guard or await. A connect request may still
            // be preparing resources even though NetworkExtension has not
            // received startVPNTunnel yet.
            invalidateConnectionRequest()
        }
        guard ensurePrivacyConsent() else { return }
        guard !enabled || distributionConnectionAccess.permitsNewConnection
        else { return }
        if isUIReviewMode {
            state = enabled ? .connected : .disconnected
            connectedSince = enabled ? .now : nil
            sessionRoutingMode = enabled ? routingMode : nil
            if enabled {
                installReviewTelemetry()
            } else {
                clearProxySelectionRuntimeState()
            }
            return
        }

        var requestID: UUID?
        if enabled {
            guard TunnelLifecycleTransitionPolicy.canBeginConnection(
                hostIsTransitioning: isTransitioning,
                providerPermitsStart: managerConnectionPermitsStart
            ) else {
                Self.runtimeLogger.info(
                    "stage=setEnabled ignored reason=hostOrProviderTransitioning"
                )
                return
            }
            disconnectErrorLookupID = nil
            cancelDisconnectionWatchdog()
            let newRequestID = beginConnectionRequest()
            requestID = newRequestID
            if manager == nil {
                Self.runtimeLogger.info(
                    "stage=setEnabled prepareRequired reason=managerMissing"
                )
                state = .loading
                await prepare()
                guard isCurrentConnectionRequest(newRequestID) else {
                    Self.runtimeLogger.info(
                        "stage=setEnabled stopped reason=staleAfterPrepare"
                    )
                    return
                }
                guard manager != nil else {
                    Self.runtimeLogger.info(
                        "stage=setEnabled deferred reason=managerUnavailable"
                    )
                    completeConnectionRequest(newRequestID)
                    return
                }
                guard TunnelLifecycleTransitionPolicy.canBeginConnection(
                    hostIsTransitioning: isTransitioning,
                    providerPermitsStart: managerConnectionPermitsStart
                ) else {
                    Self.runtimeLogger.info(
                        "stage=setEnabled stopped reason=transitioningAfterPrepare"
                    )
                    completeConnectionRequest(newRequestID)
                    return
                }
            }
            resetConnectionReadiness()
            connectionStage = .systemAuthorization
            state = .connecting
        } else {
            disconnectErrorLookupID = nil
            cancelConnectionWatchdog()
            cancelConnectionReadiness()
            guard state == .connected || state == .connecting else {
                Self.runtimeLogger.info("stage=setEnabled ignored reason=notActive")
                return
            }
            state = .disconnecting
            beginDisconnectionWatchdog()
        }
        let requestedMode = routingMode
        var launchSnapshot: ProviderLaunchSnapshot?

        do {
            if enabled, activeProfile == nil {
                throw ActiveProfileStoreError.noActiveProfile
            }
            if enabled, let activeProfile {
                Self.runtimeLogger.info("stage=prepareRuntimeResources begin")
                let profileYAML = activeProfile.yaml
                let storeFactory = routingResourceStoreFactory
                let downloadClient = routingResourceDownloadClient
                let launchInput = try await Task.detached(
                    priority: .userInitiated
                ) {
                    let store = try storeFactory()
                    let installedResources = try await downloadClient
                        .ensureRequiredResources(
                            for: profileYAML,
                            in: store
                        )
                    try store.prepareRuntimeResources(for: profileYAML)
                    let persistedSelections = try ProxySelectionStore
                        .applicationGroup()
                        .selections(forProfileYAML: profileYAML)
                    let initialSelections = InitialProxySelectionPolicy
                        .selections(
                            persisted: persistedSelections,
                            summary: ProfileConfigurationInspector.inspect(
                                yaml: profileYAML
                            )
                        )
                    return (
                        initialSelections,
                        try store.launchResourceSnapshot(
                            for: profileYAML
                        ),
                        installedResources
                    )
                }.value
                guard let requestID,
                      shouldContinueConnectionPreparation(requestID) else {
                    Self.runtimeLogger.info(
                        "stage=setEnabled stopped reason=staleAfterRuntimeResources"
                    )
                    return
                }
                if !launchInput.2.isEmpty {
                    routingResourceMessage = AppLocalization.string(
                        "Routing resources were downloaded and verified."
                    )
                    routingResourceMessageIsError = false
                    refreshRoutingResourceStatuses()
                }
                launchSnapshot = try ProviderLaunchSnapshot(
                    profileYAML: profileYAML,
                    routingMode: requestedMode,
                    bypassPolicy: bypassPolicy,
                    dnsPolicy: dnsRuntimePolicy,
                    proxySelections: launchInput.0,
                    routingResources: launchInput.1
                )
                Self.runtimeLogger.info("stage=prepareRuntimeResources success")
            }
            Self.runtimeLogger.info("stage=requireManager begin")
            let manager = try await requireManager()
            if enabled {
                guard let requestID,
                      shouldContinueConnectionPreparation(requestID) else {
                    Self.runtimeLogger.info(
                        "stage=setEnabled stopped reason=staleAfterRequireManager"
                    )
                    return
                }
            }
            Self.runtimeLogger.info("stage=requireManager success")
            if enabled {
                Self.runtimeLogger.info("stage=persistProviderConfiguration begin")
                try await persistProviderConfiguration(
                    requestedMode,
                    localProxy: providerLocalProxySettings,
                    in: manager
                )
                guard let requestID,
                      shouldContinueConnectionPreparation(requestID) else {
                    Self.runtimeLogger.info(
                        "stage=setEnabled stopped reason=staleAfterPersistConfiguration"
                    )
                    return
                }
                Self.runtimeLogger.info("stage=persistProviderConfiguration success")
                beginConnectionWatchdog()
                Self.runtimeLogger.info("stage=startVPNTunnel begin")
                guard let launchSnapshot,
                      let session = manager.connection
                        as? NETunnelProviderSession else {
                    throw TunnelManagerError.providerSessionUnavailable
                }
                let options = try ProviderLaunchSnapshotCodec.startOptions(
                    for: launchSnapshot
                )
                Self.runtimeLogger.info(
                    "stage=startVPNTunnel launchSnapshotReady mode=\(launchSnapshot.routingMode.rawValue, privacy: .public) selections=\(launchSnapshot.proxySelections.count, privacy: .public) resources=\(launchSnapshot.routingResources.count, privacy: .public)"
                )
                try session.startVPNTunnel(options: options)
                completeConnectionRequest(requestID)
                Self.runtimeLogger.info("stage=startVPNTunnel submitted")
            } else {
                Self.runtimeLogger.info("stage=stopVPNTunnel begin")
                manager.connection.stopVPNTunnel()
                Self.runtimeLogger.info("stage=stopVPNTunnel submitted")
                // A cancel issued while the provider is still starting may
                // leave NetworkExtension at .invalid/.disconnected without a
                // new status notification. Reconcile synchronously so the UI
                // cannot remain in Disconnecting after the OS already stopped.
                reconcileDisconnectionStatus()
            }
        } catch {
            if enabled, let requestID,
               !shouldContinueConnectionPreparation(requestID) {
                Self.runtimeLogger.info(
                    "stage=setEnabled errorIgnored reason=staleConnectionRequest"
                )
                return
            }
            Self.runtimeLogger.error(
                "stage=setEnabled failed error=\(String(reflecting: error), privacy: .public)"
            )
            cancelConnectionWatchdog()
            cancelDisconnectionWatchdog()
            invalidateCachedManager()
            let context: ConnectionFailureContext
            if (error as? ActiveProfileStoreError) == .noActiveProfile {
                context = .missingProfile
            } else if error is RoutingResourceError {
                context = .configuration
            } else {
                context = .provider
            }
            recordFailure(
                localizedConnectionError(error),
                context: context
            )
        }
    }

    var requiredRoutingResources: [RoutingResourceKind] {
        guard let summary = activeProfileSummary else { return [] }
        return RoutingResourceKind.allCases.filter {
            summary.requiredRoutingResources.contains($0)
        }
    }

    func refreshRoutingResourceStatuses() {
        routingResourceStatusTask?.cancel()
        let required = requiredRoutingResources
        guard !required.isEmpty else {
            routingResourceStatuses = [:]
            routingResourceMessage = nil
            routingResourceMessageIsError = false
            return
        }
        guard !isUIReviewMode else {
            routingResourceStatuses = Dictionary(
                uniqueKeysWithValues: required.map { ($0, .missing) }
            )
            return
        }
        let storeFactory = routingResourceStoreFactory
        routingResourceStatusTask = Task { [weak self] in
            do {
                let statuses = try await Task.detached(
                    priority: .utility
                ) {
                    let store = try storeFactory()
                    return Dictionary(
                        uniqueKeysWithValues: required.map {
                            ($0, store.status(for: $0))
                        }
                    )
                }.value
                guard !Task.isCancelled else { return }
                self?.routingResourceStatuses = statuses
            } catch {
                guard !Task.isCancelled else { return }
                self?.routingResourceStatuses = Dictionary(
                    uniqueKeysWithValues: required.map {
                        ($0, .invalid(.writeFailed))
                    }
                )
            }
        }
    }

    func downloadRequiredRoutingResources() async {
        guard ensurePrivacyConsent(), canModifyProfiles,
              !isUpdatingRoutingResources else { return }
        guard !isUIReviewMode else {
            routingResourceMessage = AppLocalization.string(
                "Routing resources are not written by the unsigned UI preview."
            )
            routingResourceMessageIsError = true
            return
        }
        let required = requiredRoutingResources
        guard !required.isEmpty else { return }

        isUpdatingRoutingResources = true
        routingResourceMessage = AppLocalization.string(
            "Downloading and verifying routing resources…"
        )
        routingResourceMessageIsError = false
        defer { isUpdatingRoutingResources = false }

        let storeFactory = routingResourceStoreFactory
        let downloadClient = routingResourceDownloadClient
        do {
            try await Task.detached(priority: .userInitiated) {
                let store = try storeFactory()
                for kind in required {
                    let descriptor = try RoutingResourceRemoteDescriptor
                        .maintainedDefault(for: kind)
                    try Task.checkCancellation()
                    try await downloadClient.downloadAndInstall(
                        descriptor,
                        into: store
                    )
                }
            }.value
            routingResourceMessage = AppLocalization.string(
                "Routing resources were downloaded and verified."
            )
            routingResourceMessageIsError = false
        } catch {
            routingResourceMessage = localizedRoutingResourceOperationError(
                error
            )
            routingResourceMessageIsError = true
        }
        refreshRoutingResourceStatuses()
    }

    func importRoutingResource(
        _ kind: RoutingResourceKind,
        from url: URL
    ) async {
        guard ensurePrivacyConsent(), canModifyProfiles,
              !isUpdatingRoutingResources else { return }
        guard !isUIReviewMode else {
            routingResourceMessage = AppLocalization.string(
                "Routing resources are not written by the unsigned UI preview."
            )
            routingResourceMessageIsError = true
            return
        }

        isUpdatingRoutingResources = true
        routingResourceMessage = AppLocalization.string(
            "Importing and verifying routing resource…"
        )
        routingResourceMessageIsError = false
        defer { isUpdatingRoutingResources = false }
        let storeFactory = routingResourceStoreFactory
        do {
            try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                if let size = values.fileSize, size > kind.maximumBytes {
                    throw RoutingResourceError.resourceTooLarge(kind, size)
                }
                let data = try Data(
                    contentsOf: url,
                    options: [.mappedIfSafe]
                )
                try storeFactory().installUserProvided(
                    data: data,
                    kind: kind
                )
            }.value
            routingResourceMessage = String.localizedStringWithFormat(
                AppLocalization.string("%@ was imported and verified."),
                kind.fileName
            )
            routingResourceMessageIsError = false
        } catch {
            routingResourceMessage = localizedRoutingResourceOperationError(
                error
            )
            routingResourceMessageIsError = true
        }
        refreshRoutingResourceStatuses()
    }

    func setDistributionConnectionAccess(
        _ access: DistributionConnectionAccess
    ) {
        guard access != distributionConnectionAccess else { return }
        distributionConnectionAccess = access
        guard !access.permitsNewConnection, isEnabled else { return }
        Task { await setEnabled(false) }
    }

    func setNetworkEngineMode(_ mode: NetworkEngineMode) async {
        guard mode != networkEngineMode, canChangeNetworkEngine else { return }
        invalidateCachedManager()
        networkEngineMode = mode

        if isUIReviewMode {
            state = .disconnected
            return
        }

        userDefaults.set(mode.rawValue, forKey: Self.networkEnginePreferenceKey)
        state = .loading
        await prepare()
    }

    func setLocalProxyEnabled(_ isEnabled: Bool) {
        updateLocalProxySettings { settings in
            settings.isEnabled = isEnabled
        }
    }

    func setLocalProxyHTTPPort(_ port: Int) {
        updateLocalProxySettings { settings in
            settings.httpPort = port
        }
    }

    func setLocalProxySOCKSPort(_ port: Int) {
        updateLocalProxySettings { settings in
            settings.socksPort = port
        }
    }

    func setDNSRuntimePolicy(_ policy: DNSRuntimePolicy) async {
        guard canModifyDNSRuntimePolicy, let activeProfile else { return }
        isUpdatingDNSRuntimePolicy = true
        defer { isUpdatingDNSRuntimePolicy = false }
        do {
            if !isUIReviewMode {
                let profileYAML = activeProfile.yaml
                try await Task.detached(priority: .userInitiated) {
                    try DNSRuntimePolicyStore.applicationGroup().save(
                        policy,
                        forProfileYAML: profileYAML
                    )
                }.value
            }
            dnsRuntimePolicy = policy
            dnsRuntimePolicyMessage = policy.isInherited
                ? AppLocalization.string("DNS behavior now follows the active profile.")
                : AppLocalization.string("DNS overrides will apply on the next TUN connection.")
            dnsRuntimePolicyMessageIsError = false
        } catch {
            dnsRuntimePolicyMessage = error.localizedDescription
            dnsRuntimePolicyMessageIsError = true
        }
    }

    func refreshProxySelection(group groupName: String) async {
        await performProxySelectionRequest(
            group: groupName,
            requestedMember: nil
        )
    }

    func selectProxy(group groupName: String, member: String) async {
        await performProxySelectionRequest(
            group: groupName,
            requestedMember: member
        )
    }

    func testProxyLatency(group groupName: String) async {
        guard state == .connected,
              activeProfileSummary?.proxyGroups.contains(where: {
                  $0.name == groupName
              }) == true,
              !proxyLatencyRequests.contains(groupName) else {
            return
        }
        proxyLatencyRequests.insert(groupName)
        Self.runtimeLogger.info(
            "stage=proxyLatency request members=\(self.activeProfileSummary?.proxyGroups.first(where: { $0.name == groupName })?.memberCount ?? 0, privacy: .public)"
        )
        proxySelectionMessages[groupName] = nil
        defer { proxyLatencyRequests.remove(groupName) }

        do {
            let latency: ProxyLatencyState
            if isUIReviewMode {
                let members = proxySelections[groupName]?.members
                    ?? activeProfileSummary?.proxyGroups
                        .first(where: { $0.name == groupName })?.members
                    ?? []
                latency = ProxyLatencyState(
                    results: members.enumerated().map { index, member in
                        ProxyLatencyResult(
                            member: member,
                            delayMilliseconds: index == 2
                                ? nil
                                : UInt32(24 + index * 31)
                        )
                    }
                )
            } else {
                let client = ProxySelectionProviderClient { [weak self] data in
                    guard let self else {
                        throw TunnelManagerError.providerSessionUnavailable
                    }
                    return try await self.sendProviderMessage(
                        data,
                        timeout: .seconds(25)
                    )
                }
                latency = try await client.latency(
                    group: groupName,
                    url: Self.defaultLatencyTestURL,
                    timeoutMilliseconds: 5_000
                )
            }
            proxyLatencies[groupName] = latency
            Self.runtimeLogger.info(
                "stage=proxyLatency success results=\(latency.results.count, privacy: .public) responsive=\(latency.results.lazy.filter { $0.delayMilliseconds != nil }.count, privacy: .public)"
            )
        } catch {
            Self.runtimeLogger.error(
                "stage=proxyLatency failed error=\(String(reflecting: error), privacy: .public)"
            )
            proxySelectionMessages[groupName] = error.localizedDescription
        }
    }

    private func performProxySelectionRequest(
        group groupName: String,
        requestedMember: String?
    ) async {
        guard state == .connected,
              let group = selectableProxyGroup(named: groupName),
              !proxySelectionRequests.contains(groupName) else {
            return
        }
        proxySelectionRequests.insert(groupName)
        Self.runtimeLogger.debug(
            "stage=proxySelection request operation=\(requestedMember == nil ? "snapshot" : "select", privacy: .public)"
        )
        proxySelectionMessages[groupName] = nil
        defer { proxySelectionRequests.remove(groupName) }

        do {
            let snapshot: ProxySelectionState
            if isUIReviewMode {
                snapshot = try reviewSelectionSnapshot(
                    group: group,
                    requestedMember: requestedMember
                )
            } else {
                let client = ProxySelectionProviderClient { [weak self] data in
                    guard let self else {
                        throw TunnelManagerError.providerSessionUnavailable
                    }
                    return try await self.sendProviderMessage(data)
                }
                if let requestedMember {
                    snapshot = try await client.select(
                        group: groupName,
                        member: requestedMember
                    )
                } else {
                    snapshot = try await client.snapshot(group: groupName)
                }
            }

            proxySelections[groupName] = snapshot
            Self.runtimeLogger.debug(
                "stage=proxySelection success members=\(snapshot.members.count, privacy: .public) selected=\(snapshot.selectedMember == nil ? "none" : "present", privacy: .public)"
            )
            guard !isUIReviewMode,
                  snapshot.selectedMember != nil,
                  let yaml = activeProfile?.yaml else {
                return
            }
            do {
                try await Task.detached(priority: .utility) {
                    try ProxySelectionStore.applicationGroup()
                        .recordVerified(
                            snapshot: snapshot,
                            group: groupName,
                            profileYAML: yaml
                        )
                }.value
            } catch {
                // The runtime selection remains truthful even if durable
                // storage fails. Surface the persistence failure instead of
                // pretending the choice will survive the next start.
                proxySelectionMessages[groupName] = error.localizedDescription
            }
        } catch {
            Self.runtimeLogger.error(
                "stage=proxySelection failed error=\(String(reflecting: error), privacy: .public)"
            )
            proxySelectionMessages[groupName] = error.localizedDescription
        }
    }

    private func selectableProxyGroup(
        named name: String
    ) -> ProxyGroupConfigurationSummary? {
        activeProfileSummary?.proxyGroups.first {
            $0.name == name
                && $0.strategy.lowercased() == "select"
        }
    }

    private func reviewSelectionSnapshot(
        group: ProxyGroupConfigurationSummary,
        requestedMember: String?
    ) throws -> ProxySelectionState {
        guard !group.members.isEmpty else {
            throw TunnelManagerError.providerSelectorUnavailable
        }
        if let requestedMember, !group.members.contains(requestedMember) {
            throw ProxySelectionProviderClientError.selectionNotApplied
        }
        let selected = requestedMember
            ?? proxySelections[group.name]?.selectedMember
            ?? group.members.first
        return ProxySelectionState(
            selectedMember: selected,
            members: group.members
        )
    }

    private func sendProviderMessage(
        _ data: Data,
        timeout: Duration = .seconds(5)
    ) async throws -> Data {
        guard state == .connected
                || (state == .connecting && isVerifyingProxyReadiness),
              let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected else {
            throw TunnelManagerError.providerSessionUnavailable
        }

        Self.runtimeLogger.debug(
            "stage=providerMessage hostSend begin bytes=\(data.count, privacy: .public)"
        )
        do {
            let response = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                let reply = ProviderMessageReply(continuation)
                do {
                    try session.sendProviderMessage(data) { response in
                        reply.receive(response)
                    }
                } catch {
                    reply.fail(error)
                }
                reply.startTimeout(after: timeout)
            }
            Self.runtimeLogger.debug(
                "stage=providerMessage hostSend success bytes=\(response.count, privacy: .public)"
            )
            return response
        } catch {
            Self.runtimeLogger.error(
                "stage=providerMessage hostSend failed error=\(String(reflecting: error), privacy: .public)"
            )
            throw error
        }
    }

    private func startTelemetryPollingIfNeeded() {
        guard
            state == .connected,
            !isUIReviewMode,
            telemetryPollingTask == nil
        else { return }
        telemetryPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTelemetry()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
            }
        }
    }

    private func stopTelemetryPolling() {
        telemetryPollingTask?.cancel()
        telemetryPollingTask = nil
    }

    func handleRuntimeEnvironmentEvent(
        _ event: RuntimeEnvironmentEvent
    ) async {
        guard !isUIReviewMode else { return }

        diagnosticEvents.record(event.diagnosticEventCode)
        let decision = RuntimeEnvironmentPolicy.decision(
            for: event,
            activity: runtimeConnectionActivity
        )
        if decision.shouldPauseTelemetry {
            stopTelemetryPolling()
        }
        guard decision.shouldRefreshProviderState else { return }

        // Force the next connected-state pass to request a fresh sample. This
        // never calls startVPNTunnel and never changes routes, DNS, or proxies.
        stopTelemetryPolling()
        updateState()
    }

    private func refreshTelemetry() async {
        guard state == .connected, !Task.isCancelled else { return }
        do {
            let client = ProxySelectionProviderClient { [weak self] data in
                guard let self else {
                    throw TunnelManagerError.providerSessionUnavailable
                }
                return try await self.sendProviderMessage(data)
            }
            telemetry = try await client.telemetry(maximumConnections: 50)
            telemetryUpdatedAt = .now
        } catch {
            // A transient provider-message failure must not disconnect a healthy
            // tunnel or replace the last truthful sample with fabricated zeros.
        }
    }

    private func installReviewTelemetry() {
        telemetry = NetworkTelemetrySnapshot(
            uploadBytesPerSecond: 384_000,
            downloadBytesPerSecond: 2_480_000,
            uploadTotal: 18_430_000,
            downloadTotal: 142_700_000,
            memoryBytes: 12_240_000,
            connections: [
                ConnectionTelemetry(
                    transport: .tcp,
                    destination: "developer.apple.com",
                    destinationPort: 443,
                    uploadTotal: 148_000,
                    downloadTotal: 2_840_000,
                    startedAtUnixMilliseconds: 1_775_003_420_000,
                    rule: "DomainSuffix",
                    rulePayload: "apple.com",
                    proxyChain: "Balanced → Singapore Edge"
                ),
                ConnectionTelemetry(
                    transport: .udp,
                    destination: "dns.google",
                    destinationPort: 53,
                    uploadTotal: 1_240,
                    downloadTotal: 2_880,
                    startedAtUnixMilliseconds: 1_775_003_550_000,
                    rule: "Match",
                    rulePayload: "",
                    proxyChain: "DIRECT"
                ),
            ]
        )
        telemetryUpdatedAt = .now
    }

    func importProfile(from url: URL) {
        guard ensurePrivacyConsent() else {
            profileMessage = PrivacyConsentError.required.localizedDescription
            return
        }
        guard canModifyProfiles else {
            profileMessage = AppLocalization.string(
                "Stop the secure connection before changing profiles."
            )
            profileMessageIsError = true
            return
        }
        isImportingProfile = true
        profileMessage = AppLocalization.string("Importing profile…")
        profileMessageIsError = false
        profileImportTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isImportingProfile = false
                profileImportTask = nil
            }

            do {
                let store = try ProfileCatalogStore.applicationGroup()
                let catalog = try await ProfileFileImporter.importProfile(
                    from: url,
                    into: store
                )
                await applyProductionProfileCatalog(catalog)
                diagnosticEvents.record(.profileImported)
                profileMessage = "Profile imported and activated."
                profileMessageIsError = false
            } catch is CancellationError {
                profileMessage = AppLocalization.string("Profile import cancelled.")
                profileMessageIsError = false
            } catch {
                diagnosticEvents.record(.profileOperationFailed)
                profileMessage = localizedProfileOperationError(error)
                profileMessageIsError = true
            }
        }
    }

    func cancelProfileImport() {
        profileImportTask?.cancel()
    }

    @discardableResult
    func createNativeProfile(node: AetherNode) async -> Bool {
        guard ensurePrivacyConsent(), canModifyProfiles else {
            profileMessage = AppLocalization.string(
                "Stop the secure connection before changing profiles."
            )
            profileMessageIsError = true
            return false
        }

        isUpdatingProfiles = true
        defer { isUpdatingProfiles = false }
        do {
            let profileName = String.localizedStringWithFormat(
                AppLocalization.string("%@ · Manual"),
                node.name
            )
            if isUIReviewMode {
                let yaml = try AetherNodeProfileCompiler.compile(node: node)
                let managed = ManagedProfile(
                    profile: ActiveProfile(
                        name: profileName,
                        yaml: yaml,
                        nativeNodes: [node]
                    )
                )
                installReviewProfileCatalog(
                    ProfileCatalog(
                        activeProfileID: managed.id,
                        profiles: profiles + [managed]
                    )
                )
            } else {
                try await performProductionProfileCatalogOperation {
                    try ProfileCatalogStore.applicationGroup().addNative(
                        nodes: [node],
                        suggestedName: profileName
                    )
                }
            }
            diagnosticEvents.record(.profileImported)
            profileMessage = AppLocalization.string(
                "Manual node created and activated."
            )
            profileMessageIsError = false
            return true
        } catch {
            diagnosticEvents.record(.profileOperationFailed)
            profileMessage = error.localizedDescription
            profileMessageIsError = true
            return false
        }
    }

    @discardableResult
    func updateNativeProfile(id: UUID, nodes: [AetherNode]) async -> Bool {
        guard ensurePrivacyConsent(), canModifyProfiles else {
            profileMessage = AppLocalization.string(
                "Stop the secure connection before changing profiles."
            )
            profileMessageIsError = true
            return false
        }

        isUpdatingProfiles = true
        defer { isUpdatingProfiles = false }
        do {
            if isUIReviewMode {
                guard let index = profiles.firstIndex(where: { $0.id == id }),
                      profiles[index].profile.nativeNodes != nil,
                      profiles[index].profile.subscription == nil else {
                    throw ProfileCatalogStoreError.notNativeProfile
                }
                let yaml = try AetherNodeProfileCompiler.compile(nodes: nodes)
                var updatedProfiles = profiles
                updatedProfiles[index] = ManagedProfile(
                    id: id,
                    profile: ActiveProfile(
                        name: profiles[index].profile.name,
                        yaml: yaml,
                        nativeNodes: nodes
                    )
                )
                installReviewProfileCatalog(
                    ProfileCatalog(
                        activeProfileID: activeProfileID,
                        profiles: updatedProfiles
                    )
                )
            } else {
                try await performProductionProfileCatalogOperation {
                    try ProfileCatalogStore.applicationGroup().updateNative(
                        id: id,
                        nodes: nodes
                    )
                }
            }
            diagnosticEvents.record(.profileImported)
            profileMessage = AppLocalization.string("Native nodes updated.")
            profileMessageIsError = false
            return true
        } catch {
            diagnosticEvents.record(.profileOperationFailed)
            profileMessage = error.localizedDescription
            profileMessageIsError = true
            return false
        }
    }

    func makePortableArchive(password: String) async -> Data? {
        guard ensurePrivacyConsent(), canModifyProfiles else {
            profileMessage = AppLocalization.string(
                "Stop the secure connection before changing profiles."
            )
            profileMessageIsError = true
            return nil
        }
        let catalog = ProfileCatalog(
            activeProfileID: activeProfileID,
            profiles: profiles
        )
        isTransferringProfiles = true
        defer { isTransferringProfiles = false }
        do {
            let archive = try await Task.detached(priority: .userInitiated) {
                try PortableProfileArchiveCodec().seal(
                    catalog: catalog,
                    password: password
                )
            }.value
            profileMessage = nil
            profileMessageIsError = false
            return archive
        } catch {
            profileMessage = error.localizedDescription
            profileMessageIsError = true
            return nil
        }
    }

    @discardableResult
    func importPortableArchive(
        from url: URL,
        password: String
    ) async -> Bool {
        guard ensurePrivacyConsent(), canModifyProfiles else {
            profileMessage = AppLocalization.string(
                "Stop the secure connection before changing profiles."
            )
            profileMessageIsError = true
            return false
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        isTransferringProfiles = true
        defer { isTransferringProfiles = false }
        do {
            let payload = try await Task.detached(priority: .userInitiated) {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                if let size = values.fileSize,
                   size > PortableProfileArchiveCodec.maximumArchiveBytes {
                    throw PortableProfileArchiveError.archiveTooLarge(size)
                }
                let data = try Data(
                    contentsOf: url,
                    options: [.mappedIfSafe]
                )
                return try PortableProfileArchiveCodec().open(
                    data,
                    password: password
                )
            }.value

            let catalog: ProfileCatalog
            if isUIReviewMode {
                catalog = mergeReviewCatalog(payload.catalog)
            } else {
                let importedCatalog = payload.catalog
                catalog = try await Task.detached(priority: .userInitiated) {
                    try ProfileCatalogStore.applicationGroup()
                        .mergeValidated(importedCatalog)
                }.value
            }
            if isUIReviewMode {
                installReviewProfileCatalog(catalog)
            } else {
                await applyProductionProfileCatalog(catalog)
            }
            profileMessage = String.localizedStringWithFormat(
                AppLocalization.string("%lld profiles are available after secure import."),
                Int64(catalog.profiles.count)
            )
            profileMessageIsError = false
            return true
        } catch {
            profileMessage = error.localizedDescription
            profileMessageIsError = true
            return false
        }
    }

    func reportPortableArchiveSaved() {
        profileMessage = AppLocalization.string("Portable archive saved securely.")
        profileMessageIsError = false
    }

    func handleExternalURL(_ url: URL) {
        externalSubscriptionLinkError = nil
        do {
            pendingExternalSubscription = try ExternalSubscriptionLinkParser
                .parse(url)
            clearProfileMessage()
        } catch let error as ExternalSubscriptionLinkError {
            pendingExternalSubscription = nil
            externalSubscriptionLinkError = error.localizedDescription
        } catch {
            pendingExternalSubscription = nil
            externalSubscriptionLinkError = AppLocalization.string(
                "This AetherRoute link could not be opened safely."
            )
        }
    }

    func cancelExternalSubscriptionImport() {
        pendingExternalSubscription = nil
    }

    func dismissExternalSubscriptionLinkError() {
        externalSubscriptionLinkError = nil
    }

    @discardableResult
    func addBypassRule(_ input: String) async -> Bool {
        guard ensurePrivacyConsent(), canModifyBypassPolicy else {
            bypassPolicyMessage = AppLocalization.string(
                "Disconnect before changing bypass rules."
            )
            bypassPolicyMessageIsError = true
            return false
        }
        isUpdatingBypassPolicy = true
        defer { isUpdatingBypassPolicy = false }
        do {
            let updated = try bypassPolicy.adding(BypassRule.parse(input))
            try await persistBypassPolicy(updated)
            bypassPolicyMessage = AppLocalization.string("Bypass rule added.")
            bypassPolicyMessageIsError = false
            return true
        } catch {
            bypassPolicyMessage = error.localizedDescription
            bypassPolicyMessageIsError = true
            return false
        }
    }

    func removeBypassRule(id: UUID) async {
        guard ensurePrivacyConsent(), canModifyBypassPolicy else {
            bypassPolicyMessage = AppLocalization.string(
                "Disconnect before changing bypass rules."
            )
            bypassPolicyMessageIsError = true
            return
        }
        isUpdatingBypassPolicy = true
        defer { isUpdatingBypassPolicy = false }
        do {
            try await persistBypassPolicy(bypassPolicy.removing(id: id))
            bypassPolicyMessage = AppLocalization.string("Bypass rule removed.")
            bypassPolicyMessageIsError = false
        } catch {
            bypassPolicyMessage = error.localizedDescription
            bypassPolicyMessageIsError = true
        }
    }

    func clearBypassPolicyMessage() {
        bypassPolicyMessage = nil
        bypassPolicyMessageIsError = false
    }

    @discardableResult
    func confirmExternalSubscriptionImport(
        id: UUID
    ) async -> Bool {
        guard let request = pendingExternalSubscription,
              request.id == id else {
            return false
        }
        guard await addSubscription(
            urlText: request.subscriptionURL.absoluteString
        ) else {
            return false
        }
        pendingExternalSubscription = nil
        return true
    }

    @discardableResult
    func addSubscription(urlText: String) async -> Bool {
        guard ensurePrivacyConsent(), canModifyProfiles else {
            profileMessage = AppLocalization.string(
                "Stop the secure connection before changing profiles."
            )
            profileMessageIsError = true
            return false
        }
#if !AETHERROUTE_DEVELOPMENT_PREVIEW
        guard !isUIReviewMode else { return false }
#endif

        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let url = URL(string: trimmed) else {
                throw ProfileSubscriptionError.invalidURL
            }
            let subscription = try ProfileSubscription(url: url)
            isRefreshingSubscription = true
            defer { isRefreshingSubscription = false }

            switch try await subscriptionClient.fetch(subscription) {
            case let .updated(data, metadata, report):
                let suggestedName = subscriptionDisplayName(for: url)
#if AETHERROUTE_DEVELOPMENT_PREVIEW
                if isUIReviewMode {
                    try installPreviewSubscriptionProfile(
                        data: data,
                        suggestedName: suggestedName,
                        subscription: metadata
                    )
                } else {
                    try await performProductionProfileCatalogOperation {
                        try ProfileCatalogStore.applicationGroup().addValidated(
                            data: data,
                            suggestedName: suggestedName,
                            subscription: metadata
                        )
                    }
                }
#else
                try await performProductionProfileCatalogOperation {
                    try ProfileCatalogStore.applicationGroup().addValidated(
                        data: data,
                        suggestedName: suggestedName,
                        subscription: metadata
                    )
                }
#endif
                profileMessage = subscriptionSuccessMessage(
                    base: "Subscription downloaded and activated.",
                    partial: "Subscription downloaded and activated. %lld usable nodes imported; %lld invalid nodes skipped.",
                    report: report
                )
                profileMessageIsError = false
                return true
            case .notModified:
                throw ProfileSubscriptionError.notModifiedWithoutActiveProfile
            }
        } catch {
            profileMessage = localizedProfileOperationError(error)
            profileMessageIsError = true
            return false
        }
    }

#if AETHERROUTE_DEVELOPMENT_PREVIEW
    /// The unsigned preview deliberately has no Network Extension or shared
    /// Keychain entitlement. Subscription validation is still useful during
    /// evaluation, so keep its result in the same in-memory review catalog as
    /// manually entered nodes instead of silently ignoring the action.
    private func installPreviewSubscriptionProfile(
        data: Data,
        suggestedName: String,
        subscription: ProfileSubscription
    ) throws {
        try ProfileImportValidator.validate(data: data)
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw ProfileImportError.notUTF8
        }
        guard profiles.count < ProfileCatalogStore.maximumProfiles else {
            throw ProfileCatalogStoreError.profileLimitReached(
                ProfileCatalogStore.maximumProfiles
            )
        }

        let cleanName = suggestedName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let managed = ManagedProfile(
            profile: ActiveProfile(
                name: cleanName.isEmpty ? "Imported profile" : cleanName,
                yaml: yaml,
                subscription: subscription
            )
        )
        installReviewProfileCatalog(
            ProfileCatalog(
                activeProfileID: managed.id,
                profiles: profiles + [managed]
            )
        )
    }
#endif

    func refreshSubscription() async {
        await refreshSubscription(isAutomatic: false)
    }

    func activateProfile(id: UUID) async {
        guard canModifyProfiles else {
            profileMessage = AppLocalization.string(
                "Stop the secure connection before changing profiles."
            )
            profileMessageIsError = true
            return
        }
        isUpdatingProfiles = true
        defer { isUpdatingProfiles = false }
        if isUIReviewMode {
            guard profiles.contains(where: { $0.id == id }) else { return }
            installReviewProfileCatalog(
                ProfileCatalog(activeProfileID: id, profiles: profiles)
            )
            profileMessage = AppLocalization.string("Profile activated.")
            profileMessageIsError = false
            return
        }
        do {
            try await performProductionProfileCatalogOperation {
                try ProfileCatalogStore.applicationGroup().activate(id: id)
            }
            profileMessage = AppLocalization.string("Profile activated.")
            profileMessageIsError = false
        } catch {
            profileMessage = error.localizedDescription
            profileMessageIsError = true
        }
    }

    @discardableResult
    func renameProfile(id: UUID, name: String) async -> Bool {
        guard canModifyProfiles else { return false }
        isUpdatingProfiles = true
        defer { isUpdatingProfiles = false }
        if isUIReviewMode {
            let cleanName = name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !cleanName.isEmpty,
                  let index = profiles.firstIndex(where: { $0.id == id }) else {
                return false
            }
            var updatedProfiles = profiles
            let existing = profiles[index].profile
            updatedProfiles[index] = ManagedProfile(
                id: id,
                profile: ActiveProfile(
                    name: cleanName,
                    yaml: existing.yaml,
                    importedAt: existing.importedAt,
                    subscription: existing.subscription,
                    nativeNodes: existing.nativeNodes
                )
            )
            installReviewProfileCatalog(
                ProfileCatalog(
                    activeProfileID: activeProfileID,
                    profiles: updatedProfiles
                )
            )
            profileMessage = AppLocalization.string("Profile renamed.")
            profileMessageIsError = false
            return true
        }
        do {
            try await performProductionProfileCatalogOperation {
                try ProfileCatalogStore.applicationGroup().rename(
                    id: id,
                    to: name
                )
            }
            profileMessage = AppLocalization.string("Profile renamed.")
            profileMessageIsError = false
            return true
        } catch {
            profileMessage = error.localizedDescription
            profileMessageIsError = true
            return false
        }
    }

    func removeProfile(id: UUID) async {
        guard canModifyProfiles else { return }
        isUpdatingProfiles = true
        defer { isUpdatingProfiles = false }
        if isUIReviewMode {
            guard id != activeProfileID else { return }
            installReviewProfileCatalog(
                ProfileCatalog(
                    activeProfileID: activeProfileID,
                    profiles: profiles.filter { $0.id != id }
                )
            )
            profileMessage = AppLocalization.string("Profile removed.")
            profileMessageIsError = false
            return
        }
        do {
            try await performProductionProfileCatalogOperation {
                try ProfileCatalogStore.applicationGroup().remove(id: id)
            }
            profileMessage = AppLocalization.string("Profile removed.")
            profileMessageIsError = false
        } catch {
            profileMessage = error.localizedDescription
            profileMessageIsError = true
        }
    }

    func runSubscriptionUpdateLoop() async {
        guard !isUIReviewMode else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if state == .disconnected {
                await refreshSubscriptionIfDue()
            }
        }
    }

    func clearProfileMessage() {
        profileMessage = nil
        profileMessageIsError = false
    }

    func reportProfileImportError(_ error: Error) {
        diagnosticEvents.record(.profileOperationFailed)
        profileMessage = localizedProfileOperationError(error)
        profileMessageIsError = true
    }

    func makeDiagnosticReport() async throws -> Data {
        diagnosticEvents.record(.diagnosticExportRequested)
        let providerDiagnostics = await currentProviderDiagnostics()
        let summary = activeProfileSummary
        let report = DiagnosticReport(
            generatedAtUnixMilliseconds: UInt64(
                max(0, Date.now.timeIntervalSince1970 * 1_000)
            ),
            build: DiagnosticReport.Build(
                applicationVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "unknown",
                buildNumber: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String ?? "unknown",
                operatingSystemVersion:
                    ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: Self.diagnosticArchitecture,
                distribution: Self.diagnosticDistribution
            ),
            session: DiagnosticReport.Session(
                state: Self.diagnosticState(for: state),
                engine: diagnosticEngine,
                routingMode: sessionRoutingMode ?? routingMode
            ),
            profile: DiagnosticReport.Profile(
                isLoaded: activeProfile != nil,
                usesSubscription: activeProfile?.subscription != nil,
                proxyCount: summary?.proxyCount ?? 0,
                proxyGroupCount: summary?.proxyGroupCount ?? 0,
                proxyProviderCount: summary?.proxyProviderCount ?? 0,
                ruleCount: summary?.ruleCount ?? 0,
                ruleProviderCount: summary?.ruleProviderCount ?? 0
            ),
            telemetry: DiagnosticReport.Telemetry(
                uploadBytesPerSecond: telemetry.uploadBytesPerSecond,
                downloadBytesPerSecond: telemetry.downloadBytesPerSecond,
                uploadTotal: telemetry.uploadTotal,
                downloadTotal: telemetry.downloadTotal,
                memoryBytes: telemetry.memoryBytes,
                activeConnectionCount: telemetry.connections.count
            ),
            provider: providerDiagnostics,
            events: diagnosticEvents.snapshot()
        )
        return try DiagnosticReportEncoder.encode(report)
    }

    private func currentProviderDiagnostics() async -> DiagnosticReport.Provider {
        guard state == .connected, !isUIReviewMode else {
            return .unavailable
        }
        do {
            let client = ProxySelectionProviderClient { [weak self] data in
                guard let self else {
                    throw TunnelManagerError.providerSessionUnavailable
                }
                return try await self.sendProviderMessage(data)
            }
            return DiagnosticReport.Provider(
                isAvailable: true,
                counters: try await client.diagnostics()
            )
        } catch {
            return .unavailable
        }
    }

    private func mergeReviewCatalog(
        _ imported: ProfileCatalog
    ) -> ProfileCatalog {
        var merged = profiles
        var identifiers = Set(merged.map(\.id))
        var importedIdentifiers: [UUID: UUID] = [:]
        for managed in imported.profiles {
            if let existing = merged.first(where: {
                $0.profile.name == managed.profile.name
                    && $0.profile.yaml == managed.profile.yaml
                    && $0.profile.subscription?.url ==
                        managed.profile.subscription?.url
            }) {
                importedIdentifiers[managed.id] = existing.id
                continue
            }
            guard merged.count < ProfileCatalogStore.maximumProfiles else {
                break
            }
            var identifier = managed.id
            while identifiers.contains(identifier) {
                identifier = UUID()
            }
            identifiers.insert(identifier)
            importedIdentifiers[managed.id] = identifier
            merged.append(
                ManagedProfile(id: identifier, profile: managed.profile)
            )
        }
        let selected = activeProfileID
            ?? imported.activeProfileID.flatMap { importedIdentifiers[$0] }
        return ProfileCatalog(activeProfileID: selected, profiles: merged)
    }

    private func refreshSubscriptionIfDue() async {
        guard activeProfile?.subscription?.isDue() == true else { return }
        await refreshSubscription(isAutomatic: true)
    }

    private func refreshSubscription(isAutomatic: Bool) async {
        guard ensurePrivacyConsent(), canModifyProfiles,
              let profile = activeProfile,
              let subscription = profile.subscription,
              !isUIReviewMode else {
            if !isAutomatic, activeProfile?.subscription == nil {
                profileMessage = AppLocalization.string("The active profile is not a subscription.")
                profileMessageIsError = true
            }
            return
        }

        isRefreshingSubscription = true
        defer { isRefreshingSubscription = false }
        do {
            guard let activeProfileID else {
                throw ProfileCatalogStoreError.activeProfileNotFound
            }
            let update = try await subscriptionClient.fetch(subscription)
            try await performProductionProfileCatalogOperation {
                let updated: ActiveProfile
                switch update {
                case let .updated(data, metadata, _):
                    try ProfileImportValidator.validate(data: data)
                    guard let yaml = String(data: data, encoding: .utf8) else {
                        throw ProfileImportError.notUTF8
                    }
                    updated = ActiveProfile(
                        name: profile.name,
                        yaml: yaml,
                        subscription: metadata
                    )
                case let .notModified(metadata):
                    guard let data = profile.yaml.data(using: .utf8) else {
                        throw ProfileImportError.notUTF8
                    }
                    updated = ActiveProfile(
                        name: profile.name,
                        yaml: String(decoding: data, as: UTF8.self),
                        importedAt: profile.importedAt,
                        subscription: metadata
                    )
                }
                return try ProfileCatalogStore.applicationGroup().replace(
                    id: activeProfileID,
                    with: updated
                )
            }
            switch update {
            case let .updated(_, _, report):
                profileMessage = subscriptionSuccessMessage(
                    base: "Subscription updated and activated.",
                    partial: "Subscription updated and activated. %lld usable nodes imported; %lld invalid nodes skipped.",
                    report: report
                )
            case .notModified:
                profileMessage = AppLocalization.string(
                    "Subscription is already up to date."
                )
            }
            diagnosticEvents.record(.subscriptionRefreshed)
            profileMessageIsError = false
        } catch {
            diagnosticEvents.record(.profileOperationFailed)
            profileMessage = localizedProfileOperationError(error)
            profileMessageIsError = true
        }
    }

    private func localizedProfileOperationError(_ error: Error) -> String {
        guard let issue = ProfileOperationIssue(error) else {
            return AppLocalization.string(
                "The profile operation could not be completed."
            )
        }
        switch issue {
        case .invalidSubscriptionURL:
            return AppLocalization.string(
                "Enter a valid HTTPS subscription address without embedded credentials or a fragment."
            )
        case .invalidAutoUpdateInterval:
            return AppLocalization.string(
                "Choose a subscription update interval between 15 minutes and 7 days."
            )
        case .invalidSubscriptionResponse:
            return AppLocalization.string(
                "The subscription provider returned an invalid response."
            )
        case .unsafeRedirect:
            return AppLocalization.string(
                "The subscription provider attempted an unsafe redirect."
            )
        case .tooManyRedirects:
            return AppLocalization.string(
                "The subscription provider redirected too many times."
            )
        case let .subscriptionResponseTooLarge(bytes):
            return String.localizedStringWithFormat(
                AppLocalization.string("The subscription response is too large (%lld bytes)."),
                Int64(clamping: bytes)
            )
        case let .subscriptionHTTPStatus(status):
            return String.localizedStringWithFormat(
                AppLocalization.string("The subscription provider returned HTTP %lld. Check that the link is active and permitted for this Mac."),
                Int64(clamping: status)
            )
        case .notModifiedWithoutActiveProfile:
            return AppLocalization.string(
                "The subscription reported no changes before an active profile existed."
            )
        case .emptyProfile:
            return AppLocalization.string("The profile is empty.")
        case let .profileTooLarge(bytes):
            return String.localizedStringWithFormat(
                AppLocalization.string("The profile is too large (%lld bytes)."),
                Int64(clamping: bytes)
            )
        case .profileNotUTF8:
            return AppLocalization.string("The profile is not UTF-8 text.")
        case let .forbiddenExecutableKey(key):
            return String.localizedStringWithFormat(
                AppLocalization.string("The executable profile key ‘%@’ is not allowed."),
                key
            )
        case .missingProxyDefinition:
            return AppLocalization.string(
                "No proxies or proxy providers were found in the profile."
            )
        case .unsupportedSubscriptionFormat:
            return AppLocalization.string(
                "The subscription is neither supported YAML nor a share-link list."
            )
        case .invalidSubscriptionBase64:
            return AppLocalization.string(
                "The subscription contains invalid Base64 text."
            )
        case let .tooManySubscriptionNodes(maximum):
            return String.localizedStringWithFormat(
                AppLocalization.string("The subscription contains more than %lld nodes."),
                Int64(clamping: maximum)
            )
        case let .invalidSubscriptionNode(index):
            return String.localizedStringWithFormat(
                AppLocalization.string("Subscription node %lld is invalid."),
                Int64(clamping: index)
            )
        case let .unsupportedShareScheme(scheme):
            return String.localizedStringWithFormat(
                AppLocalization.string("The subscription uses the unsupported ‘%@’ share-link scheme."),
                scheme
            )
        }
    }

    private func subscriptionDisplayName(for url: URL) -> String {
        let filename = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !filename.isEmpty, filename != "/" { return filename }
        return url.host ?? AppLocalization.string("Subscribed profile")
    }

    private func subscriptionSuccessMessage(
        base: String.LocalizationValue,
        partial: String.LocalizationValue,
        report: SubscriptionPayloadReport
    ) -> String {
        guard report.skippedNodeCount > 0,
              let usableNodeCount = report.usableNodeCount else {
            return AppLocalization.string(base)
        }
        return String.localizedStringWithFormat(
            AppLocalization.string(partial),
            Int64(usableNodeCount),
            Int64(report.skippedNodeCount)
        )
    }

    private func installReviewProfileCatalog(_ catalog: ProfileCatalog) {
        installProfileProjection(
            ProfileCatalogProjectionBuilder.review(catalog)
        )
    }

    private func installProfileProjection(
        _ projection: ProfileCatalogProjection
    ) {
        clearProxySelectionRuntimeState()
        profiles = projection.catalog.profiles
        activeProfileID = projection.catalog.activeProfileID
        activeProfile = projection.catalog.activeProfile?.profile
        activeProfileSummary = projection.summary
        dnsRuntimePolicy = projection.dnsPolicy
        dnsRuntimePolicyMessage = projection.dnsErrorDescription
        dnsRuntimePolicyMessageIsError =
            projection.dnsErrorDescription != nil
        refreshRoutingResourceStatuses()
    }

    private func applyProductionProfileCatalog(
        _ catalog: ProfileCatalog
    ) async {
        let projection = await Task.detached(priority: .userInitiated) {
            ProfileCatalogProjectionBuilder.production(catalog)
        }.value
        installProfileProjection(projection)
    }

    private func performProductionProfileCatalogOperation(
        _ operation: @escaping @Sendable () throws -> ProfileCatalog
    ) async throws {
        let projection = try await Task.detached(priority: .userInitiated) {
            ProfileCatalogProjectionBuilder.production(try operation())
        }.value
        installProfileProjection(projection)
    }

    var isEnabled: Bool {
        switch state {
        case .connecting, .connected: true
        default: false
        }
    }

    var isConnected: Bool {
        state == .connected
    }

    var isTransitioning: Bool {
        switch state {
        case .loading, .connecting, .disconnecting: true
        default: false
        }
    }

    private var managerConnectionIsTransitioning: Bool {
        guard let status = manager?.connection.status else { return false }
        return status == .connecting
            || status == .reasserting
            || status == .disconnecting
    }

    private var managerConnectionPermitsStart: Bool {
        guard let status = manager?.connection.status else { return true }
        return status == .invalid || status == .disconnected
    }

    var canConnect: Bool {
#if AETHERROUTE_DEVELOPMENT_PREVIEW
        false
#else
        hasAcceptedPrivacyDisclosure
            && activeProfile != nil
            && distributionConnectionAccess.permitsNewConnection
            && !isPreparing
            && !systemExtensionApprovalRequired
            && managerConnectionPermitsStart
            && !managerConnectionIsTransitioning
            && !isTransitioning
            && !isImportingProfile
            && !isUpdatingProfiles
            && !isUpdatingBypassPolicy
#endif
    }

    var isConnectionPreviewOnly: Bool {
#if AETHERROUTE_DEVELOPMENT_PREVIEW
        true
#else
        false
#endif
    }

    var canChangeRoutingMode: Bool {
        hasAcceptedPrivacyDisclosure
            && !isEnabled
            && !isTransitioning
            && !isImportingProfile
            && !isUpdatingProfiles
    }

    var canChangeNetworkEngine: Bool {
        hasAcceptedPrivacyDisclosure
            && !isEnabled
            && !isTransitioning
            && !isImportingProfile
            && !isUpdatingProfiles
    }

    var canModifyProfiles: Bool {
        hasAcceptedPrivacyDisclosure
            && !isEnabled
            && !isTransitioning
            && !isRefreshingSubscription
            && !isImportingProfile
            && !isUpdatingProfiles
            && !isUpdatingBypassPolicy
            && !isTransferringProfiles
    }

    var canModifyBypassPolicy: Bool {
        canModifyProfiles
    }

    var canModifyDNSRuntimePolicy: Bool {
        canModifyProfiles
            && !isUpdatingDNSRuntimePolicy
            && activeProfileSummary?.dns.isEnabled == true
    }

    var canModifyLocalProxySettings: Bool {
        canChangeNetworkEngine
    }

    var canPerformPrimaryAction: Bool {
        switch state {
        case .disconnected, .failed:
            canConnect
        case .connecting, .connected:
            true
        case .privacyConsentRequired, .loading, .disconnecting:
            false
        }
    }

    var primaryActionTitle: String {
        if isConnectionPreviewOnly, !isEnabled {
            return AppLocalization.string("Preview only")
        }
        return switch state {
        case .privacyConsentRequired: AppLocalization.string("Review privacy")
        case .loading: AppLocalization.string("Preparing")
        case .disconnected where !distributionConnectionAccess.permitsNewConnection:
            AppLocalization.string("License required")
        case .disconnected: AppLocalization.string("Connect")
        case .connecting: AppLocalization.string("Cancel")
        case .connected: AppLocalization.string("Disconnect")
        case .disconnecting: AppLocalization.string("Disconnecting")
        case .failed: AppLocalization.string("Retry")
        }
    }

    var statusTitle: String {
        switch state {
        case .privacyConsentRequired: AppLocalization.string("Privacy review required")
        case .loading: AppLocalization.string("Preparing")
        case .disconnected where !distributionConnectionAccess.permitsNewConnection:
            AppLocalization.string("License required")
        case .disconnected: AppLocalization.string("Not connected")
        case .connecting: AppLocalization.string("Connecting")
        case .connected: AppLocalization.string("Traffic routing active")
        case .disconnecting: AppLocalization.string("Disconnecting")
        case .failed: AppLocalization.string("Unavailable")
        }
    }

    var statusDetail: String {
        if isConnectionPreviewOnly, !isEnabled {
            return AppLocalization.string(
                "This preview can import and inspect profiles, but it cannot enable system routing."
            )
        }
        return switch state {
        case .privacyConsentRequired:
            AppLocalization.string("Review how network data is handled before continuing")
        case .loading:
            AppLocalization.string("Loading the local network extension configuration")
        case .disconnected where !distributionConnectionAccess.permitsNewConnection:
            distributionConnectionAccessDetail
        case .disconnected:
            AppLocalization.string("Traffic is using the normal network path")
        case .connecting:
            AppLocalization.string("Verifying the network extension")
        case .connected:
            AppLocalization.string("The network extension reports ready")
        case .disconnecting:
            AppLocalization.string("Restoring the normal network path")
        case let .failed(message): message
        }
    }

    private var distributionConnectionAccessDetail: String {
        switch distributionConnectionAccess {
        case .unrestrictedDevelopment, .authorized:
            AppLocalization.string("Traffic is using the normal network path")
        case .activationRequired:
            AppLocalization.string("Activate AetherRoute in Settings > Account before connecting.")
        case .restricted(.expired):
            AppLocalization.string("The saved license has expired. Review Settings > Account.")
        case .restricted(.revoked):
            AppLocalization.string("The saved license was revoked. Review Settings > Account.")
        case .restricted(.deviceLimit):
            AppLocalization.string("This license reached its device limit. Review Settings > Account.")
        case .restricted(.active):
            AppLocalization.string("The saved license cannot authorize a connection. Review Settings > Account.")
        case .verificationUnavailable:
            AppLocalization.string("The saved license cannot be verified. Review Settings > Account.")
        }
    }

    var recoveryPlan: ConnectionRecoveryPlan? {
        guard case .failed = state else { return nil }
        let context = activeProfile == nil
            ? ConnectionFailureContext.missingProfile
            : failureContext ?? .unknown
        return ConnectionRecoveryPlan(context: context)
    }

    private func loadOrCreateManager() async throws -> NEVPNManager {
        Self.runtimeLogger.info(
            "stage=loadOrCreateManager begin engine=\(self.networkEngineMode.rawValue, privacy: .public)"
        )
        try privacyConsentStore.requireCurrentConsent()
        Self.runtimeLogger.info("stage=loadExistingManager begin")
        if let existing = try await loadExistingManager() {
            Self.runtimeLogger.info("stage=loadExistingManager success result=existing")
            return existing
        }
        Self.runtimeLogger.info("stage=loadExistingManager success result=none")

        let manager: NEVPNManager = switch networkEngineMode {
        case .transparent: NETransparentProxyManager()
#if AETHERROUTE_INDEPENDENT
        case .tun: NETunnelProviderManager()
#endif
        }
        let provider = NETunnelProviderProtocol()
        provider.providerBundleIdentifier = networkEngineMode.providerBundleIdentifier
        provider.serverAddress = networkEngineMode.serverAddress
        provider.providerConfiguration = TunnelProviderConfigurationCodec.setting(
            routingMode: routingMode,
            localProxy: providerLocalProxySettings
        )
        manager.protocolConfiguration = provider
        manager.localizedDescription = AppConstants.localizedDescription
        manager.isEnabled = true
        Self.runtimeLogger.info("stage=createManager save begin")
        try await manager.saveToPreferences()
        Self.runtimeLogger.info("stage=createManager save success")
        Self.runtimeLogger.info("stage=createManager reload begin")
        try await manager.loadFromPreferences()
        Self.runtimeLogger.info("stage=createManager reload success")
        return manager
    }

    private func persistProviderConfiguration(
        _ requestedMode: RoutingMode,
        localProxy: LocalProxySettings,
        in manager: NEVPNManager
    ) async throws {
        isPersistingConfiguration = true
        defer { isPersistingConfiguration = false }

        Self.runtimeLogger.info("stage=persistConfiguration reloadBeforeSave begin")
        try await manager.loadFromPreferences()
        Self.runtimeLogger.info("stage=persistConfiguration reloadBeforeSave success")
        guard let provider = manager.protocolConfiguration
            as? NETunnelProviderProtocol else {
            Self.runtimeLogger.error("stage=persistConfiguration failed reason=invalidProtocol")
            throw TunnelManagerError.invalidProtocolConfiguration
        }
        guard TunnelProviderConfigurationCodec.requiresPersistence(
            routingMode: requestedMode,
            localProxy: localProxy,
            configuration: provider.providerConfiguration,
            isEnabled: manager.isEnabled
        ) else {
            Self.runtimeLogger.info("stage=persistConfiguration skipped reason=unchanged")
            return
        }

        guard let updatedProvider = provider.copy()
            as? NETunnelProviderProtocol else {
            throw TunnelManagerError.invalidProtocolConfiguration
        }

        updatedProvider.providerConfiguration = TunnelProviderConfigurationCodec.setting(
            routingMode: requestedMode,
            localProxy: localProxy,
            in: provider.providerConfiguration
        )
        manager.protocolConfiguration = updatedProvider
        manager.isEnabled = true
        Self.runtimeLogger.info("stage=persistConfiguration save begin")
        try await manager.saveToPreferences()
        Self.runtimeLogger.info("stage=persistConfiguration save success")
        Self.runtimeLogger.info("stage=persistConfiguration reloadAfterSave begin")
        try await manager.loadFromPreferences()
        Self.runtimeLogger.info("stage=persistConfiguration reloadAfterSave success")

        guard manager.isEnabled,
              let persistedProvider = manager.protocolConfiguration
                as? NETunnelProviderProtocol,
              TunnelProviderConfigurationCodec.isPrimaryConfiguration(
                  persistedProvider.providerConfiguration
              ),
              try TunnelProviderConfigurationCodec.routingMode(
                  from: persistedProvider.providerConfiguration
              ) == requestedMode,
              try TunnelProviderConfigurationCodec.localProxySettings(
                  from: persistedProvider.providerConfiguration
              ) == localProxy else {
            Self.runtimeLogger.error("stage=persistConfiguration failed reason=verification")
            throw TunnelManagerError.configurationDidNotPersist
        }
        Self.runtimeLogger.info("stage=persistConfiguration verification success")
    }

    private var providerLocalProxySettings: LocalProxySettings {
#if AETHERROUTE_INDEPENDENT
        networkEngineMode == .tun ? localProxySettings : LocalProxySettings()
#else
        LocalProxySettings()
#endif
    }

    private func updateLocalProxySettings(
        _ update: (inout LocalProxySettings) -> Void
    ) {
        guard canModifyLocalProxySettings else {
            localProxySettingsMessage = AppLocalization.string(
                "Disconnect before changing the local proxy."
            )
            return
        }
        var updated = localProxySettings
        update(&updated)
        do {
            let validated = try updated.validated()
            if !isUIReviewMode {
                try localProxySettingsStore.save(validated)
            }
            localProxySettings = validated
            localProxySettingsMessage = validated.isEnabled
                ? AppLocalization.string(
                    "The loopback proxy will start with the next TUN connection."
                )
                : AppLocalization.string("The loopback proxy is off.")
        } catch {
            localProxySettingsMessage = error.localizedDescription
        }
    }

    private func requireManager() async throws -> NEVPNManager {
        try privacyConsentStore.requireCurrentConsent()
        if let manager {
            Self.runtimeLogger.info("stage=requireManager source=cache")
            return manager
        }
        Self.runtimeLogger.info("stage=requireManager source=preferences")
        let loaded = try await loadOrCreateManager()
        installManager(loaded)
        observeConfigurationChanges()
        return loaded
    }

    private func loadExistingManager() async throws -> NEVPNManager? {
        Self.runtimeLogger.info(
            "stage=queryManagers begin engine=\(self.networkEngineMode.rawValue, privacy: .public)"
        )
        let loaded: [NEVPNManager] = switch networkEngineMode {
        case .transparent:
            try await NETransparentProxyManager.loadAllFromPreferences().map { $0 }
#if AETHERROUTE_INDEPENDENT
        case .tun:
            try await NETunnelProviderManager.loadAllFromPreferences().map { $0 }
#endif
        }
        let matching = loaded
            .filter { manager in
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier ==
                    networkEngineMode.providerBundleIdentifier
            }
        Self.runtimeLogger.info(
            "stage=queryManagers success total=\(loaded.count, privacy: .public) matching=\(matching.count, privacy: .public)"
        )
        guard matching.count <= 1 else {
            Self.runtimeLogger.error("stage=queryManagers failed reason=duplicates")
            throw TunnelManagerError.duplicateConfigurations
        }
        return matching.first
    }

    private func installManager(_ manager: NEVPNManager) {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
            self.statusObserver = nil
        }
        resetManagerScopedLifecycleState()
        self.manager = manager
        observeStatus()
    }

    private func invalidateCachedManager() {
        invalidateConnectionRequest()
        cancelConnectionWatchdog()
        cancelDisconnectionWatchdog()
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
            self.statusObserver = nil
        }
        resetManagerScopedLifecycleState()
        manager = nil
        connectedSince = nil
        sessionRoutingMode = nil
        sessionNetworkEngineMode = nil
        clearProxySelectionRuntimeState()
    }

    private func observeStatus() {
        guard statusObserver == nil, let manager else { return }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateState() }
        }
    }

    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.reloadAfterConfigurationChange()
            }
        }
    }

    private func reloadAfterConfigurationChange() async {
        guard !isUIReviewMode,
              !isPersistingConfiguration,
              !isReloadingConfiguration else {
            Self.runtimeLogger.info("stage=configurationChange ignored reason=busyOrReview")
            return
        }
        Self.runtimeLogger.info("stage=configurationChange reload begin")
        isReloadingConfiguration = true
        defer { isReloadingConfiguration = false }

        do {
            guard let reloaded = try await loadExistingManager() else {
                Self.runtimeLogger.info("stage=configurationChange reload result=missing")
                invalidateCachedManager()
                state = .disconnected
                return
            }
            installManager(reloaded)
            updateState()
            Self.runtimeLogger.info("stage=configurationChange reload success")
        } catch {
            Self.runtimeLogger.error(
                "stage=configurationChange reload failed error=\(String(reflecting: error), privacy: .public)"
            )
            invalidateCachedManager()
            recordFailure(error, context: .configuration)
        }
    }

    private func updateState() {
        guard let connection = manager?.connection else {
            Self.runtimeLogger.info("stage=updateState status=missing")
            state = .disconnected
            connectedSince = nil
            sessionRoutingMode = nil
            sessionNetworkEngineMode = nil
            clearProxySelectionRuntimeState()
            return
        }
        let status = connection.status
        let previousProviderStatus = lastObservedProviderStatus
        if status == .connected, previousProviderStatus != .connected {
            providerConnectionID = UUID()
            readinessVerifiedConnectionID = nil
        } else if status != .connected {
            providerConnectionID = nil
            readinessVerifiedConnectionID = nil
        }
        lastObservedProviderStatus = status

        if TunnelLifecycleTransitionPolicy.shouldArmDisconnectionWatchdog(
            providerIsDisconnecting: status == .disconnecting,
            disconnectionAttemptPending: disconnectionAttemptID != nil
        ) {
            Self.runtimeLogger.info(
                "stage=updateState adoptingDisconnectingStatus"
            )
            beginDisconnectionWatchdog()
        }

        if disconnectionAttemptID != nil,
           status != .invalid,
           status != .disconnected {
            Self.runtimeLogger.info(
                "stage=updateState preservingDisconnectRequest status=\(status.rawValue, privacy: .public)"
            )
            cancelConnectionReadiness()
            state = .disconnecting
            return
        }

        let readinessGroups = activeProfileSummary.map {
            ProxyConnectionReadinessPolicy.groupsToVerify(summary: $0)
        } ?? []
        let requiresReadiness = status == .connected
            && !readinessGroups.isEmpty
            && providerConnectionID != readinessVerifiedConnectionID

        Self.runtimeLogger.info(
            "stage=updateState status=\(status.rawValue, privacy: .public)"
        )
        if ProviderTerminationPolicy.isUnexpectedTerminalState(
            currentIsTerminal: Self.isTerminalProviderStatus(status),
            previousWasActive: previousProviderStatus.map {
                Self.isActiveProviderStatus($0)
            } ?? false,
            connectionAttemptPending: connectionAttemptID != nil,
            disconnectionAttemptPending: disconnectionAttemptID != nil
        ) {
            Self.runtimeLogger.error(
                "stage=updateState unexpectedTerminal status=\(status.rawValue, privacy: .public) previous=\(previousProviderStatus?.rawValue ?? -1, privacy: .public)"
            )
            handleUnexpectedProviderTermination(connection)
            return
        }
        state = switch status {
        case .invalid, .disconnected: .disconnected
        case .connecting, .reasserting: .connecting
        case .connected: requiresReadiness ? .connecting : .connected
        case .disconnecting: .disconnecting
        @unknown default: .failed(AppLocalization.string("Unknown network extension status"))
        }
        connectionStage = ConnectionStagePolicy.stage(
            providerPhase: Self.providerLifecyclePhase(status),
            isVerifyingReadiness: requiresReadiness || isVerifyingProxyReadiness
        )
        if status == .connected {
            cancelConnectionWatchdog()
        }
        switch state {
        case .connected, .disconnected, .failed:
            cancelConnectionWatchdog()
            cancelDisconnectionWatchdog()
        case .privacyConsentRequired, .loading, .connecting, .disconnecting:
            break
        }
        if !distributionConnectionAccess.permitsNewConnection,
           state == .connecting || state == .connected {
            invalidateConnectionRequest()
            cancelConnectionWatchdog()
            cancelConnectionReadiness()
            beginDisconnectionWatchdog()
            manager?.connection.stopVPNTunnel()
            state = .disconnecting
            connectedSince = nil
            sessionRoutingMode = nil
            sessionNetworkEngineMode = nil
            clearProxySelectionRuntimeState()
            return
        }
        if case .failed = state, failureContext == nil {
            failureContext = .provider
        }
        if status == .connected {
            connectedSince = manager?.connection.connectedDate ?? connectedSince ?? .now
            let provider = manager?.protocolConfiguration as? NETunnelProviderProtocol
            do {
                sessionRoutingMode = try TunnelProviderConfigurationCodec.routingMode(
                    from: provider?.providerConfiguration
                )
                sessionNetworkEngineMode = NetworkEngineMode(
                    providerBundleIdentifier: provider?.providerBundleIdentifier
                )
            } catch {
                manager?.connection.stopVPNTunnel()
                connectedSince = nil
                sessionRoutingMode = nil
                sessionNetworkEngineMode = nil
                recordFailure(error, context: .configuration)
            }
            if state == .connected {
                isVerifyingProxyReadiness = false
                startTelemetryPollingIfNeeded()
            } else if let connectionID = providerConnectionID {
                startConnectionReadinessCheck(
                    groups: readinessGroups,
                    connectionID: connectionID
                )
            }
            return
        }

        cancelConnectionReadiness()
        switch state {
        case .disconnected, .failed:
            connectedSince = nil
            sessionRoutingMode = nil
            sessionNetworkEngineMode = nil
            clearProxySelectionRuntimeState()
        case .privacyConsentRequired, .loading, .connecting, .connected,
             .disconnecting:
            break
        }
    }

    @discardableResult
    private func ensurePrivacyConsent() -> Bool {
        let isAccepted = isUIReviewMode
            ? hasAcceptedPrivacyDisclosure
            : privacyConsentStore.hasAcceptedCurrentDisclosure
        guard isAccepted else {
            hasAcceptedPrivacyDisclosure = false
            state = .privacyConsentRequired
            return false
        }
        hasAcceptedPrivacyDisclosure = true
        return true
    }

    private static let networkEnginePreferenceKey =
        "AetherRoute.NetworkEngineMode"
    private static let defaultLatencyTestURL =
        "https://www.gstatic.com/generate_204"

    private func persistBypassPolicy(_ policy: BypassPolicy) async throws {
        let policy = try policy.validated()
        if !isUIReviewMode {
            try await Task.detached(priority: .userInitiated) {
                try BypassPolicyStore.applicationGroup().save(policy)
            }.value
        }
        bypassPolicy = policy
        hasLoadedBypassPolicy = true
    }

#if DEBUG || AETHERROUTE_PERFORMANCE_MEASUREMENT || AETHERROUTE_UI_RESPONSIVENESS || AETHERROUTE_DEVELOPMENT_PREVIEW
    private func installReviewBypassPolicy() {
        let fixtureValues = [
            "*.apple.com",
            "192.0.2.0/24",
            "2001:db8::/48",
        ]
        let rules = fixtureValues.compactMap { try? BypassRule.parse($0) }
        assert(
            rules.count == fixtureValues.count,
            "UI review bypass fixtures must remain valid"
        )
        bypassPolicy = BypassPolicy(
            rules: rules
        )
        hasLoadedBypassPolicy = true
    }
#endif

    private func clearProxySelectionRuntimeState() {
        stopTelemetryPolling()
        proxySelections = [:]
        proxySelectionMessages = [:]
        proxySelectionRequests = []
        proxyLatencies = [:]
        proxyLatencyRequests = []
        telemetry = .empty
        telemetryUpdatedAt = nil
    }

    private func startConnectionReadinessCheck(
        groups: [ProxyGroupConfigurationSummary],
        connectionID: UUID
    ) {
        guard connectionReadinessTask == nil,
              !groups.isEmpty,
              providerConnectionID == connectionID else { return }
        isVerifyingProxyReadiness = true
        connectionStage = .readinessCheck
        Self.runtimeLogger.info(
            "stage=connectionReadiness begin groups=\(groups.count, privacy: .public)"
        )
        connectionReadinessTask = Task { [weak self] in
            await self?.verifyConnectionReadiness(
                groups: groups,
                connectionID: connectionID
            )
        }
    }

    private func verifyConnectionReadiness(
        groups: [ProxyGroupConfigurationSummary],
        connectionID: UUID
    ) async {
        defer {
            if providerConnectionID == connectionID {
                connectionReadinessTask = nil
            }
        }
        do {
            let client = ProxySelectionProviderClient { [weak self] data in
                guard let self else {
                    throw TunnelManagerError.providerSessionUnavailable
                }
                return try await self.sendProviderMessage(
                    data,
                    timeout: .seconds(25)
                )
            }
            for group in groups {
                try Task.checkCancellation()
                let latency = try await client.latency(
                    group: group.name,
                    url: Self.defaultLatencyTestURL,
                    timeoutMilliseconds: 3_000
                )
                guard providerConnectionID == connectionID else { return }
                proxyLatencies[group.name] = latency
                var snapshot = try await client.snapshot(group: group.name)
                guard let preferred = ProxyConnectionReadinessPolicy
                    .preferredMember(snapshot: snapshot, latency: latency) else {
                    throw TunnelManagerError.noResponsiveProxy
                }
                if snapshot.selectedMember != preferred {
                    snapshot = try await client.select(
                        group: group.name,
                        member: preferred
                    )
                }
                proxySelections[group.name] = snapshot
                if let yaml = activeProfile?.yaml {
                    try await Task.detached(priority: .utility) {
                        try ProxySelectionStore.applicationGroup()
                            .recordVerified(
                                snapshot: snapshot,
                                group: group.name,
                                profileYAML: yaml
                            )
                    }.value
                }
            }
            guard providerConnectionID == connectionID else { return }
            readinessVerifiedConnectionID = connectionID
            isVerifyingProxyReadiness = false
            state = .connected
            startTelemetryPollingIfNeeded()
            Self.runtimeLogger.info("stage=connectionReadiness success")
        } catch is CancellationError {
            Self.runtimeLogger.info("stage=connectionReadiness cancelled")
        } catch {
            guard providerConnectionID == connectionID else { return }
            Self.runtimeLogger.error(
                "stage=connectionReadiness failed error=\(String(reflecting: error), privacy: .public)"
            )
            isVerifyingProxyReadiness = false
            manager?.connection.stopVPNTunnel()
            recordFailure(error, context: .provider)
        }
    }

    private func cancelConnectionReadiness() {
        connectionReadinessTask?.cancel()
        connectionReadinessTask = nil
        isVerifyingProxyReadiness = false
    }

    private func resetConnectionReadiness() {
        cancelConnectionReadiness()
        providerConnectionID = nil
        readinessVerifiedConnectionID = nil
        lastObservedProviderStatus = nil
    }

    private func resetManagerScopedLifecycleState() {
        disconnectErrorLookupID = nil
        resetConnectionReadiness()
    }

    private func beginConnectionRequest() -> UUID {
        let requestID = UUID()
        connectionRequestID = requestID
        Self.runtimeLogger.info("stage=connectionRequest began")
        return requestID
    }

    private func invalidateConnectionRequest() {
        if connectionRequestID != nil {
            Self.runtimeLogger.info("stage=connectionRequest invalidated")
        }
        connectionRequestID = nil
    }

    private func completeConnectionRequest(_ requestID: UUID) {
        guard connectionRequestID == requestID else { return }
        connectionRequestID = nil
        Self.runtimeLogger.info("stage=connectionRequest completed")
    }

    private func isCurrentConnectionRequest(_ requestID: UUID) -> Bool {
        connectionRequestID == requestID
    }

    private func shouldContinueConnectionPreparation(
        _ requestID: UUID
    ) -> Bool {
        TunnelLifecycleTransitionPolicy.shouldContinueConnectionPreparation(
            generationMatches: isCurrentConnectionRequest(requestID),
            hostIsConnecting: state == .connecting,
            providerPermitsStart: managerConnectionPermitsStart
        )
    }

    private func handleUnexpectedProviderTermination(
        _ connection: NEVPNConnection
    ) {
        let lookupID = UUID()
        disconnectErrorLookupID = lookupID
        cancelConnectionReadiness()
        connectedSince = nil
        sessionRoutingMode = nil
        sessionNetworkEngineMode = nil
        clearProxySelectionRuntimeState()
        recordFailure(
            LocalizedConnectionError(
                message: AppLocalization.string(
                    "The network extension stopped before it became ready. Another active proxy or VPN may be using the required network channel, or the active profile may have failed. Turn off conflicting network extensions, then retry."
                )
            ),
            context: .provider
        )
        connection.fetchLastDisconnectError { [weak self] error in
            let nsError = error as NSError?
            let kind = ProviderDisconnectErrorClassifier.classify(nsError)
            let domain = nsError?.domain ?? "none"
            let code = nsError?.code ?? 0
            Task { @MainActor [weak self] in
                self?.applyDisconnectError(
                    kind,
                    domain: domain,
                    code: code,
                    lookupID: lookupID
                )
            }
        }
    }

    private func applyDisconnectError(
        _ kind: ProviderDisconnectErrorKind,
        domain: String,
        code: Int,
        lookupID: UUID
    ) {
        guard disconnectErrorLookupID == lookupID else {
            Self.runtimeLogger.info(
                "stage=disconnectError ignored reason=stale"
            )
            return
        }
        disconnectErrorLookupID = nil
        Self.runtimeLogger.error(
            "stage=disconnectError resolved domain=\(domain, privacy: .public) code=\(code, privacy: .public) classification=\(String(describing: kind), privacy: .public)"
        )
        guard kind == .competingNetworkExtension else { return }
        diagnosticEvents.record(.networkExtensionConflict)
        failureContext = .provider
        state = .failed(
            AppLocalization.string(
                "Another network extension is already controlling this traffic. Turn off the conflicting proxy or VPN extension, then retry."
            )
        )
    }

    private static func isTerminalProviderStatus(_ status: NEVPNStatus) -> Bool {
        status == .invalid || status == .disconnected
    }

    /// Narrows the provider status to the phases the stage policy reasons
    /// about, so the policy itself stays free of NetworkExtension types.
    private static func providerLifecyclePhase(
        _ status: NEVPNStatus?
    ) -> ProviderLifecyclePhase {
        switch status {
        case nil, .invalid, .disconnected, .disconnecting: .inactive
        case .connecting, .reasserting: .starting
        case .connected: .established
        @unknown default: .inactive
        }
    }

    private static func isActiveProviderStatus(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connecting, .connected, .reasserting, .disconnecting:
            true
        case .invalid, .disconnected:
            false
        @unknown default:
            true
        }
    }

    private func recordFailure(
        _ error: Error,
        context: ConnectionFailureContext
    ) {
        Self.runtimeLogger.error(
            "stage=recordFailure context=\(String(describing: context), privacy: .public) error=\(String(reflecting: error), privacy: .public)"
        )
        invalidateConnectionRequest()
        cancelConnectionWatchdog()
        cancelDisconnectionWatchdog()
        failureContext = context
        state = .failed(error.localizedDescription)
    }

    /// A provider that never reaches a terminal Network Extension state must
    /// not leave the host UI in an unbounded ``Connecting`` state. The
    /// watchdog is armed only after configuration and runtime resources have
    /// been persisted, immediately before the OS start request.
    private func beginConnectionWatchdog() {
        cancelConnectionWatchdog()
        let attemptID = UUID()
        connectionAttemptID = attemptID
        Self.runtimeLogger.info(
            "stage=connectionWatchdog armed timeoutSeconds=\(TunnelStartupTimingPolicy.hostConnectionWatchdogTimeoutSeconds, privacy: .public)"
        )
        connectionWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: TunnelStartupTimingPolicy.hostConnectionWatchdogTimeout
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.connectionWatchdogFired(attemptID)
        }
    }

    private func cancelConnectionWatchdog() {
        if connectionWatchdogTask != nil {
            Self.runtimeLogger.info("stage=connectionWatchdog cancelled")
        }
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = nil
        connectionAttemptID = nil
    }

    private func beginDisconnectionWatchdog() {
        cancelDisconnectionWatchdog()
        let attemptID = UUID()
        disconnectionAttemptID = attemptID
        Self.runtimeLogger.info(
            "stage=disconnectionWatchdog armed timeoutSeconds=\(TunnelStartupTimingPolicy.hostDisconnectionWatchdogTimeoutSeconds, privacy: .public)"
        )
        disconnectionWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: TunnelStartupTimingPolicy
                        .hostDisconnectionWatchdogTimeout
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.disconnectionWatchdogFired(attemptID)
        }
    }

    private func cancelDisconnectionWatchdog() {
        if disconnectionWatchdogTask != nil {
            Self.runtimeLogger.info(
                "stage=disconnectionWatchdog cancelled"
            )
        }
        disconnectionWatchdogTask?.cancel()
        disconnectionWatchdogTask = nil
        disconnectionAttemptID = nil
    }

    private func disconnectionWatchdogFired(_ attemptID: UUID) {
        guard disconnectionAttemptID == attemptID,
              case .disconnecting = state else {
            Self.runtimeLogger.info(
                "stage=disconnectionWatchdog ignored reason=stale"
            )
            return
        }
        Self.runtimeLogger.error("stage=disconnectionWatchdog fired")
        reconcileDisconnectionStatus()
        let resolution = TunnelLifecycleTransitionPolicy
            .disconnectionWatchdogResolution(
                hostIsDisconnectingAfterReconciliation: state == .disconnecting
            )
        guard resolution == .timedOut else {
            cancelDisconnectionWatchdog()
            return
        }
        cancelDisconnectionWatchdog()
        recordFailure(
            LocalizedConnectionError(
                message: AppLocalization.string(
                    "The network extension did not finish stopping. Wait a moment, then retry; macOS will update the status when shutdown completes."
                )
            ),
            context: .provider
        )
    }

    private func reconcileDisconnectionStatus() {
        guard let status = manager?.connection.status else {
            state = .disconnected
            return
        }
        Self.runtimeLogger.info(
            "stage=reconcileDisconnection status=\(status.rawValue, privacy: .public)"
        )
        if status == .invalid || status == .disconnected {
            updateState()
        } else {
            state = .disconnecting
        }
    }

    private func connectionWatchdogFired(_ attemptID: UUID) {
        guard connectionAttemptID == attemptID,
              case .connecting = state else {
            Self.runtimeLogger.info("stage=connectionWatchdog ignored reason=stale")
            return
        }
        Self.runtimeLogger.error("stage=connectionWatchdog fired")
        cancelConnectionWatchdog()
        manager?.connection.stopVPNTunnel()
        invalidateCachedManager()
        recordFailure(
            LocalizedConnectionError(
                message: AppLocalization.string(
                    "The network extension stopped before it could report ready. Retry once, then review the active profile."
                )
            ),
            context: .provider
        )
    }

    private func localizedConnectionError(_ error: Error) -> Error {
        guard let resourceError = error as? RoutingResourceError else {
            return error
        }
        let message: String
        switch resourceError {
        case let .missing(kind):
            message = String.localizedStringWithFormat(
                AppLocalization.string(
                    "%@ is required by this profile. Add it in Profiles before connecting."
                ),
                kind.fileName
            )
        case let .stale(kind, _):
            message = String.localizedStringWithFormat(
                AppLocalization.string(
                    "%@ is more than 30 days old. Update it in Profiles before connecting."
                ),
                kind.fileName
            )
        case let .checksumMismatch(kind),
             let .invalidResourceFormat(kind),
             let .metadataDateInFuture(kind),
             let .metadataEncodingFailed(kind),
             let .metadataUnreadable(kind),
             let .metadataTooLarge(kind),
             let .metadataMismatch(kind):
            message = String.localizedStringWithFormat(
                AppLocalization.string(
                    "%@ failed validation. Replace it in Profiles before connecting."
                ),
                kind.fileName
            )
        case let .resourceTooSmall(kind, _),
             let .resourceTooLarge(kind, _):
            message = String.localizedStringWithFormat(
                AppLocalization.string(
                    "%@ has an invalid size. Replace it in Profiles before connecting."
                ),
                kind.fileName
            )
        default:
            message = AppLocalization.string(
                "Routing resources could not be prepared securely. Review them in Profiles before connecting."
            )
        }
        return LocalizedConnectionError(message: message)
    }

    private func localizedRoutingResourceOperationError(
        _ error: Error
    ) -> String {
        localizedConnectionError(error).localizedDescription
    }

    private var runtimeConnectionActivity: RuntimeConnectionActivity {
        switch state {
        case .connecting, .disconnecting:
            .transitioning
        case .connected:
            .connected
        case .privacyConsentRequired, .loading, .disconnected, .failed:
            .inactive
        }
    }

    private var diagnosticEngine: DiagnosticReport.Engine {
        switch sessionNetworkEngineMode ?? networkEngineMode {
        case .transparent: .transparentProxy
#if AETHERROUTE_INDEPENDENT
        case .tun: .packetTunnel
#endif
        }
    }

    private static func diagnosticEventCode(
        for state: State
    ) -> DiagnosticEventCode {
        switch state {
        case .privacyConsentRequired: .privacyRequired
        case .loading: .preparing
        case .disconnected: .disconnected
        case .connecting: .connectRequested
        case .connected: .providerReady
        case .disconnecting: .disconnectRequested
        case .failed: .providerFailed
        }
    }

    private static func diagnosticState(
        for state: State
    ) -> DiagnosticReport.SessionState {
        switch state {
        case .privacyConsentRequired: .privacyRequired
        case .loading: .loading
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .disconnecting: .disconnecting
        case .failed: .failed
        }
    }

    private static var diagnosticArchitecture: String {
#if arch(arm64)
        "arm64"
#else
        "unsupported"
#endif
    }

    private static var diagnosticDistribution: DiagnosticReport.Distribution {
        .independent
    }
}

private extension RuntimeEnvironmentEvent {
    var diagnosticEventCode: DiagnosticEventCode {
        switch self {
        case .systemWillSleep: .systemSleep
        case .systemDidWake: .systemWake
        case .networkPathChanged: .networkPathChanged
        }
    }
}

private enum TunnelManagerError: LocalizedError, Sendable, Equatable {
    case invalidProtocolConfiguration
    case duplicateConfigurations
    case configurationDidNotPersist
    case providerMessageTimedOut
    case providerReplyMissing
    case providerSelectorUnavailable
    case providerSessionUnavailable
    case noResponsiveProxy

    var errorDescription: String? {
        switch self {
        case .invalidProtocolConfiguration:
            AppLocalization.string("The saved network extension configuration is invalid.")
        case .duplicateConfigurations:
            AppLocalization.string("Multiple AetherRoute network extension configurations were found. Remove the duplicate in System Settings and try again.")
        case .configurationDidNotPersist:
            AppLocalization.string("The selected routing mode could not be saved to the network extension configuration.")
        case .providerMessageTimedOut:
            AppLocalization.string("The network extension did not answer the proxy selection request in time.")
        case .providerReplyMissing:
            AppLocalization.string("The network extension returned no proxy selection response.")
        case .providerSelectorUnavailable:
            AppLocalization.string("This profile does not expose selectable proxy members.")
        case .providerSessionUnavailable:
            AppLocalization.string("Connect the network extension before selecting a proxy.")
        case .noResponsiveProxy:
            AppLocalization.string("No proxy node in the active route passed the connection check.")
        }
    }
}

private final class ProviderMessageReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func receive(_ data: Data?) {
        guard let data else {
            fail(TunnelManagerError.providerReplyMissing)
            return
        }
        finish(.success(data))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    func startTimeout(after timeout: Duration) {
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(for: timeout)
            fail(TunnelManagerError.providerMessageTimedOut)
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}
