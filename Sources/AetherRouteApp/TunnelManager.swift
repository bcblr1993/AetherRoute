import AetherRouteKit
import Foundation
import Network
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

struct ProfileCatalogProjection: Sendable {
    let catalog: ProfileCatalog
    let summary: ProfileConfigurationSummary?
    let dnsPolicy: DNSRuntimePolicy
    let dnsErrorDescription: String?
}

enum ProfileCatalogProjectionBuilder {
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

struct ProductionStartupState: Sendable {
    let bypassPolicy: BypassPolicy?
    let profileProjection: ProfileCatalogProjection
}

struct LocalizedConnectionError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

enum ProductionStartupLoader {
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

/// Publishes high-frequency traffic counters independently from the host
/// lifecycle model. Keeping this object separate prevents every telemetry
/// sample from invalidating the complete navigation, icon and panel tree.
@MainActor
final class NetworkTelemetryViewModel: ObservableObject {
    @Published var snapshot: NetworkTelemetrySnapshot = .empty
    private(set) var history = TrafficHistory()

    func update(_ snapshot: NetworkTelemetrySnapshot) {
        history.append(
            download: Double(snapshot.downloadBytesPerSecond),
            upload: Double(snapshot.uploadBytesPerSecond),
            at: Date()
        )
        // One publication for both current values and the timestamped history.
        self.snapshot = snapshot
    }

    func reset() {
        history = TrafficHistory()
        snapshot = .empty
    }

}

@MainActor
final class TunnelManager: ObservableObject {
    static let runtimeLogger = AppLog.logger(category: AppLog.Category.appRuntime)

    enum State: Equatable {
        case privacyConsentRequired
        case loading
        case disconnected
        case connecting
        case connected
        case recovering
        case disconnecting
        case failed(String)
    }

    /// Route quality for a tunnel that is already up and carrying traffic.
    /// Defined in `AetherRouteKit` so the decision behind it is unit-testable
    /// alongside the other connection policies.
    typealias ConnectionQuality = AetherRouteKit.ConnectionQuality

    @Published var state: State = .loading {
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
    @Published var distributionConnectionAccess:
        DistributionConnectionAccess = .unrestrictedDevelopment
    @Published var profiles: [ManagedProfile] = []
    @Published var activeProfileID: UUID?
    @Published var activeProfile: ActiveProfile?
    @Published var activeProfileSummary: ProfileConfigurationSummary?
    @Published var profileMessage: String?
    @Published var profileMessageIsError = false
    @Published var pendingExternalSubscription:
        ExternalSubscriptionImportRequest?
    @Published var externalSubscriptionLinkError: String?
    @Published var bypassPolicy: BypassPolicy = .empty
    @Published var bypassPolicyMessage: String?
    @Published var bypassPolicyMessageIsError = false
    @Published var dnsRuntimePolicy: DNSRuntimePolicy = .inherited
    @Published var dnsRuntimePolicyMessage: String?
    @Published var dnsRuntimePolicyMessageIsError = false
    @Published var isRefreshingSubscription = false
    @Published var isImportingProfile = false
    @Published var isUpdatingProfiles = false
    @Published var isUpdatingBypassPolicy = false
    @Published var isUpdatingDNSRuntimePolicy = false
    @Published var isUpdatingRoutingMode = false
    @Published var routingModeMessage: String?
    @Published var routingModeMessageIsError = false
    @Published var isSwitchingNetworkEngine = false
    @Published var isDomesticOptimizationEnabled: Bool
    let engineReconnect = NetworkEngineReconnectCoordinator()
    @Published var networkEngineMessage: String?
    @Published var networkEngineMessageIsError = false
    @Published var isTransferringProfiles = false
    @Published var routingResourceStatuses:
        [RoutingResourceKind: RoutingResourceStatus] = [:]
    @Published var isUpdatingRoutingResources = false
    @Published var routingResourceMessage: String?
    @Published var routingResourceMessageIsError = false
    @Published var hasAcceptedPrivacyDisclosure: Bool
    @Published var connectedSince: Date?
    @Published var sessionRoutingMode: RoutingMode?
    @Published var sessionNetworkEngineMode: NetworkEngineMode?
    /// Connections requested per telemetry poll. The snapshot truncates to this
    /// limit, so the diagnostic report needs the same number to tell a real
    /// count from a saturated one.
    static let telemetryConnectionLimit: UInt16 = 50

    @Published var networkEngineMode: NetworkEngineMode
    @Published var systemExtensionApprovalRequired = false
    @Published var proxySelections: [String: ProxySelectionState] = [:]
    @Published var proxySelectionMessages: [String: String] = [:]
    @Published var proxySelectionRequests: Set<String> = []
    @Published var automaticProxySelectionGroups: Set<String> = []
    @Published var proxyLatencies: [String: ProxyLatencyState] = [:]
    @Published var proxyLatencyRequests: Set<String> = []
    @Published var memberLatencyRequests: Set<String> = []

    /// Staging area behind `proxyLatencies`. Merging one result is O(1) here;
    /// the published arrays are rebuilt once per flush window instead of once
    /// per arriving result.
    var latencyIndex = ProxyLatencyIndex()
    /// The profile the index was built for. A profile switch resets the index
    /// so a member name reused by the new profile never inherits an old
    /// number.
    var latencyIndexToken: LatencyRunToken?
    var pendingLatencyFlush: Set<String> = []
    var lastLatencyFlushAt: ContinuousClock.Instant?
    var latencyFlushTask: Task<Void, Never>?

    @Published var isAutomaticRouteRecovering = false
    @Published var isVerifyingProxyReadiness = false
    /// Quality of the route behind an already-usable tunnel. The tunnel being
    /// up and the selected route being fast are two different questions; this
    /// reports the second without gating the first.
    @Published var connectionQuality: ConnectionQuality = .unknown
    @Published var connectionStage: ConnectionStage = .systemAuthorization
    let telemetryViewModel = NetworkTelemetryViewModel()
    var telemetry: NetworkTelemetrySnapshot { telemetryViewModel.snapshot }
    var telemetryUpdatedAt: Date?
    var realtimeTelemetrySources: Set<String> = []
    @Published var isRealtimeTelemetryPreferred = false

    /// Registers or unregisters demand for high-frequency (3s) telemetry.
    /// When any source demands realtime telemetry, the polling interval switches to 3s
    /// and immediately triggers a refresh; when all sources clear, it drops back to 10s.
    @Published var localProxySettings: LocalProxySettings
    @Published var localProxySettingsMessage: String? = nil
    @Published var routingMode: RoutingMode {
        didSet {
            guard persistsRoutingModeSelection else { return }
            routingModePreferenceStore.save(routingMode)
        }
    }

    let isUIReviewMode: Bool
    /// Captured at init so QA automation reads the same environment the rest
    /// of the fixture hooks do, and so tests can inject one.
    let qaAutomationEnvironment: [String: String]
    let privacyConsentStore: PrivacyConsentStore
    let routingModePreferenceStore: RoutingModePreferenceStore
    let localProxySettingsStore: LocalProxySettingsStore
    let userDefaults: UserDefaults
    let subscriptionClient: ProfileSubscriptionClient
    let routingResourceDownloadClient: RoutingResourceDownloadClient
    let systemExtensionActivator: any SystemExtensionActivating
    let routingResourceStoreFactory:
        @Sendable () throws -> RoutingResourceStore
    let diagnosticEvents = DiagnosticEventBuffer()
    var manager: NEVPNManager?
    var statusObserver: NSObjectProtocol?
    var configurationObserver: NSObjectProtocol?
    nonisolated(unsafe) var cloudSyncObserver: (any NSObjectProtocol)?
    var isPreparing = false
    var isPersistingConfiguration = false
    var isReloadingConfiguration = false
    var persistsRoutingModeSelection = false
    var hasLoadedBypassPolicy = false
    var telemetryPollingTask: Task<Void, Never>?
    var runtimeEnvironmentResetTask: Task<Void, Never>?
    var automaticReadinessGroupNames: Set<String> = []
    var automaticReadinessChildGroups: [String: String] = [:]
    var automaticRouteFailureCounts: [String: Int] = [:]
    var profileImportTask: Task<Void, Never>?
    var routingResourceStatusTask: Task<Void, Never>?
    var routingResourceRefreshTask: Task<Void, Never>?
    var lastAutomaticResourceRefreshAttempt: Date?
    let bundledResourceDirectoryURL = Bundle.main.resourceURL?
        .appendingPathComponent("RoutingResources", isDirectory: true)
    var connectionWatchdogTask: Task<Void, Never>?
    var disconnectionWatchdogTask: Task<Void, Never>?
    var recoveryWatchdogTask: Task<Void, Never>?
    var connectionReadinessTask: Task<Void, Never>?
    var connectionRequestID: UUID?
    var connectionAttemptID: UUID?
    var disconnectionAttemptID: UUID?
    var recoveryAttemptID: UUID?
    /// Whether the disconnection the watchdog is guarding is one *we* asked
    /// for.
    ///
    /// The watchdog is armed from two very different places: a stop this host
    /// initiated, and a `.disconnecting` status the provider reported on its
    /// own. Both used to set `disconnectionAttemptID` alone, which made the
    /// second case indistinguishable from the first — so a provider killed by
    /// macOS looked like a user-requested disconnect and
    /// `handleUnexpectedProviderTermination` was skipped entirely.
    var disconnectionWasSelfInitiated = false
    /// Reconnects attempted since the last successful connection. Reset when
    /// the tunnel connects or the user takes over.
    var automaticReconnectAttempt = 0
    var automaticReconnectTask: Task<Void, Never>?
    /// The user's standing intent to be connected.
    ///
    /// Distinct from `isEnabled`, which is derived from the current provider
    /// status and therefore goes false the instant the tunnel drops — exactly
    /// when a reconnect needs to know whether the user still wants one.
    var userIntendsToConnect = false
    let connectionIntentStore: ConnectionIntentStore
    var isApplicationTerminating = false
    var providerConnectionID: UUID?
    var readinessVerifiedConnectionID: UUID?
    var readinessFailureStopPending = false
    var lastObservedProviderStatus: NEVPNStatus?
    var disconnectErrorLookupID: UUID?
    var failureContext: ConnectionFailureContext?
    var isSystemSleeping = false
    var lastSystemWakeAt: Date = .distantPast
    let wakeGracePeriodDuration: TimeInterval = 20.0

    var isInWakeGracePeriod: Bool {
        isSystemSleeping || Date().timeIntervalSince(lastSystemWakeAt) < wakeGracePeriodDuration
    }

    var wasConnectedBeforeTermination: Bool {
        connectionIntentStore.wasConnected
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        privacyConsentStore: PrivacyConsentStore = PrivacyConsentStore(),
        routingModePreferenceStore: RoutingModePreferenceStore =
            RoutingModePreferenceStore(),
        connectionIntentStore: ConnectionIntentStore? = nil,
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
        self.qaAutomationEnvironment = environment
        self.privacyConsentStore = privacyConsentStore
        self.routingModePreferenceStore = routingModePreferenceStore
        self.connectionIntentStore = connectionIntentStore ?? ConnectionIntentStore(defaults: userDefaults)
        self.userDefaults = userDefaults
        self.subscriptionClient = subscriptionClient
        self.routingResourceDownloadClient = routingResourceDownloadClient
        self.systemExtensionActivator = systemExtensionActivator
        self.routingResourceStoreFactory = routingResourceStoreFactory
        localProxySettingsStore = LocalProxySettingsStore(defaults: userDefaults)
        localProxySettings = localProxySettingsStore.load()
        self.isDomesticOptimizationEnabled = DomesticRoutingOptimizer.isEnabled

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
                if reviewState == "extension-approval" {
                    systemExtensionApprovalRequired = true
                    failureContext = .configuration
                    state = .failed(AppLocalization.string(
                        "Approve the AetherRoute network extension to continue."
                    ))
                } else {
                    state = .disconnected
                }
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
            case "recovering": .recovering
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
            connectedSince = state == .connected || state == .recovering
                ? Date(timeIntervalSince1970: 1_775_003_600)
                : nil
            sessionRoutingMode = state == .connected || state == .recovering ? routingMode : nil
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

        cloudSyncObserver = NotificationCenter.default.addObserver(
            forName: .aetherRouteCloudSyncDidUpdateProfiles,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isUIReviewMode else { return }
                do {
                    let catalog = try ProfileCatalogStore.applicationGroup().loadOrMigrate()
                    await self.applyProductionProfileCatalog(catalog)
                } catch {
                    Self.runtimeLogger.error(
                        "stage=cloudSyncReload failed error=\(String(reflecting: error), privacy: .public)"
                    )
                }
            }
        }
    }

    deinit {
        if let cloudSyncObserver {
            NotificationCenter.default.removeObserver(cloudSyncObserver)
        }
    }

    func acceptPrivacyDisclosure() async {
        if !isUIReviewMode {
            privacyConsentStore.acceptCurrentDisclosure()
        }
        hasAcceptedPrivacyDisclosure = true
        state = isUIReviewMode ? .disconnected : .loading
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
            await deactivateOpposingNetworkEngineManagers(for: networkEngineMode)
            installManager(try await loadOrCreateManager())
            observeConfigurationChanges()
            updateState()
            if state == .disconnected {
                await refreshSubscriptionIfDue()
            }
            isPreparing = false
            await restorePreviousConnectionIfRequested()
            await connectForQAAutomationIfRequested()
        } catch {
            systemExtensionApprovalRequired = false
            recordFailure(error, context: .configuration)
        }
    }

    private func restorePreviousConnectionIfRequested() async {
        guard !isUIReviewMode else { return }
#if AETHERROUTE_QA_AUTOMATION
        if qaAutomationEnvironment["AETHERROUTE_QA_AUTOCONNECT"] == "0" {
            Self.runtimeLogger.info(
                "stage=startup autoReconnect skipped reason=qaAutomationAutoconnectDisabled"
            )
            return
        }
#endif
        guard wasConnectedBeforeTermination else { return }
        guard state == .disconnected else { return }
        guard canRestorePreviousConnection else {
            Self.runtimeLogger.info(
                "stage=startup autoReconnect skipped reason=cannotConnect isPreparing=\(self.isPreparing, privacy: .public) profile=\(self.activeProfile != nil, privacy: .public) approvalRequired=\(self.systemExtensionApprovalRequired, privacy: .public) permitsStart=\(self.managerConnectionPermitsStart, privacy: .public)"
            )
            return
        }
        Self.runtimeLogger.info(
            "stage=startup autoReconnect restoring previous connection"
        )
        await setEnabled(true)
    }

    private var canRestorePreviousConnection: Bool {
#if AETHERROUTE_DEVELOPMENT_PREVIEW
        false
#else
        hasAcceptedPrivacyDisclosure
            && activeProfile != nil
            && distributionConnectionAccess.permitsNewConnection
            && !systemExtensionApprovalRequired
            && managerConnectionPermitsStart
            && !managerConnectionIsTransitioning
            && !isTransitioning
            && !isImportingProfile
            && !isUpdatingProfiles
            && !isUpdatingRoutingResources
            && !isUpdatingBypassPolicy
            && !isUpdatingDNSRuntimePolicy
            && !isUpdatingRoutingMode
            && !isSwitchingNetworkEngine
            && proxySelectionRequests.isEmpty
#endif
    }

    /// Starts the tunnel without UI so an acceptance run can be unattended.
    ///
    /// Starting a Packet Tunnel needs the launch snapshot that only this app
    /// can build, so there is no command-line path to a connected tunnel and
    /// every verification otherwise stops for a human click. This closes that
    /// gap for QA builds only, behind two independent gates:
    ///
    /// 1. `AETHERROUTE_QA_AUTOMATION` must be compiled in. It is set by
    ///    `build_signed_local_test_candidate.sh` and rejected outright by
    ///    `guard_developer_id_network_extension_build.sh` for the stable
    ///    channel, so notarized and release builds cannot contain this code.
    /// 2. `AETHERROUTE_QA_AUTOCONNECT=1` must be in the environment, so even a
    ///    QA build behaves normally when a person launches it by hand.
    ///
    /// Both gates are required. Neither is reachable from a shipped build.
    private func connectForQAAutomationIfRequested() async {
#if AETHERROUTE_QA_AUTOMATION
        if let localPath = qaAutomationEnvironment["AETHERROUTE_QA_PROFILE_PATH"], !localPath.isEmpty {
            let fileURL = URL(fileURLWithPath: localPath)
            Self.runtimeLogger.info(
                "stage=qaAutomation localProfile requested path=\(localPath, privacy: .public)"
            )
            importProfile(from: fileURL)
        } else if let subURL = qaAutomationEnvironment["AETHERROUTE_QA_SUBSCRIPTION_URL"], !subURL.isEmpty {
            Self.runtimeLogger.info(
                "stage=qaAutomation autoImport requested url=\(subURL.sanitizedURLForLogging, privacy: .private)"
            )
            _ = await addSubscription(urlText: subURL)
        }
        guard qaAutomationEnvironment["AETHERROUTE_QA_AUTOCONNECT"] == "1",
              state == .disconnected else { return }
        Self.runtimeLogger.info(
            "stage=qaAutomation autoConnect requested engine=\(self.networkEngineMode.rawValue, privacy: .public)"
        )
        await setEnabled(true)
#endif
    }

    /// Re-runs preparation after the user returns from System Settings. When
    /// the original activation request is still pending, `prepare()` safely
    /// coalesces this call through `isPreparing`; macOS will complete that
    /// request as soon as approval is granted.
    func recheckSystemExtensionApproval() async {
        guard systemExtensionApprovalRequired else { return }
        await prepare()
    }

    func rejectDevelopmentPreviewStart() -> Bool {
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
        await setEnabled(enabled, isAutomaticReconnect: false)
    }

    /// - Parameter isAutomaticReconnect: distinguishes a reconnect this manager
    ///   scheduled from a connect the user asked for. Only the latter restores
    ///   the retry budget; a reconnect that reset it would retry forever. This
    ///   travels as an argument rather than an instance flag because the body
    ///   suspends, and a flag could be read by a user-driven call that
    ///   interleaved with this one.
    func setEnabled(
        _ enabled: Bool,
        isAutomaticReconnect: Bool
    ) async {
        Self.runtimeLogger.info(
            "stage=setEnabled request=\(enabled ? "connect" : "disconnect", privacy: .public) state=\(Self.diagnosticEventCode(for: self.state).rawValue, privacy: .public) engine=\(self.networkEngineMode.rawValue, privacy: .public) routing=\(self.routingMode.rawValue, privacy: .public)"
        )
        if !enabled {
            engineReconnect.cancel()
            // Invalidate before any guard or await. A connect request may still
            // be preparing resources even though NetworkExtension has not
            // received startVPNTunnel yet.
            invalidateConnectionRequest()
            // The user is taking over. No scheduled reconnect may outlive this,
            // or the tunnel would come back up after they asked for it down.
            userIntendsToConnect = false
            cancelAutomaticReconnect(reason: "userDisconnected")
            if !isApplicationTerminating && !isUIReviewMode {
                connectionIntentStore.save(intendedConnected: false)
            }
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
            // An explicit connect supersedes any reconnect still waiting out
            // its delay, and restores the full retry budget for the next drop.
            userIntendsToConnect = true
            if !isUIReviewMode {
                connectionIntentStore.save(intendedConnected: true)
            }
            if !isAutomaticReconnect {
                cancelAutomaticReconnect(reason: "userConnected")
                automaticReconnectAttempt = 0
            }
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
            cancelDisconnectionWatchdog()
            cancelRecoveryWatchdog()
            cancelConnectionReadiness()
            guard state == .connected || state == .connecting || state == .recovering else {
                Self.runtimeLogger.info("stage=setEnabled ignored reason=notActive")
                return
            }
            state = .disconnecting
            beginDisconnectionWatchdog(selfInitiated: true)
        }
        let requestedMode = routingMode
        var launchSnapshot: ProviderLaunchSnapshot?
        var launchPayload: Data?

        do {
            if enabled {
                let (snapshot, payload) = try await prepareLaunchSnapshotPayload(
                    requestedMode: requestedMode
                )
                guard let requestID,
                      shouldContinueConnectionPreparation(requestID) else {
                    Self.runtimeLogger.info(
                        "stage=setEnabled stopped reason=staleAfterRuntimeResources"
                    )
                    return
                }
                launchSnapshot = snapshot
                launchPayload = payload
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
                guard let launchSnapshot, let launchPayload,
                      let session = manager.connection
                        as? NETunnelProviderSession else {
                    throw TunnelManagerError.providerSessionUnavailable
                }
                let options: [String: NSObject] = [
                    ProviderLaunchSnapshotCodec.startOptionsKey: launchPayload as NSData
                ]
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
            cancelRecoveryWatchdog()
            invalidateCachedManager()
            let context: ConnectionFailureContext
            if (error as? ActiveProfileStoreError) == .noActiveProfile {
                context = .missingProfile
            } else if error is RoutingResourceError
                        || error is BundledRoutingResourceError
                        || (error as? ActiveProfileStoreError)
                            == .appGroupUnavailable
                        || error is ProfileKeyStoreError
                        || error is KeychainAccessGroupResolutionError {
                context = .configuration
            } else {
                context = .provider
            }
            recordFailure(error, context: context)
        }
    }

    func prepareLaunchSnapshotPayload(
        requestedMode: RoutingMode
    ) async throws -> (ProviderLaunchSnapshot, Data) {
        guard let activeProfile else {
            throw ActiveProfileStoreError.noActiveProfile
        }
        Self.runtimeLogger.info("stage=prepareRuntimeResources begin")
        isUpdatingRoutingResources = true
        defer { isUpdatingRoutingResources = false }
        let rawProfileYAML = activeProfile.yaml
        let profileYAML = isDomesticOptimizationEnabled
            ? DomesticRoutingOptimizer.optimizedProfile(for: rawProfileYAML)
            : rawProfileYAML
#if AETHERROUTE_QA_AUTOMATION
        if let appGroupDir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroup)?
            .appendingPathComponent("Library/Application Support/AetherRoute", isDirectory: true) {
            try? FileManager.default.createDirectory(at: appGroupDir, withIntermediateDirectories: true)
            try? rawProfileYAML.write(to: appGroupDir.appendingPathComponent("debug_profile_raw.yaml"), atomically: true, encoding: .utf8)
            try? profileYAML.write(to: appGroupDir.appendingPathComponent("debug_profile_optimized.yaml"), atomically: true, encoding: .utf8)
        }
#endif
        let storeFactory = routingResourceStoreFactory
        let downloadClient = routingResourceDownloadClient
        let bundleDirectory = bundledResourceDirectoryURL
        let requestedBypassPolicy = bypassPolicy
        let requestedDNSPolicy = dnsRuntimePolicy
        let launchInput = try await Task.detached(
            priority: .userInitiated
        ) {
            let store = try storeFactory()
            let bundled = try BundledRoutingResources(
                directoryURL: bundleDirectory
            ).installMissingResources(for: profileYAML, in: store)
            let downloaded = try await downloadClient
                .ensureRequiredResources(
                    for: profileYAML,
                    in: store
                )
            try store.prepareRuntimeResources(for: profileYAML)
            let persistedSelections = try ProxySelectionStore
                .applicationGroup()
                .selections(forProfileYAML: rawProfileYAML)
            let profileSummary = ProfileConfigurationInspector.inspect(
                yaml: profileYAML
            )
            let initialSelections = InitialProxySelectionPolicy
                .selections(
                    persisted: persistedSelections,
                    summary: profileSummary
                )
            let snapshot = try ProviderLaunchSnapshot(
                profileYAML: profileYAML,
                routingMode: requestedMode,
                bypassPolicy: requestedBypassPolicy,
                dnsPolicy: requestedDNSPolicy,
                proxySelections: initialSelections,
                routingResources: try store.launchResourceSnapshot(for: profileYAML)
            )
            return (
                snapshot,
                try ProviderLaunchSnapshotCodec.encodedPayload(for: snapshot),
                bundled.union(downloaded)
            )
        }.value
        if !launchInput.2.isEmpty {
            routingResourceMessage = AppLocalization.string(
                "Routing rules are ready."
            )
            routingResourceMessageIsError = false
            refreshRoutingResourceStatuses()
        }
        Self.runtimeLogger.info("stage=prepareRuntimeResources success")
        return (launchInput.0, launchInput.1)
    }

    func reconnect() async {
        guard isConnected else {
            await setEnabled(true)
            return
        }
        await setEnabled(false)
        try? await Task.sleep(nanoseconds: 500_000_000)
        await setEnabled(true)
    }

    var requiredRoutingResources: [RoutingResourceKind] {
        guard let summary = activeProfileSummary else { return [] }
        return RoutingResourceKind.allCases.filter {
            summary.requiredRoutingResources.contains($0)
        }
    }

    func setDistributionConnectionAccess(
        _ access: DistributionConnectionAccess
    ) {
        guard access != distributionConnectionAccess else { return }
        distributionConnectionAccess = access
        guard !access.permitsNewConnection, isEnabled else { return }
        Task { await setEnabled(false) }
    }

    var requiresDisconnectBeforeApplicationTermination: Bool {
        managerConnectionIsActive
    }

    /// A VPN or transparent proxy must not outlive an intentional App quit.
    /// AppKit defers termination while this completes so NetworkExtension has
    /// time to restore the system route and DNS state. If shutdown does not
    /// settle, the delegate cancels termination instead of leaving an
    /// unmanaged network extension active in the background.
    func disconnectForApplicationTermination() async -> Bool {
        isApplicationTerminating = true
        let wasActive = managerConnectionIsActive || userIntendsToConnect
        if wasActive && !isUIReviewMode {
            connectionIntentStore.save(intendedConnected: true)
        }
        engineReconnect.cancel()
        userIntendsToConnect = false
        cancelAutomaticReconnect(reason: "applicationTermination")
        stopTelemetryPolling()
        cancelConnectionReadiness()
        runtimeEnvironmentResetTask?.cancel()
        runtimeEnvironmentResetTask = nil
        guard managerConnectionIsActive else { return true }
        Self.runtimeLogger.info(
            "stage=applicationTermination disconnect begin wasActive=\(wasActive, privacy: .public)"
        )
        await setEnabled(false)
        let stopped = await waitForProviderToBecomeInactive(
            timeout: .seconds(30)
        )
        Self.runtimeLogger.info(
            "stage=applicationTermination disconnect complete stopped=\(stopped, privacy: .public)"
        )
        return stopped
    }

    static let networkEngineSwitchSettleTimeout = Duration.seconds(10)
    static let networkEngineSwitchDrainTimeout = Duration.seconds(8)

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

    func setDomesticOptimizationEnabled(_ enabled: Bool) {
        isDomesticOptimizationEnabled = enabled
        DomesticRoutingOptimizer.setEnabled(enabled)
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

    func setRoutingMode(_ mode: RoutingMode) async {
        guard ensurePrivacyConsent(), canChangeRoutingMode else { return }
        guard mode != routingMode || sessionRoutingMode != mode else { return }

        if state != .connected {
            routingMode = mode
            sessionRoutingMode = nil
            routingModeMessage = nil
            routingModeMessageIsError = false
            return
        }

        isUpdatingRoutingMode = true
        routingModeMessage = nil
        defer { isUpdatingRoutingMode = false }
        let connectionID = providerConnectionID
        let previousMode = sessionRoutingMode ?? routingMode
        let client: ProxySelectionProviderClient? = isUIReviewMode
            ? nil
            : ProxySelectionProviderClient { [weak self] data in
                guard let self else {
                    throw TunnelManagerError.providerSessionUnavailable
                }
                return try await self.sendProviderMessage(data, for: connectionID)
            }
        do {
            let applied: RoutingMode
            if isUIReviewMode {
                applied = mode
            } else {
                guard let client else {
                    throw TunnelManagerError.providerSessionUnavailable
                }
                if mode == .global,
                   let summary = activeProfileSummary,
                   let primaryGroup = ProxyConnectionReadinessPolicy.groupsToVerify(summary: summary).first,
                   readinessVerifiedConnectionID == connectionID {
                    _ = try? await client.select(group: "GLOBAL", member: primaryGroup.name)
                }
                applied = try await client.setRoutingMode(mode)
            }
            guard state == .connected, providerConnectionID == connectionID
            else { return }
            routingMode = applied
            sessionRoutingMode = applied
            routingModeMessage = AppLocalization.string(
                "Routing mode updated without disconnecting."
            )
            routingModeMessageIsError = false
            Self.runtimeLogger.info(
                "stage=routingMode hotSwitch success mode=\(applied.rawValue, privacy: .public)"
            )
        } catch {
            guard state == .connected, providerConnectionID == connectionID
            else { return }
            let switchError = error
            if let client, state == .connected {
                do {
                    let restored = try await client.setRoutingMode(
                        previousMode
                    )
                    guard state == .connected, providerConnectionID == connectionID
                    else { return }
                    guard restored == previousMode else {
                        throw TunnelManagerError.providerSelectorUnavailable
                    }
                    sessionRoutingMode = restored
                    Self.runtimeLogger.info(
                        "stage=routingMode hotSwitch rollback success"
                    )
                } catch {
                    Self.runtimeLogger.error(
                        "stage=routingMode hotSwitch rollback failed"
                    )
                }
            }
            routingModeMessage = switchError.localizedDescription
            routingModeMessageIsError = true
            Self.runtimeLogger.error(
                "stage=routingMode hotSwitch failed error=\(String(reflecting: switchError), privacy: .public)"
            )
        }
    }

    /// Identifies one measurement run.
    ///
    /// A probe that finishes after the user switched profiles must be dropped
    /// rather than written to whatever group now carries the same name.
    struct LatencyRunToken: Equatable {
        let profileName: String
        let importedAt: Date
    }

    var currentLatencyRunToken: LatencyRunToken? {
        activeProfile.map {
            LatencyRunToken(profileName: $0.name, importedAt: $0.importedAt)
        }
    }

    /// The members actually shown for each group: the live selector snapshot
    /// when there is one, the profile summary otherwise.
    var isEnabled: Bool {
        switch state {
        case .connecting, .connected, .recovering: true
        default: false
        }
    }

    var isConnected: Bool {
        state == .connected
    }

    var isTransitioning: Bool {
        switch state {
        case .loading, .connecting, .recovering, .disconnecting: true
        default: false
        }
    }

    var managerConnectionIsTransitioning: Bool {
        guard let status = manager?.connection.status else { return false }
        return status == .connecting
            || status == .reasserting
            || status == .disconnecting
    }

    var managerConnectionIsActive: Bool {
        guard let status = manager?.connection.status else { return false }
        return Self.isActiveProviderStatus(status)
    }

    var managerConnectionPermitsStart: Bool {
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
            && !isUpdatingRoutingResources
            && !isUpdatingBypassPolicy
            && !isUpdatingDNSRuntimePolicy
            && !isUpdatingRoutingMode
            && !isSwitchingNetworkEngine
            && proxySelectionRequests.isEmpty
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
        let statePermitsChange = switch state {
        case .disconnected, .connected, .failed: true
        case .privacyConsentRequired, .loading, .connecting, .recovering, .disconnecting: false
        }
        return hasAcceptedPrivacyDisclosure
            && statePermitsChange
            && !isTransitioning
            && !isUpdatingRoutingMode
            && !isSwitchingNetworkEngine
            && !isImportingProfile
            && !isUpdatingProfiles
            && !isSavingConnectionConfiguration
    }

    var canChangeNetworkEngine: Bool {
        let statePermitsChange = switch state {
        case .disconnected, .connected, .failed: true
        case .privacyConsentRequired, .loading, .connecting, .recovering, .disconnecting: false
        }
        return hasAcceptedPrivacyDisclosure
            && statePermitsChange
            && !isSwitchingNetworkEngine
            && !isImportingProfile
            && !isUpdatingProfiles
            && !isUpdatingRoutingMode
            && !isSavingConnectionConfiguration
    }

    var canActivateProfile: Bool {
        let statePermitsChange = switch state {
        case .disconnected, .connected, .failed: true
        case .privacyConsentRequired, .loading, .connecting, .recovering, .disconnecting: false
        }
        return hasAcceptedPrivacyDisclosure
            && statePermitsChange
            && !isSwitchingNetworkEngine
            && !isRefreshingSubscription
            && !isImportingProfile
            && !isUpdatingProfiles
            && !isUpdatingBypassPolicy
            && !isTransferringProfiles
            && !isUpdatingRoutingMode
            && !isSavingConnectionConfiguration
    }

    var canModifyProfiles: Bool {
        hasAcceptedPrivacyDisclosure
            && canModifyProfilesRegardlessOfPrivacy
    }

    var canModifyProfilesRegardlessOfPrivacy: Bool {
        !isEnabled
            && !isTransitioning
            && !isRefreshingSubscription
            && !isImportingProfile
            && !isUpdatingProfiles
            && !isUpdatingBypassPolicy
            && !isTransferringProfiles
            && !isUpdatingRoutingMode
            && !isSwitchingNetworkEngine
            && !isSavingConnectionConfiguration
    }

    var canModifyInactiveProfilesRegardlessOfPrivacy: Bool {
        !isTransitioning
            && !isRefreshingSubscription
            && !isImportingProfile
            && !isUpdatingProfiles
            && !isUpdatingBypassPolicy
            && !isTransferringProfiles
            && !isUpdatingRoutingMode
            && !isSwitchingNetworkEngine
            && !isSavingConnectionConfiguration
    }

    var canModifyInactiveProfiles: Bool {
        hasAcceptedPrivacyDisclosure
            && canModifyInactiveProfilesRegardlessOfPrivacy
    }

    var canImportOrAddProfile: Bool {
        hasAcceptedPrivacyDisclosure
            && canImportOrAddProfileRegardlessOfPrivacy
    }

    var canImportOrAddProfileRegardlessOfPrivacy: Bool {
        !isTransitioning
            && !isRefreshingSubscription
            && !isImportingProfile
            && !isUpdatingProfiles
            && !isTransferringProfiles
    }

    private var isSavingConnectionConfiguration: Bool {
        isUpdatingRoutingResources || isUpdatingDNSRuntimePolicy
            || isUpdatingBypassPolicy || !proxySelectionRequests.isEmpty
    }

    var canModifyBypassPolicy: Bool {
        canModifyProfiles
    }

    var canModifyDNSRuntimePolicy: Bool {
        canModifyProfiles
            && !isUpdatingDNSRuntimePolicy
            && activeProfile != nil
    }

    var canModifyLocalProxySettings: Bool {
        canChangeNetworkEngine
    }

    var canPerformPrimaryAction: Bool {
        if isSwitchingNetworkEngine { return true }
        return switch state {
        case .disconnected, .failed:
            canConnect
        case .connecting, .connected, .recovering:
            true
        case .privacyConsentRequired, .loading, .disconnecting:
            false
        }
    }

    var primaryActionTitle: String {
        if systemExtensionApprovalRequired {
            return AppLocalization.string("Waiting for approval")
        }
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
        case .connected, .recovering: AppLocalization.string("Disconnect")
        case .disconnecting: AppLocalization.string("Disconnecting")
        case .failed: AppLocalization.string("Retry")
        }
    }

    var statusTitle: String {
        if systemExtensionApprovalRequired {
            return AppLocalization.string("Waiting for approval")
        }
        if isSwitchingNetworkEngine {
            return AppLocalization.string("Switching network engine…")
        }
        return switch state {
        case .privacyConsentRequired: AppLocalization.string("Privacy review required")
        case .loading: AppLocalization.string("Preparing")
        case .disconnected where !distributionConnectionAccess.permitsNewConnection:
            AppLocalization.string("License required")
        case .disconnected: AppLocalization.string("Not connected")
        case .connecting: AppLocalization.string("Connecting")
        case .recovering: AppLocalization.string("Recovering network")
        case .connected where isAutomaticRouteRecovering:
            AppLocalization.string("Recovering route")
        case .connected: AppLocalization.string("Traffic routing active")
        case .disconnecting: AppLocalization.string("Disconnecting")
        case .failed: AppLocalization.string("Unavailable")
        }
    }

    var statusDetail: String {
        if systemExtensionApprovalRequired {
            return AppLocalization.string(
                "Approve the AetherRoute network extension to continue."
            )
        }
        if isSwitchingNetworkEngine {
            return AppLocalization.string("Switching network engine…")
        }
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
            AppLocalization.string(isUpdatingRoutingResources
                ? "Preparing routing rules…" : "Verifying the network extension")
        case .recovering:
            AppLocalization.string("The tunnel remains active while the network recovers. You can disconnect at any time.")
        case .connected where isAutomaticRouteRecovering:
            AppLocalization.string(
                "The tunnel remains active while AetherRoute retries the fastest available node."
            )
        case .connected:
            AppLocalization.string("The network extension reports ready")
        case .disconnecting:
            AppLocalization.string("Restoring the normal network path")
        case let .failed(message): message
        }
    }

    private var distributionConnectionAccessDetail: String {
        switch distributionConnectionAccess {
        case .authorizedUntil where !distributionConnectionAccess.permitsNewConnection:
            AppLocalization.string("The saved license has expired. Review Settings > Account.")
        case .free, .unrestrictedDevelopment, .authorized, .authorizedUntil:
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
        guard !systemExtensionApprovalRequired,
              case .failed = state else { return nil }
        let context = activeProfile == nil
            ? ConnectionFailureContext.missingProfile
            : failureContext ?? .unknown
        return ConnectionRecoveryPlan(context: context)
    }

    @discardableResult
    func ensurePrivacyConsent() -> Bool {
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

    static let networkEnginePreferenceKey =
        "AetherRoute.NetworkEngineMode"
    static let selectorLatencyTestURL =
        ProxyConnectionReadinessPolicy.requiredExternalProbeURLString
    public static let defaultLatencyTestURL =
        "http://cp.cloudflare.com/generate_204"
    public static let uiLatencyTimeoutMilliseconds: UInt32 = 3_000

    var runtimeConnectionActivity: RuntimeConnectionActivity {
        switch state {
        case .connecting, .recovering, .disconnecting:
            .transitioning
        case .connected:
            .connected
        case .privacyConsentRequired, .loading, .disconnected, .failed:
            .inactive
        }
    }

    var diagnosticEngine: DiagnosticReport.Engine {
        switch sessionNetworkEngineMode ?? networkEngineMode {
        case .transparent: .transparentProxy
#if AETHERROUTE_INDEPENDENT
        case .tun: .packetTunnel
#endif
        }
    }

    static func diagnosticEventCode(
        for state: State
    ) -> DiagnosticEventCode {
        switch state {
        case .privacyConsentRequired: .privacyRequired
        case .loading: .preparing
        case .disconnected: .disconnected
        case .connecting: .connectRequested
        case .recovering: .networkRecovering
        case .connected: .providerReady
        case .disconnecting: .disconnectRequested
        case .failed: .providerFailed
        }
    }

    static func diagnosticState(
        for state: State
    ) -> DiagnosticReport.SessionState {
        switch state {
        case .privacyConsentRequired: .privacyRequired
        case .loading: .loading
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .recovering: .recovering
        case .connected: .connected
        case .disconnecting: .disconnecting
        case .failed: .failed
        }
    }

    static var diagnosticArchitecture: String {
#if arch(arm64)
        "arm64"
#else
        "unsupported"
#endif
    }

    static var diagnosticDistribution: DiagnosticReport.Distribution {
        .independent
    }
}

extension RuntimeEnvironmentEvent {
    var diagnosticEventCode: DiagnosticEventCode {
        switch self {
        case .systemWillSleep: .systemSleep
        case .systemDidWake: .systemWake
        case .networkPathChanged: .networkPathChanged
        }
    }
}

enum TunnelManagerError: LocalizedError, Sendable, Equatable {
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

