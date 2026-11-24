import AetherRouteKit
import Combine
import CryptoKit
import Foundation
import Network
import NetworkExtension
import OSLog
import Security

extension NetworkEngineMode {
    var localizedTitle: String {
        switch self {
        case .transparent: AppLocalization.string("Transparent Proxy")
#if AETHERROUTE_INDEPENDENT
        case .tun: AppLocalization.string("TUN")
#endif
        }
    }

    /// The engine's name where room is short, as in the menu bar panel's
    /// segmented control: "Transparent Proxy" did not fit there in English.
    var shortTitle: String {
        switch self {
        case .transparent: AppLocalization.string("Transparent (short engine name)")
#if AETHERROUTE_INDEPENDENT
        case .tun: AppLocalization.string("TUN")
#endif
        }
    }

    var localizedDetail: String {
        switch self {
        case .transparent:
            AppLocalization.string("Takes over each app's connections. Most compatible; recommended for everyday use.")
#if AETHERROUTE_INDEPENDENT
        case .tun:
            AppLocalization.string("Captures all traffic through a virtual network interface and can offer a local proxy for Terminal.")
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

struct SubscriptionUpdateFailureRecord: Codable, Equatable, Sendable {
    let message: String
    let occurredAt: Date
}

struct ProfileCatalogProjection: Sendable {
    let catalog: ProfileCatalog
    let summary: ProfileConfigurationSummary?
    let dnsPolicy: DNSRuntimePolicy
    let dnsErrorDescription: String?
}

enum ProfileCatalogProjectionBuilder {
    static func production(
        _ catalog: ProfileCatalog,
        customRules: [CustomRule] = [],
        remoteRules: [String] = [],
        globalOverride: ProfileOverride? = nil,
        externalRuleProviders: [RuleProviderMetadata] = [],
        bypassPolicy: BypassPolicy = .empty,
        enableDomesticDirect: Bool = DomesticRoutingOptimizer.isEnabled,
        loadSavedDNSPolicy: ((String) throws -> DNSRuntimePolicy?)? = nil
    ) -> ProfileCatalogProjection {
        let active = catalog.activeProfile?.profile
        let resolvedGlobalOverride = globalOverride
            ?? ProfileOverrideStore.applicationGroup().loadGlobalOverride()
        let effectiveCustomRules = TunnelManager.bypassDomainCustomRules(for: bypassPolicy) + customRules
        let effectiveYAML = active.map { profile in
            ProfileOverrideCompiler.apply(
                profile.overrides,
                globalOverride: resolvedGlobalOverride,
                externalRuleProviders: externalRuleProviders,
                to: ProfileRuntimeYAML.canonicalize(profile.yaml)
            ).yaml
        }
        let rawSummary = effectiveYAML.map { yaml in
            ProfileConfigurationInspector.inspect(
                yaml: yaml,
                customRules: effectiveCustomRules,
                remoteRules: remoteRules
            )
        }
        let summary = effectiveYAML.map { yaml in
            let optimizedYAML = DomesticRoutingOptimizer.optimizedProfile(
                for: yaml,
                customRules: effectiveCustomRules,
                remoteRules: remoteRules,
                enableDomesticDirect: enableDomesticDirect
            )
            return ProfileConfigurationInspector.inspect(
                yaml: optimizedYAML,
                customRules: effectiveCustomRules,
                remoteRules: remoteRules
            )
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
            let compatibilityDefault = rawSummary.map {
                DNSRuntimePolicy.packetTunnelCompatibilityDefault(
                    for: $0.dns
                )
            } ?? .inherited
            let savedPolicy = if let loadSavedDNSPolicy {
                try loadSavedDNSPolicy(active.yaml)
            } else {
                try DNSRuntimePolicyStore.applicationGroup()
                    .loadIfPresent(forProfileYAML: active.yaml)
            }
            return ProfileCatalogProjection(
                catalog: catalog,
                summary: summary,
                dnsPolicy: savedPolicy ?? compatibilityDefault,
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
        _ catalog: ProfileCatalog,
        globalOverride: ProfileOverride = ProfileOverride(),
        bypassPolicy: BypassPolicy = .empty
    ) -> ProfileCatalogProjection {
        let effectiveCustomRules = TunnelManager.bypassDomainCustomRules(for: bypassPolicy)
        return ProfileCatalogProjection(
            catalog: catalog,
            summary: catalog.activeProfile.map { managed in
                let compiled = ProfileOverrideCompiler.apply(
                    managed.profile.overrides,
                    globalOverride: globalOverride,
                    to: ProfileRuntimeYAML.canonicalize(managed.profile.yaml)
                ).yaml
                return ProfileConfigurationInspector.inspect(
                    yaml: compiled,
                    customRules: effectiveCustomRules
                )
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
    static func load(
        shouldLoadBypassPolicy: Bool,
        customRules: [CustomRule] = [],
        enableDomesticDirect: Bool = DomesticRoutingOptimizer.isEnabled
    ) throws
        -> ProductionStartupState
    {
        let bypassPolicy = shouldLoadBypassPolicy
            ? try BypassPolicyStore.applicationGroup().load()
            : nil
        let globalOverride = ProfileOverrideStore.applicationGroup().loadGlobalOverride()
        let catalog = try ProfileCatalogStore.applicationGroup().loadOrMigrate()
        return ProductionStartupState(
            bypassPolicy: bypassPolicy,
            profileProjection: ProfileCatalogProjectionBuilder.production(
                catalog,
                customRules: customRules,
                globalOverride: globalOverride,
                bypassPolicy: bypassPolicy ?? .empty,
                enableDomesticDirect: enableDomesticDirect
            )
        )
    }
}

/// Publishes the traffic statistics ledger on its own, like the telemetry
/// below: it changes with every sample, and publishing it from the tunnel
/// manager redrew the whole window (sidebar, page and menu bar) each time.
@MainActor
final class TrafficStatisticsModel: ObservableObject {
    @Published var ledger = TrafficStatisticsLedger()
}

/// Publishes high-frequency traffic counters independently from the host
/// lifecycle model. Keeping this object separate prevents every telemetry
/// sample from invalidating the complete navigation, icon and panel tree.
@MainActor
final class NetworkTelemetryViewModel: ObservableObject {
    @Published var snapshot: NetworkTelemetrySnapshot = .empty {
        didSet {
            invalidateConnectionCaches()
        }
    }
    private(set) var appMemoryBytes: UInt64 = NetworkTelemetryViewModel.measuredAppMemoryBytes()
    private(set) var history = TrafficHistory()
    private(set) var recentlyClosed = RecentlyClosedConnectionBuffer()
    private(set) var connectionRates: [ConnectionTableItem.ID: ConnectionTransferRates] = [:]
    private var rateTracker = ConnectionLiveRateTracker()
    private var truncationGuard = ConnectionTruncationGuard()
    private var cachedIdentifiedSnapshotConnections: [ConnectionTableItem]?
    private var cachedTrafficSortedSnapshotConnections: [ConnectionTableItem]?
    private var cachedSpeedSortedSnapshotConnections: [ConnectionTableItem]?
    private var cachedSnapshotOutletCounts: ConnectionOutletClassifier.Counts?

    private func invalidateConnectionCaches() {
        cachedIdentifiedSnapshotConnections = nil
        cachedTrafficSortedSnapshotConnections = nil
        cachedSpeedSortedSnapshotConnections = nil
        cachedSnapshotOutletCounts = nil
    }

    func identifiedSnapshotConnections() -> [ConnectionTableItem] {
        if let cached = cachedIdentifiedSnapshotConnections {
            return cached
        }
        let identified = ConnectionTableItem.identify(snapshot.connections)
        cachedIdentifiedSnapshotConnections = identified
        return identified
    }

    func trafficSortedSnapshotConnections() -> [ConnectionTableItem] {
        if let cached = cachedTrafficSortedSnapshotConnections {
            return cached
        }
        let sorted = identifiedSnapshotConnections().sorted {
            $0.connection.downloadTotal + $0.connection.uploadTotal
                > $1.connection.downloadTotal + $1.connection.uploadTotal
        }
        cachedTrafficSortedSnapshotConnections = sorted
        return sorted
    }

    func speedSortedSnapshotConnections() -> [ConnectionTableItem] {
        if let cached = cachedSpeedSortedSnapshotConnections {
            return cached
        }
        let rates = connectionRates
        let sorted = identifiedSnapshotConnections().sorted { lhs, rhs in
            let lhsSpeed = rates[lhs.id]?.totalBytesPerSecond ?? 0
            let rhsSpeed = rates[rhs.id]?.totalBytesPerSecond ?? 0
            if lhsSpeed != rhsSpeed {
                return lhsSpeed > rhsSpeed
            }
            return lhs.connection.downloadTotal + lhs.connection.uploadTotal
                > rhs.connection.downloadTotal + rhs.connection.uploadTotal
        }
        cachedSpeedSortedSnapshotConnections = sorted
        return sorted
    }

    func snapshotOutletCounts() -> ConnectionOutletClassifier.Counts {
        if let cached = cachedSnapshotOutletCounts {
            return cached
        }
        let counts = ConnectionOutletClassifier.counts(for: snapshot.connections)
        cachedSnapshotOutletCounts = counts
        return counts
    }

    private static func measuredAppMemoryBytes() -> UInt64 {
#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS
        if ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW"] != nil,
           ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_LIVE"] != "1" {
            return 48_640_000
        }
#endif
        return ProcessMemoryFootprint.currentBytes()
    }

#if DEBUG
    /// Review mode only: a fixed 30-second history, so screenshots show the
    /// traffic chart and sparklines the same way on every run.
    func seedReviewHistory(endingAt end: Date) {
        for second in stride(from: 29, through: 1, by: -1) {
            let phase = Double(30 - second)
            let coreWave = UInt64(max(0, 620_000 * sin(phase * 0.35)))
            let appWave = UInt64(max(0, 940_000 * cos(phase * 0.28)))
            history.append(
                download: 2_400_000 * (0.7 + 0.25 * sin(phase * 0.45) + 0.12 * sin(phase * 1.3)),
                upload: 384_000 * (0.7 + 0.3 * sin(phase * 0.6 + 1) + 0.1 * sin(phase * 1.7)),
                coreMemoryBytes: 11_800_000 + coreWave,
                appMemoryBytes: 47_800_000 + appWave,
                at: end.addingTimeInterval(-Double(second))
            )
        }
    }
#endif

    func update(
        _ snapshot: NetworkTelemetrySnapshot,
        requestedConnectionLimit: UInt16 = TunnelManager.connectionsPageTelemetryLimit,
        at now: Date = .now
    ) {
        let currentAppMemory = Self.measuredAppMemoryBytes()
        appMemoryBytes = currentAppMemory
        history.append(
            download: Double(snapshot.downloadBytesPerSecond),
            upload: Double(snapshot.uploadBytesPerSecond),
            coreMemoryBytes: snapshot.memoryBytes,
            appMemoryBytes: currentAppMemory,
            at: now
        )
        let identified = ConnectionTableItem.identify(snapshot.connections)
        connectionRates = rateTracker.update(items: identified, at: now)
        let effectiveCap = min(
            Int(requestedConnectionLimit),
            NetworkTelemetryCodec.maximumConnections
        )
        let isTruncated = snapshot.totalActiveConnections > snapshot.connections.count
            || (effectiveCap > 0 && snapshot.connections.count >= effectiveCap)
        truncationGuard.record(
            active: snapshot.connections,
            isTruncated: isTruncated,
            into: &recentlyClosed
        )
        // One publication for current values, connection rates, and history.
        self.snapshot = snapshot
        cachedIdentifiedSnapshotConnections = identified
    }

    func reset() {
        appMemoryBytes = Self.measuredAppMemoryBytes()
        history = TrafficHistory()
        recentlyClosed.reset()
        truncationGuard.reset()
        rateTracker.reset()
        connectionRates = [:]
        snapshot = .empty
    }

    func clearRecentlyClosed() {
        recentlyClosed.reset()
        truncationGuard.seed(active: snapshot.connections)
        objectWillChange.send()
    }

}

/// Tracks whether any network path is usable while a startup restore runs.
/// Reads happen on the main actor; updates hop there from the monitor queue.
@MainActor
private final class StartupNetworkPathWatcher {
    private(set) var isSatisfied: Bool
    private let monitor = NWPathMonitor()

    init() {
        isSatisfied = monitor.currentPath.status == .satisfied
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isSatisfied = satisfied
            }
        }
        monitor.start(queue: DispatchQueue(
            label: "com.example.aetherroute.startup-restore-path",
            qos: .utility
        ))
    }

    func cancel() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}

@MainActor
final class TunnelManager: ObservableObject {
    static let runtimeLogger = AppLog.logger(category: AppLog.Category.appRuntime)
    static let diagnosticLog = DiagnosticLogCenter.current.log(category: AppLog.Category.appRuntime)

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
            if oldValue != state {
                handleSystemProxyForStateTransition(from: oldValue, to: state)
                handleMITMStateTransition(to: state)
            }
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
    var activeProfileSummaryGeneration: UInt64 = 0
    @Published var profileMessage: String?
    @Published var profileMessageIsError = false
    @Published var pendingExternalSubscription:
        ExternalSubscriptionImportRequest?
    @Published var externalSubscriptionLinkError: String?
    @Published var bypassPolicy: BypassPolicy = .empty
    @Published var bypassPolicyMessage: String?
    @Published var bypassPolicyMessageIsError = false
    @Published var customRules: [CustomRule] = []
    @Published var customRuleMessage: String?
    @Published var customRuleMessageIsError = false
    @Published var isUpdatingCustomRules = false
    @Published var customRuleProviders: [RuleProviderMetadata] = []
    @Published var refreshingRuleProviderIDs: Set<UUID> = []
    @Published var isRefreshingAllRuleProviders = false
    @Published var ruleProviderMessage: String?
    @Published var ruleProviderMessageIsError = false
    var compiledRemoteRulesCache: [String] = []
    @Published var pendingRuleTestDestination: String?
    @Published var dnsRuntimePolicy: DNSRuntimePolicy = .inherited
    @Published var dnsRuntimePolicyMessage: String?
    @Published var dnsRuntimePolicyMessageIsError = false
    @Published var isRefreshingSubscription = false
    @Published var refreshingSubscriptionProfileIDs: Set<UUID> = []
    @Published var subscriptionUpdateErrors: [UUID: SubscriptionUpdateFailureRecord] = [:]
    @Published var isUnifiedDelayEnabled: Bool
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
    @Published var networkEngineBlockedNeedsSetup = false
    @Published var isTransferringProfiles = false
    @Published var routingResourceStatuses:
        [RoutingResourceKind: RoutingResourceStatus] = [:]
    @Published var isUpdatingRoutingResources = false
    /// A check or download that applies on the next connection. Unlike
    /// `isUpdatingRoutingResources` it never holds back connection controls.
    @Published var isRefreshingRoutingResources = false
    @Published var isAutomaticRoutingResourceUpdateEnabled: Bool
    /// Close what still runs through a group when its node changes, so the
    /// new node takes effect at once. On by default, as in other clients.
    @Published var closesConnectionsOnProxySwitch: Bool
    /// Test the shown group's latency once when the Proxies page opens.
    /// Off by default: no probe runs unless the person asks for it.
    @Published var testsLatencyWhenProxiesOpen: Bool
    /// When each group was last tested because the Proxies page opened.
    var latencyOnOpenTestedAt: [String: Date] = [:]
    /// Local traffic statistics (Settings › Network). Off by default; the
    /// ledger never leaves this Mac.
    @Published var isTrafficStatisticsEnabled: Bool
    /// Observed only by the statistics sheet.
    let trafficStatistics = TrafficStatisticsModel()
    var trafficLedger: TrafficStatisticsLedger {
        get { trafficStatistics.ledger }
        set { trafficStatistics.ledger = newValue }
    }
    var trafficAccumulator = TrafficStatisticsAccumulator()
    var trafficLedgerSavedAt: Date?
    var isTrafficLedgerLoaded = false
    /// Samples were added since the ledger was last written.
    var hasUnsavedTrafficSamples = false
    var trafficLedgerRevision: UInt64 = 0
    let trafficStatisticsWriter = TrafficStatisticsWriter()
    @Published var routingResourceMessage: String?
    @Published var routingResourceMessageIsError = false
    @Published var hasAcceptedPrivacyDisclosure: Bool
    /// First-run network setup still has to grant both engines' system
    /// extension and configuration before the main window opens.
    @Published var isNetworkSetupRequired = false
    @Published var networkSetupStates: [NetworkEngineMode: NetworkSetupStepState] = [:]
    @Published var isRunningNetworkSetup = false
    @Published var connectedSince: Date?
    @Published var sessionRoutingMode: RoutingMode?
    @Published var sessionNetworkEngineMode: NetworkEngineMode?
    /// Connections requested per telemetry poll. The Connections page requests
    /// up to 250 active flows when visible; background/other pages keep 64.
    static let connectionsPageTelemetryLimit: UInt16 = 250
    static let backgroundTelemetryConnectionLimit: UInt16 = 64
    static let telemetryConnectionLimit: UInt16 = 64
    var telemetryRateSampler = TelemetryRateSampler()

    var effectiveTelemetryConnectionLimit: UInt16 {
        if realtimeTelemetrySources.contains("connections")
            || backgroundTelemetrySources.contains("connections") {
            return Self.connectionsPageTelemetryLimit
        }
        return Self.backgroundTelemetryConnectionLimit
    }

    var effectiveActiveSubscriptionUsage: SubscriptionUsage? {
        if let usage = activeProfile?.subscription?.usage {
            return usage
        }
        guard let active = activeProfile, let summary = activeProfileSummary else {
            return nil
        }
        let reportedAt = active.subscription?.lastUpdatedAt
            ?? active.subscription?.lastCheckedAt
            ?? active.importedAt
        return SubscriptionUsage.fallback(from: summary, reportedAt: reportedAt)
    }

    @Published var networkEngineMode: NetworkEngineMode
    @Published var systemExtensionApprovalRequired = false
    @Published var proxySelections: [String: ProxySelectionState] = [:]
    /// Node each automatic group (url-test, fallback…) is really using,
    /// derived from live connection chains. Published only when it changes,
    /// so views read it without observing every telemetry sample.
    @Published var automaticGroupLeaves: [String: String] = [:]
    @Published var proxySelectionMessages: [String: String] = [:]
    @Published var proxySelectionRequests: Set<String> = []
    /// Non-published tracking for passive read-only selection snapshots so
    /// visiting Overview/Proxies does not trigger two full-window re-layouts.
    var proxySnapshotRefreshRequests: Set<String> = []
    /// When each group's selection was last read, and on which connection.
    var proxySelectionRefreshedAt: [String: (connectionID: UUID?, at: Date)] = [:]
    /// Groups that switch nodes on their own: every `select` group whose
    /// mode is not manual. Kept in step with `proxySelectionModes`.
    @Published var automaticProxySelectionGroups: Set<String> = []
    /// The mode of each `select` group that is not manual (1.6.0).
    @Published var proxySelectionModes: [String: ProxySelectionMode] = [:]
    /// The preferred node of each group in failover mode.
    @Published var preferredProxyMembers: [String: String] = [:]
    /// Automatic switches in this run, newest first. Never written to disk.
    @Published var proxySwitchLog = ProxySwitchLog()
    /// Each automatic switch as it happens, for notifications.
    let proxySwitchEvents = PassthroughSubject<ProxySwitchEvent, Never>()
    var failoverRecoveryTracker = ProxyFailoverRecoveryTracker()
    var failoverRecoveryScannedAt: [String: Date] = [:]
    let latencyStore = ProxyLatencyStore()
    var proxyLatencies: [String: ProxyLatencyState] {
        get { latencyStore.proxyLatencies }
        set {
            if latencyStore.proxyLatencies != newValue {
                latencyStore.proxyLatencies = newValue
            }
        }
    }
    var proxyLatencyRequests: Set<String> {
        get { latencyStore.proxyLatencyRequests }
        set {
            if latencyStore.proxyLatencyRequests != newValue {
                latencyStore.proxyLatencyRequests = newValue
            }
        }
    }
    var memberLatencyRequests: Set<String> {
        get { latencyStore.memberLatencyRequests }
        set {
            if latencyStore.memberLatencyRequests != newValue {
                latencyStore.memberLatencyRequests = newValue
            }
        }
    }

    /// Staging area behind `proxyLatencies`. Merging one result is O(1) here;
    /// the published arrays are rebuilt once per flush window instead of once
    /// per arriving result.
    var latencyIndex = ProxyLatencyIndex()
    /// The profile the index was built for. A profile switch resets the index
    /// so a member name reused by the new profile never inherits an old
    /// number.
    var latencyIndexToken: LatencyRunToken?
    var latencyRuntimeEpoch: UInt64 = 0
    var activeLatencyRunTasks: [UUID: Task<Void, Never>] = [:]
    var activeMemberLatencyTokens: [String: UUID] = [:]
    var proxySelectionModeTokens: [String: UUID] = [:]
    var proxySelectionModeTasks: [String: Task<Void, Never>] = [:]
    var prepareGeneration: UInt64 = 0
    var pendingDNSRuntimePolicy: DNSRuntimePolicy?
    var scenarioPresetQueueTask: Task<Void, Never>?
    var pendingLatencyFlush: Set<String> = []
    var lastLatencyFlushAt: ContinuousClock.Instant?
    var latencyFlushTask: Task<Void, Never>?

    @Published var isAutomaticRouteRecovering = false
    @Published var isVerifyingProxyReadiness = false
    /// Quality of the route behind an already-usable tunnel. The tunnel being
    /// up and the selected route being fast are two different questions; this
    /// reports the second without gating the first.
    var connectionQualityCheckedAt: Date?
    @Published var connectionQuality: ConnectionQuality = .unknown {
        didSet {
            switch connectionQuality {
            case .unknown, .verifying: connectionQualityCheckedAt = nil
            case .verified, .degraded: connectionQualityCheckedAt = .now
            }
        }
    }

    func setConnectionQuality(_ quality: ConnectionQuality) {
        if connectionQuality != quality {
            connectionQuality = quality
        } else if quality == .verified || quality == .degraded {
            connectionQualityCheckedAt = .now
        }
    }
    var latencyMeasuredAt: [String: [String: Date]] {
        get { latencyStore.latencyMeasuredAt }
        set {
            if latencyStore.latencyMeasuredAt != newValue {
                latencyStore.latencyMeasuredAt = newValue
            }
        }
    }
    let telemetryViewModel = NetworkTelemetryViewModel()
    var telemetry: NetworkTelemetrySnapshot { telemetryViewModel.snapshot }
    var realtimeTelemetrySources: Set<String> = []
    var backgroundTelemetrySources: Set<String> = []
    /// Some surface showing live traffic is frontmost: poll every 3 seconds.
    @Published var isRealtimeTelemetryPreferred = false
    /// Some surface showing live traffic is visible but the app is not
    /// frontmost: poll every 10 seconds so the numbers on screen stay true.
    @Published var isBackgroundTelemetryPreferred = false

    struct PendingControlURLRequest: Identifiable, Equatable, Sendable {
        let id = UUID()
        let url: URL
        let action: ExternalControlAction
    }

    struct EffectiveProfileCompilationKey: Equatable {
        let yamlDigest: SHA256Digest
        let profileOverrides: ProfileOverride?
        let globalOverride: ProfileOverride
        let enabledProviders: [RuleProviderMetadata]
    }

    static let controlURLSchemeTokenPreferenceKey = "AetherRoute.ControlURLSchemeToken"

    @Published var localProxySettings: LocalProxySettings
    @Published var localProxySettingsMessage: String? = nil
    @Published var externalControllerSettings: ExternalControllerSettings
    @Published var externalControllerSecret: String
    @Published var externalControllerIsRunning = false
    @Published var externalControllerMessage: String? = nil
    @Published var externalControllerMessageIsError = false
    @Published var mitmConfiguration: MITMConfiguration
    @Published var mitmCAFingerprint: String? = nil
    @Published var mitmMessage: String? = nil
    @Published var mitmMessageIsError = false
    @Published var isSystemProxyActive = false
    @Published var controlURLSchemePreferences: ControlURLSchemePreferences
    @Published private(set) var controlURLSchemeToken: String
    @Published var pendingControlURLRequest: PendingControlURLRequest?
    var cachedGlobalProfileOverride: ProfileOverride?
    var cachedEffectiveProfileCompilation: (key: EffectiveProfileCompilationKey, result: ProfileOverrideResult)?
    var externalControllerServer: ExternalControllerServer?
    var externalControllerDelegateAdapter: ExternalControllerTunnelAdapter?
    var externalControllerBoundPort: UInt16?
    var externalControllerStartTask: Task<Void, Never>?
    var mitmSyncTask: Task<Void, Never>?
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
    let externalControllerPreferencesStore: ExternalControllerPreferencesStore
    let externalControllerSecretStore: ExternalControllerSecretStore
    let mitmConfigurationStore: MITMConfigurationStore
    let mitmCertificateAuthority: MITMCertificateAuthority
    let controlURLSchemePreferenceStore: ControlURLSchemePreferenceStore
    let systemProxyConfigurator: SystemProxyConfigurator
    let userDefaults: UserDefaults
    let subscriptionClient: ProfileSubscriptionClient
    let routingResourceDownloadClient: RoutingResourceDownloadClient
    let systemExtensionActivator: any SystemExtensionActivating
    let routingResourceStoreFactory:
        @Sendable () throws -> RoutingResourceStore
    let ruleProviderEngine: RuleProviderEngine
    let proxyProviderEngine: ProxyProviderEngine
    let diagnosticEvents = DiagnosticEventBuffer()
    var manager: NEVPNManager?
    var statusObserver: NSObjectProtocol?
    var configurationObserver: NSObjectProtocol?
    nonisolated(unsafe) var cloudSyncObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) var cloudSyncUserRulesObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) var cloudSyncRuleProvidersObserver: (any NSObjectProtocol)?
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
    var routingResourceRefreshSchedule: Task<Void, Never>?
    var subscriptionUpdateSchedule: Task<Void, Never>?
    var automaticResourceRefreshFailures = 0
    var nextAutomaticResourceRefreshAttempt: Date?
    let bundledResourceDirectoryURL = Bundle.main.resourceURL?
        .appendingPathComponent("RoutingResources", isDirectory: true)
    lazy var bundledGeoSiteData: Data? = bundledResourceDirectoryURL
        .flatMap { try? Data(contentsOf: $0.appendingPathComponent(RoutingResourceKind.geoSite.fileName), options: .mappedIfSafe) }
    /// GEOSITE categories of the bundled database, read once for the rule
    /// editor (it validates on every keystroke); nil when unreadable, in
    /// which case the launch-time check still applies.
    lazy var bundledGeoSiteCategories: GeoSiteCategoryIndex? = bundledGeoSiteData
        .flatMap { try? GeoSiteCategoryIndex(data: $0) }
    /// Pre-indexed protobuf slices of each GeoSite entry (`0x0A <len> <entry>`),
    /// built in a single linear pass so DNS lookup and route simulation only
    /// decode referenced categories instead of rescanning megabytes per rule.
    lazy var bundledGeoSiteSliceIndex: GeoSiteEntrySliceIndex? = bundledGeoSiteData
        .flatMap(GeoSiteEntrySliceIndex.init(data:))
    var connectionWatchdogTask: Task<Void, Never>?
    var disconnectionWatchdogTask: Task<Void, Never>?
    var recoveryWatchdogTask: Task<Void, Never>?
    var connectionReadinessTask: Task<Void, Never>?
    var connectionReadinessAttemptID: UUID?
    var connectionRequestID: UUID?
    var connectionAttemptID: UUID?
    var disconnectionAttemptID: UUID?
    var recoveryAttemptID: UUID?
    var connectionGenerationToken: UInt64 = 0
    var userIntentEpoch: UInt64 = 0
    var prepareTask: Task<Void, Never>?
    var reconnectToken: UUID?
    var recoveryRestartTask: Task<Void, Never>?
    var recoveryRestartToken: UUID?
    let systemProxyCoordinator = SystemProxyWorkCoordinator()
    var systemProxyGeneration: UInt64 = 0
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
    var startupRestoreTask: Task<Void, Never>?
    /// The previous connection is restored at most once per launch; see
    /// `restorePreviousConnectionIfRequested`.
    var hasBegunStartupRestore = false
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
    /// Last wake or network path change, for blaming a lost route on it.
    var lastNetworkChangeAt: Date?
    /// Last reconnect made because a route did not come back after a change.
    var lastNetworkRecoveryReconnectAt: Date?
    /// Consecutive control-plane message failures (reply missing or timed out).
    var consecutiveProviderUnresponsiveCount: Int = 0
    /// Last non-sensitive extension diagnostic log snapshot fetched while connected
    /// so post-disconnect/post-crash diagnostics remain viewable when offline.
    var cachedExtensionDiagnosticLog: (process: String, text: String)?

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
        systemProxyConfigurator: SystemProxyConfigurator? = nil,
        userDefaults: UserDefaults = .standard,
        subscriptionClient: ProfileSubscriptionClient = .live(),
        routingResourceDownloadClient: RoutingResourceDownloadClient = .live(),
        systemExtensionActivator: any SystemExtensionActivating =
            SystemExtensionActivationCoordinator(),
        routingResourceStoreFactory:
            @escaping @Sendable () throws -> RoutingResourceStore = {
                try RoutingResourceStore.applicationGroup()
            },
        ruleProviderEngine: RuleProviderEngine = .shared,
        proxyProviderEngine: ProxyProviderEngine = .shared
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
        self.ruleProviderEngine = ruleProviderEngine
        self.proxyProviderEngine = proxyProviderEngine
        let localProxyStore = LocalProxySettingsStore(defaults: userDefaults)
        let loadedLocalProxySettings = localProxyStore.load()
        localProxySettingsStore = localProxyStore
        localProxySettings = loadedLocalProxySettings
        let controllerStore = ExternalControllerPreferencesStore(defaults: userDefaults)
        externalControllerPreferencesStore = controllerStore
        externalControllerSettings = controllerStore.load(localProxy: loadedLocalProxySettings)
        let controllerSecretStore = ExternalControllerSecretStore()
        externalControllerSecretStore = controllerSecretStore
        externalControllerSecret = ""
        let mitmStore = MITMConfigurationStore(defaults: userDefaults)
        mitmConfigurationStore = mitmStore
        mitmConfiguration = mitmStore.load()
        mitmCertificateAuthority = MITMCertificateAuthority()
        controlURLSchemePreferenceStore = ControlURLSchemePreferenceStore(defaults: userDefaults)
        controlURLSchemePreferences = controlURLSchemePreferenceStore.load()
        controlURLSchemeToken = Self.loadOrCreateControlURLSchemeToken(in: userDefaults)
        self.systemProxyConfigurator = systemProxyConfigurator ?? SystemProxyConfigurator(defaults: userDefaults)
        LANProxyServerController.localizedFailureFormatter = {
            Self.localizedLANProxyStatusFailure($0)
        }
        self.isDomesticOptimizationEnabled = DomesticRoutingOptimizer.isEnabled
        self.isAutomaticRoutingResourceUpdateEnabled = userDefaults.object(
            forKey: Self.automaticRoutingResourceUpdatePreferenceKey
        ) as? Bool ?? true
        self.closesConnectionsOnProxySwitch = userDefaults.object(
            forKey: Self.closesConnectionsOnProxySwitchPreferenceKey
        ) as? Bool ?? true
        self.testsLatencyWhenProxiesOpen = userDefaults.object(
            forKey: Self.testsLatencyWhenProxiesOpenPreferenceKey
        ) as? Bool ?? false
        self.isTrafficStatisticsEnabled = userDefaults.object(
            forKey: Self.trafficStatisticsPreferenceKey
        ) as? Bool ?? false
        self.isUnifiedDelayEnabled = (
            userDefaults.object(forKey: Self.unifiedDelayPreferenceKey)
                ?? UserDefaults.standard.object(forKey: Self.unifiedDelayPreferenceKey)
        ) as? Bool ?? true
        self.subscriptionUpdateErrors = Self.loadSubscriptionUpdateErrors(from: userDefaults)
        do {
            self.customRules = try CustomRuleStore.applicationGroup().load()
        } catch {
            self.customRules = []
        }

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
#if DEBUG
        if reviewState != nil,
           environment["AETHERROUTE_UI_REVIEW_PROFILE"] == "showcase" {
            customRules = Self.showcaseReviewCustomRules
        }
#endif
        routingMode = reviewState == nil
            ? routingModePreferenceStore.load()
            : .rule
        persistsRoutingModeSelection = reviewState == nil
        if let reviewState {
            hasAcceptedPrivacyDisclosure =
                environment["AETHERROUTE_UI_REVIEW_PRIVACY"] != "pending"
            installReviewNetworkSetup(environment["AETHERROUTE_UI_REVIEW_SETUP"])
            guard hasAcceptedPrivacyDisclosure else {
                state = .privacyConsentRequired
                return
            }
            installReviewBypassPolicy()
            if startsWithEmptyReviewProfile
                || environment["AETHERROUTE_UI_REVIEW_PROFILE"] == "none" {
                if reviewState == "extension-approval" {
                    systemExtensionApprovalRequired = true
                    isPreparing = false
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
                // Usage is relative to now so the card always shows the
                // "running low" state: 93% of 200 GiB used, 12 days left.
                let gib: UInt64 = 1 << 30
                reviewSubscription = try? ProfileSubscription(
                    url: url,
                    etag: "\"review-7\"",
                    lastCheckedAt: Date(timeIntervalSince1970: 1_775_003_300),
                    lastUpdatedAt: Date(timeIntervalSince1970: 1_775_000_000),
                    usage: SubscriptionUsage(
                        uploadBytes: 14 * gib,
                        downloadBytes: 172 * gib,
                        totalBytes: 200 * gib,
                        expiresAt: Date.now.addingTimeInterval(12 * 86_400),
                        reportedAt: Date.now.addingTimeInterval(-20 * 60)
                    ),
                    providerUpdateInterval: 12 * 3_600
                )
            } else {
                reviewSubscription = nil
            }

            // "groups" reviews the multi-group Proxies layout; every other
            // review keeps the single group the UI tests are written for.
            let reviewExtraGroups = environment["AETHERROUTE_UI_REVIEW_PROFILE"] == "groups"
                ? """
                  - {name: Auto, type: url-test, proxies: [Singapore Edge, Tokyo Direct], url: 'https://www.gstatic.com/generate_204', interval: 300}
                  - {name: Streaming, type: fallback, proxies: [Singapore Edge, Tokyo Direct], url: 'https://www.gstatic.com/generate_204', interval: 300}
                """
                : ""
            // "compat" adds nodes and rules the engine cannot use, for the
            // compatibility notice on the Proxies and Rules pages.
            let isCompatReview = environment["AETHERROUTE_UI_REVIEW_PROFILE"] == "compat"
            let reviewCompatProxies = isCompatReview
                ? """
                  - {name: Hong Kong Sudoku 01, type: sudoku}
                  - {name: Hong Kong Sudoku 02, type: sudoku}
                  - {name: Seoul KCP, type: vmess, network: kcp}
                """
                : ""
            let reviewCompatRules = isCompatReview
                ? """
                  - FUTURE-RULE,13335,Balanced
                  - UNKNOWN-RULE,*.cdn.example,Balanced
                """
                : ""
            // "large" stresses the lists: 500 nodes and 10,000 rules.
            let isLargeReview = environment["AETHERROUTE_UI_REVIEW_PROFILE"] == "large"
            // "showcase" is the website's screenshot set: a realistic mix of
            // regions, protocols, rules and flows. Generated, never bundled.
            let isShowcaseReview = environment["AETHERROUTE_UI_REVIEW_PROFILE"] == "showcase"
            let profile = ActiveProfile(
                name: "Balanced · Singapore",
                yaml: isLargeReview ? Self.largeReviewProfileYAML
                    : isShowcaseReview ? Self.showcaseReviewProfileYAML : """
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
                \(reviewCompatProxies)
                proxy-groups:
                  - {name: Balanced, type: select, proxies: [Singapore Edge, Tokyo Direct]}
                \(reviewExtraGroups)
                rules:
                \(reviewCompatRules)
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
                    // "single" reviews the one-profile library layout.
                    profiles: environment["AETHERROUTE_UI_REVIEW_PROFILE"] == "single"
                        ? [managed]
                        : [managed, fallback, office]
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
                ? (isShowcaseReview
                    ? Date.now.addingTimeInterval(-8_040)
                    : Date(timeIntervalSince1970: 1_775_003_600))
                : nil
            sessionRoutingMode = state == .connected || state == .recovering ? routingMode : nil
            if state == .connected {
                if isShowcaseReview {
                    installShowcaseReviewSelections()
                } else {
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
                }
                installReviewTelemetry()
                if environment["AETHERROUTE_UI_REVIEW_FAILOVER"] == "1" {
                    installReviewFailover()
                }
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
        isNetworkSetupRequired = resolveNetworkSetupGate()
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
                    await self.applyProductionProfileCatalog(
                        catalog,
                        preserveConnectedRuntimeState: true
                    )
                } catch {
                    Self.runtimeLogger.error(
                        "stage=cloudSyncReload failed error=\(String(reflecting: error), privacy: .public)"
                    )
                }
            }
        }
        cloudSyncUserRulesObserver = NotificationCenter.default.addObserver(
            forName: .aetherRouteCloudSyncDidUpdateUserRules,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let syncedSnapshot = notification.object as? CloudSyncUserRulesSnapshot
            Task { @MainActor [weak self] in
                guard let self, !self.isUIReviewMode else { return }
                let previousRules = self.customRules
                let previousBypass = self.bypassPolicy
                if let snapshot = syncedSnapshot {
                    self.customRules = snapshot.customRules
                    self.bypassPolicy = Self.sanitizeBypassPolicy(snapshot.bypassPolicy)
                } else {
                    if let loadedRules = try? CustomRuleStore.applicationGroup().load() {
                        self.customRules = loadedRules
                    }
                    if let loadedBypass = try? BypassPolicyStore.applicationGroup().load() {
                        self.bypassPolicy = Self.sanitizeBypassPolicy(loadedBypass)
                    }
                }
                // Synced rules used to show on the Rules page but route
                // nothing until the next connect; apply them like a local edit.
                let previousProviders = self.customRuleProviders
                await self.reloadCustomRuleProvidersFromEngine()
                if self.customRules != previousRules
                    || self.bypassPolicy != previousBypass
                    || self.customRuleProviders != previousProviders {
                    await self.refreshActiveProfileSummaryOffMainActor()
                    await self.reloadCustomRulesLive()
                }
            }
        }
        cloudSyncRuleProvidersObserver = NotificationCenter.default.addObserver(
            forName: .aetherRouteCloudSyncDidUpdateRuleProviders,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isUIReviewMode else { return }
                let previousProviders = self.customRuleProviders
                await self.reloadCustomRuleProvidersFromEngine()
                if self.customRuleProviders != previousProviders {
                    await self.refreshActiveProfileSummaryOffMainActor()
                    await self.reloadCustomRulesLive()
                }
            }
        }
        if !isUIReviewMode {
            installLANProxyCallbacks()
            restoreSystemProxyIfNeeded()
            LANProxyServerController.shared.updateConfiguration(
                settings: localProxySettings,
                isTunnelConnected: state == .connected,
                allowStandaloneLoopback: false
            )
            MenuBarTrafficController.shared.onEnabledChanged = { [weak self] enabled in
                self?.handleMenuBarTrafficEnabledChanged(enabled)
            }
            if hasAcceptedPrivacyDisclosure {
                #if !AETHERROUTE_APP_STORE
                SparkleUpdaterController.shared.handlePrivacyConsentAccepted()
                #endif
            }
            startSubscriptionUpdateScheduleIfNeeded()
            syncExternalControllerLifecycle()
            loadMITMCertificateFingerprintIfNeeded()
        }
    }

    deinit {
        subscriptionUpdateSchedule?.cancel()
        if let cloudSyncObserver {
            NotificationCenter.default.removeObserver(cloudSyncObserver)
        }
        if let cloudSyncUserRulesObserver {
            NotificationCenter.default.removeObserver(cloudSyncUserRulesObserver)
        }
        if let cloudSyncRuleProvidersObserver {
            NotificationCenter.default.removeObserver(cloudSyncRuleProvidersObserver)
        }
    }

    func startSubscriptionUpdateScheduleIfNeeded() {
        guard !isUIReviewMode, !isApplicationTerminating else { return }
        guard subscriptionUpdateSchedule == nil else { return }
        subscriptionUpdateSchedule = Task { @MainActor [weak self] in
            await self?.runSubscriptionUpdateLoop()
        }
    }

    func acceptPrivacyDisclosure() async {
        if !isUIReviewMode {
            privacyConsentStore.acceptCurrentDisclosure()
            #if !AETHERROUTE_APP_STORE
            SparkleUpdaterController.shared.handlePrivacyConsentAccepted()
            #endif
        }
        hasAcceptedPrivacyDisclosure = true
        startSubscriptionUpdateScheduleIfNeeded()
        // First run continues with network setup; prepare() would otherwise
        // install one engine's extension on its own and skip the other.
        if isNetworkSetupRequired {
            state = .disconnected
            await refreshNetworkSetupStatus()
            return
        }
        state = isUIReviewMode ? .disconnected : .loading
        await prepare()
    }

    func prepare() async {
        guard ensurePrivacyConsent() else { return }
        guard !isNetworkSetupRequired else { return }
        guard !isUIReviewMode else { return }
        guard !rejectDevelopmentPreviewStart() else { return }
        startSubscriptionUpdateScheduleIfNeeded()
        if let existingPrepare = prepareTask {
            await existingPrepare.value
            return
        }
        guard manager == nil, !isPreparing else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPrepare()
        }
        prepareTask = task
        await task.value
    }

    private func performPrepare() async {
        let generation = prepareGeneration
        isPreparing = true
        defer {
            if prepareGeneration == generation {
                isPreparing = false
                prepareTask = nil
            }
        }

        do {
            let shouldLoadBypassPolicy = !hasLoadedBypassPolicy
            let currentCustomRules = customRules
            let currentDomesticEnabled = isDomesticOptimizationEnabled
            let startup = try await Task.detached(priority: .userInitiated) {
                try ProductionStartupLoader.load(
                    shouldLoadBypassPolicy: shouldLoadBypassPolicy,
                    customRules: currentCustomRules,
                    enableDomesticDirect: currentDomesticEnabled
                )
            }.value
            if let loadedBypassPolicy = startup.bypassPolicy {
                let sanitized = Self.sanitizeBypassPolicy(loadedBypassPolicy)
                bypassPolicy = sanitized
                hasLoadedBypassPolicy = true
                if sanitized.rules.count != loadedBypassPolicy.rules.count {
                    Task { [weak self] in
                        _ = try? await self?.persistBypassPolicy(sanitized)
                    }
                }
            }
            await reloadCustomRuleProvidersFromEngine(
                additionalProfileYAMLs: startup.profileProjection.catalog.profiles.map(\.profile.yaml)
            )
            let initialProjection: ProfileCatalogProjection
            let activeRuleProviders = customRuleProviders.filter(\.isEnabled)
            if !compiledRemoteRulesCache.isEmpty || !activeRuleProviders.isEmpty || !bypassPolicy.rules.isEmpty {
                let currentCustomRules = customRules
                let currentRemoteRules = compiledRemoteRulesCache
                let currentGlobalOverride = loadGlobalProfileOverride()
                let currentBypassPolicy = bypassPolicy
                let currentDomesticEnabled = isDomesticOptimizationEnabled
                let catalog = startup.profileProjection.catalog
                initialProjection = await Task.detached(priority: .userInitiated) {
                    ProfileCatalogProjectionBuilder.production(
                        catalog,
                        customRules: currentCustomRules,
                        remoteRules: currentRemoteRules,
                        globalOverride: currentGlobalOverride,
                        externalRuleProviders: activeRuleProviders,
                        bypassPolicy: currentBypassPolicy,
                        enableDomesticDirect: currentDomesticEnabled
                    )
                }.value
            } else {
                initialProjection = startup.profileProjection
            }
            guard prepareGeneration == generation else { return }
            installProfileProjection(initialProjection)
            try await systemExtensionActivator.activate(
                identifier: networkEngineMode.providerBundleIdentifier
            ) { [weak self] in
                guard let self, self.prepareGeneration == generation else { return }
                self.failureContext = .configuration
                self.systemExtensionApprovalRequired = true
                self.isPreparing = false
                self.prepareTask = nil
                self.state = .failed(
                    AppLocalization.string(
                        "Approve the AetherRoute network extension to continue."
                    )
                )
            }
            guard prepareGeneration == generation else { return }
            systemExtensionApprovalRequired = false
            await deactivateOpposingNetworkEngineManagers(for: networkEngineMode)
            guard prepareGeneration == generation else { return }
            installManager(try await loadOrCreateManager())
            observeConfigurationChanges()
            updateState()
            if prepareGeneration == generation {
                isPreparing = false
            }
            if !isUIReviewMode,
               qaAutomationEnvironment["AETHERROUTE_QA_AUTOCONNECT"] == nil,
               NSClassFromString("XCTestCase") == nil,
               ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
#if AETHERROUTE_INDEPENDENT
                let opposingMode: NetworkEngineMode =
                    networkEngineMode == .transparent ? .tun : .transparent
                let opposingIdentifier = opposingMode.providerBundleIdentifier
                Task { @MainActor [weak self] in
                    await self?.systemExtensionActivator
                        .upgradeEnabledIfOutdated(identifier: opposingIdentifier)
                }
#endif
            }
            if shouldRunAutomaticSubscriptionCheck, !isApplicationTerminating {
                Task { @MainActor [weak self] in
                    guard let self, !self.isApplicationTerminating else { return }
                    await self.refreshSubscriptionIfDue()
                }
            }
            await restorePreviousConnectionIfRequested()
            await connectForQAAutomationIfRequested()
        } catch is CancellationError {
            return
        } catch {
            guard prepareGeneration == generation else { return }
            systemExtensionApprovalRequired = false
            recordFailure(error, context: .configuration)
        }
    }

    func cancelStartupRestore(reason: String) {
        guard startupRestoreTask != nil else { return }
        Self.runtimeLogger.info(
            "stage=startupRestore cancel reason=\(reason, privacy: .public)"
        )
        startupRestoreTask?.cancel()
        startupRestoreTask = nil
    }

    private func restorePreviousConnectionIfRequested() async {
        guard !isUIReviewMode else { return }
#if AETHERROUTE_QA_AUTOMATION
        if let automation = qaAutomationEnvironment["AETHERROUTE_QA_AUTOCONNECT"],
           automation == "0" || automation == "1" {
            Self.runtimeLogger.info(
                "stage=startup autoReconnect skipped reason=qaAutomationOwnsStartup"
            )
            return
        }
#endif
        guard wasConnectedBeforeTermination else {
            Self.runtimeLogger.info(
                "stage=startup autoReconnect skipped reason=wasNotConnectedBeforeTermination"
            )
            return
        }
        // prepare() runs again when a window opens and inside setEnabled
        // after a failure dropped the manager. Restarting the restore there
        // reset its attempt count, so a failure before launch (1.8.7: an
        // unknown GEOSITE category) retried twice a second at ~70% CPU
        // forever. One restore per launch keeps its 6-attempt, 120 s limits.
        guard !hasBegunStartupRestore else {
            Self.runtimeLogger.info(
                "stage=startup autoReconnect skipped reason=alreadyRestoredThisLaunch"
            )
            return
        }
        hasBegunStartupRestore = true

        cancelStartupRestore(reason: "newStartupCycle")
        startupRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executeStartupConnectionRestoration()
        }
    }

    private func executeStartupConnectionRestoration() async {
        typealias Policy = StartupConnectionRestorePolicy
        Self.runtimeLogger.info(
            "stage=startupRestore begin wasConnectedBeforeTermination=true maxAttempts=\(Policy.maximumAttempts, privacy: .public) budgetSeconds=\(Policy.overallBudget, privacy: .public)"
        )
        // At login after a reboot Wi-Fi or DHCP may still be coming up. Watch
        // the path only for the lifetime of this restore.
        let pathWatcher = StartupNetworkPathWatcher()
        defer { pathWatcher.cancel() }
        let clock = ContinuousClock()
        let startedAt = clock.now
        func elapsed() -> TimeInterval {
            let duration = clock.now - startedAt
            return TimeInterval(duration.components.seconds)
                + TimeInterval(duration.components.attoseconds) / 1e18
        }
        var attemptsMade = 0
        var lastWaitLogged: Policy.Step?

        while true {
            if Task.isCancelled {
                Self.runtimeLogger.info("stage=startupRestore aborted reason=cancelled")
                return
            }
            let step = Policy.nextStep(Policy.Snapshot(
                elapsed: elapsed(),
                attemptsMade: attemptsMade,
                wasConnectedBeforeTermination: wasConnectedBeforeTermination,
                isTerminating: isApplicationTerminating,
                isConnected: state == .connected,
                networkPathSatisfied: pathWatcher.isSatisfied,
                canStartConnection: canRestorePreviousConnection,
                automaticReconnectPending: automaticReconnectTask != nil
            ))
            switch step {
            case .finish(let reason):
                Self.runtimeLogger.info(
                    "stage=startupRestore finished reason=\(reason.rawValue, privacy: .public) attempts=\(attemptsMade, privacy: .public) elapsed=\(elapsed(), format: .fixed(precision: 1), privacy: .public) state=\(Self.diagnosticEventCode(for: self.state).rawValue, privacy: .public)"
                )
                return
            case .waitForNetwork, .waitForReadiness:
                if lastWaitLogged != step {
                    lastWaitLogged = step
                    Self.runtimeLogger.info(
                        "stage=startupRestore waiting for=\(step == .waitForNetwork ? "network" : "readiness", privacy: .public) attempts=\(attemptsMade, privacy: .public) elapsed=\(elapsed(), format: .fixed(precision: 1), privacy: .public) isPreparing=\(self.isPreparing, privacy: .public) profile=\(self.activeProfile != nil, privacy: .public) approvalRequired=\(self.systemExtensionApprovalRequired, privacy: .public) permitsStart=\(self.managerConnectionPermitsStart, privacy: .public) reconnectPending=\(self.automaticReconnectTask != nil, privacy: .public) state=\(Self.diagnosticEventCode(for: self.state).rawValue, privacy: .public)"
                    )
                }
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
            case .attempt:
                lastWaitLogged = nil
                let attempt = attemptsMade
                attemptsMade += 1
                Self.runtimeLogger.info(
                    "stage=startupRestore attempt=\(attempt, privacy: .public) triggering restore elapsed=\(elapsed(), format: .fixed(precision: 1), privacy: .public)"
                )
                await setEnabled(true)
                let outcome = await awaitStartupRestoreAttemptOutcome(clock: clock)
                Self.runtimeLogger.info(
                    "stage=startupRestore attempt=\(attempt, privacy: .public) outcome=\(String(describing: outcome), privacy: .public) state=\(Self.diagnosticEventCode(for: self.state).rawValue, privacy: .public)"
                )
                if Task.isCancelled { return }
                if outcome == .succeeded { continue }
                // Re-checked by nextStep: the user may have connected or
                // disconnected while the attempt ran.
                guard let delay = Policy.backoffDelay(
                    afterAttempts: attemptsMade,
                    elapsed: elapsed()
                ) else { continue }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    /// Waits until the attempt just submitted connects, stops, or exceeds the
    /// outcome timeout. Connecting and recovering are still in progress.
    private func awaitStartupRestoreAttemptOutcome(
        clock: ContinuousClock
    ) async -> StartupConnectionRestorePolicy.AttemptOutcome {
        let submittedAt = clock.now
        while true {
            let progress: StartupConnectionRestorePolicy.AttemptProgress = switch state {
            case .connected: .connected
            case .loading, .connecting, .recovering: .inProgress
            case .disconnected, .disconnecting, .failed, .privacyConsentRequired: .stopped
            }
            let waited = clock.now - submittedAt
            let outcome = StartupConnectionRestorePolicy.attemptOutcome(
                progress: progress,
                waited: TimeInterval(waited.components.seconds)
                    + TimeInterval(waited.components.attoseconds) / 1e18
            )
            if outcome != .pending || Task.isCancelled || isApplicationTerminating {
                return outcome
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return .pending
            }
        }
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
            guard let importTask = profileImportTask else {
                Self.runtimeLogger.error("stage=qaAutomation localProfile failed reason=notStarted")
                return
            }
            await importTask.value
            guard !profileMessageIsError else {
                Self.runtimeLogger.error("stage=qaAutomation localProfile failed reason=importFailed")
                return
            }
        } else if let subURL = qaAutomationEnvironment["AETHERROUTE_QA_SUBSCRIPTION_URL"], !subURL.isEmpty {
            Self.runtimeLogger.info(
                "stage=qaAutomation autoImport requested url=\(subURL.sanitizedURLForLogging, privacy: .private)"
            )
            _ = await addSubscription(urlText: subURL)
        }
        // Overrides from a JSON file, then the profile's text replaced the
        // way a subscription update replaces it, for the override
        // end-to-end test (1.7.0).
        if let path = qaAutomationEnvironment["AETHERROUTE_QA_OVERRIDES_PATH"],
           let data = FileManager.default.contents(atPath: path),
           let overrides = try? JSONDecoder().decode(ProfileOverride.self, from: data) {
            let saved = await setProfileOverrides(overrides, reloadsRunningProfile: false)
            Self.runtimeLogger.info("stage=qaAutomation overrides applied=\(saved, privacy: .public)")
        }
        if let path = qaAutomationEnvironment["AETHERROUTE_QA_REPLACE_PROFILE_PATH"],
           let yaml = try? String(contentsOfFile: path, encoding: .utf8),
           let id = activeProfileID, let previous = activeProfile {
            nonisolated(unsafe) let defaults = userDefaults
            let updated = ActiveProfile(name: previous.name, yaml: yaml, subscription: previous.subscription)
            do {
                try await performProductionProfileCatalogOperation {
                    try Self.replaceProfileContents(id: id, previous: previous, with: updated, defaults: defaults)
                }
                Self.runtimeLogger.info("stage=qaAutomation profileReplaced success")
            } catch {
                Self.runtimeLogger.error("stage=qaAutomation profileReplaced failed")
            }
        }
        // "Group=mode" sets a select group's node selection mode before
        // connecting, for the failover end-to-end test.
        if let spec = qaAutomationEnvironment["AETHERROUTE_QA_SELECTION_MODE"],
           let separator = spec.lastIndex(of: "="),
           let mode = ProxySelectionMode(
               rawValue: String(spec[spec.index(after: separator)...])
           ) {
            let group = String(spec[..<separator])
            await setProxySelectionMode(group: group, mode: mode)
            Self.runtimeLogger.info(
                "stage=qaAutomation selectionMode applied=\(self.proxySelectionMode(for: group).rawValue, privacy: .public)"
            )
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
        await systemExtensionActivator.recheckPendingApprovalNow()
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
        await setEnabled(enabled, isAutomaticReconnect: false, clearsUserIntent: true)
    }

    func cancelRecoveryRestart() {
        recoveryRestartTask?.cancel()
        recoveryRestartTask = nil
        recoveryRestartToken = nil
    }

    /// - Parameter isAutomaticReconnect: distinguishes a reconnect this manager
    ///   scheduled from a connect the user asked for. Only the latter restores
    ///   the retry budget; a reconnect that reset it would retry forever. This
    ///   travels as an argument rather than an instance flag because the body
    ///   suspends, and a flag could be read by a user-driven call that
    ///   interleaved with this one.
    func setEnabled(
        _ enabled: Bool,
        isAutomaticReconnect: Bool,
        clearsUserIntent: Bool = true
    ) async {
        Self.runtimeLogger.info(
            "stage=setEnabled request=\(enabled ? "connect" : "disconnect", privacy: .public) state=\(Self.diagnosticEventCode(for: self.state).rawValue, privacy: .public) engine=\(self.networkEngineMode.rawValue, privacy: .public) routing=\(self.routingMode.rawValue, privacy: .public)"
        )
        if !enabled {
            cancelStartupRestore(reason: clearsUserIntent ? "userDisconnected" : "internalRestart")
            engineReconnect.cancel()
            cancelEgressAvailabilityProbe()
            if clearsUserIntent {
                networkEngineMessage = nil
                networkEngineMessageIsError = false
                networkEngineBlockedNeedsSetup = false
            }
            // Invalidate before any guard or await. A connect request may still
            // be preparing resources even though NetworkExtension has not
            // received startVPNTunnel yet.
            invalidateConnectionRequest()
            if clearsUserIntent {
                userIntentEpoch &+= 1
                connectionGenerationToken &+= 1
                reconnectToken = nil
                cancelRecoveryRestart()
                // The user is taking over. No scheduled reconnect may outlive this,
                // or the tunnel would come back up after they asked for it down.
                userIntendsToConnect = false
                if !isApplicationTerminating && !isUIReviewMode {
                    connectionIntentStore.save(intendedConnected: false)
                }
            }
            cancelAutomaticReconnect(reason: clearsUserIntent ? "userDisconnected" : "internalRestart")
        }
        guard ensurePrivacyConsent() else { return }
        guard !enabled || distributionConnectionAccess.permitsNewConnection
        else { return }
        // Shortcuts, URL imports and the menu cannot connect around setup.
        guard !enabled || !isNetworkSetupRequired else {
            AppWindowManager.shared.showMainWindow()
            return
        }
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
                providerPermitsStart: managerConnectionPermitsStart,
                isAutomaticReconnect: isAutomaticReconnect,
                hostIsRecovering: state == .recovering
            ) else {
                Self.runtimeLogger.info(
                    "stage=setEnabled ignored reason=hostOrProviderTransitioning"
                )
                return
            }
            disconnectErrorLookupID = nil
            cancelDisconnectionWatchdog()
            cancelRecoveryWatchdog()
            // An explicit connect supersedes any reconnect still waiting out
            // its delay, and restores the full retry budget for the next drop.
            userIntendsToConnect = true
            if !isUIReviewMode {
                connectionIntentStore.save(intendedConnected: true)
            }
            if !isAutomaticReconnect {
                connectionGenerationToken &+= 1
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
                    providerPermitsStart: managerConnectionPermitsStart,
                    isAutomaticReconnect: isAutomaticReconnect,
                    hostIsRecovering: state == .recovering
                ) else {
                    Self.runtimeLogger.info(
                        "stage=setEnabled stopped reason=transitioningAfterPrepare"
                    )
                    completeConnectionRequest(newRequestID)
                    return
                }
            }
            resetConnectionReadiness()
            lastObservedProviderStatus = manager?.connection.status
            state = .connecting
        } else {
            disconnectErrorLookupID = nil
            cancelConnectionWatchdog()
            cancelDisconnectionWatchdog()
            cancelRecoveryWatchdog()
            cancelConnectionReadiness()
            guard state == .connected
                || state == .connecting
                || state == .recovering
                || (state == .loading && manager == nil) else {
                Self.runtimeLogger.info("stage=setEnabled ignored reason=notActive")
                return
            }
            if self.manager == nil {
                resetConnectionReadiness()
                connectedSince = nil
                sessionRoutingMode = nil
                sessionNetworkEngineMode = nil
                clearProxySelectionRuntimeState()
                reconcileDisconnectionStatus()
                Self.runtimeLogger.info("stage=setEnabled stoppedWithoutManager")
                return
            }
            let sampleBeforeStop = state == .connected
            if sampleBeforeStop {
                await snapshotExtensionDiagnosticLogIfNeeded()
            }
            Self.diagnosticLog.lifecycle("stage=stopVPNTunnel requested")
            // Show Disconnecting before the final sample so the click answers
            // at once; .disconnecting also keeps a connect from interleaving
            // while the sample waits.
            state = .disconnecting
            beginDisconnectionWatchdog(selfInitiated: true)
            if sampleBeforeStop {
                await recordFinalTrafficSample()
            }
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
            } else if self.manager == nil {
                cancelDisconnectionWatchdog()
                resetConnectionReadiness()
                connectedSince = nil
                sessionRoutingMode = nil
                sessionNetworkEngineMode = nil
                clearProxySelectionRuntimeState()
                reconcileDisconnectionStatus()
                return
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
                if !isUIReviewMode {
                    LANProxyServerController.shared.updateConfiguration(
                        settings: localProxySettings,
                        isTunnelConnected: false,
                        allowStandaloneLoopback: false
                    )
                }
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
                Self.diagnosticLog.lifecycle("stage=startVPNTunnel begin")
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
            Self.diagnosticLog.failure("stage=setEnabled failed error=\(String(describing: type(of: error)))")
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
                        || error is KeychainAccessGroupResolutionError
                        || error is AetherNodeProfileCompilerError
                        || error is CustomRuleGeoSiteError {
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
        if let nativeNodes = activeProfile.nativeNodes {
            // Profiles saved before 1.8.7 could name a dialer outside the
            // profile; the core then refuses it with an opaque error.
            try AetherNodeProfileCompiler.validateDialerProxies(in: nativeNodes)
        }
        Self.runtimeLogger.info("stage=prepareRuntimeResources begin")
        isUpdatingRoutingResources = true
        defer { isUpdatingRoutingResources = false }
        let rawProfileYAML = activeProfile.yaml
        let baseProfileYAML = effectiveProfileYAML(for: activeProfile)
        let requestedBypassPolicy = Self.sanitizeBypassPolicy(bypassPolicy)
        let currentCustomRules = Self.bypassDomainCustomRules(for: requestedBypassPolicy) + customRules
        let remoteRules = await ruleProviderEngine.compileActiveRules()
        let profileYAML = DomesticRoutingOptimizer.optimizedProfile(
            for: baseProfileYAML,
            customRules: currentCustomRules,
            remoteRules: remoteRules,
            enableDomesticDirect: isDomesticOptimizationEnabled
        )
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
        let requestedDNSPolicy = dnsRuntimePolicy
        let requestedEngine = networkEngineMode
        let requestedControlledListeners = requestedEngine == .tun
            ? effectiveControlledListenersForLaunch
            : []
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
                yaml: profileYAML,
                customRules: currentCustomRules
            )
            var initialSelections = InitialProxySelectionPolicy
                .selections(
                    persisted: persistedSelections,
                    summary: profileSummary
                )
            if initialSelections["GLOBAL"] == nil,
               let globalTarget = Self.resolvedGlobalTargetMember(
                   in: profileSummary,
                   persistedSelections: persistedSelections
               ) {
                initialSelections["GLOBAL"] = globalTarget
            }
            let routingResources = try store.launchResourceSnapshot(for: profileYAML)
            // The core refuses the whole rule set for one unknown GEOSITE
            // category; name the custom rule instead. Checked against the
            // database this launch actually carries, which may be newer
            // than the one bundled with the app.
            if let geoSiteData = routingResources[.geoSite],
               let unknown = try GeoSiteCategoryIndex(data: geoSiteData)
                .unknownCategories(in: currentCustomRules).first {
                throw CustomRuleGeoSiteError.unknownCategory(unknown)
            }
            let snapshot = try ProviderLaunchSnapshot(
                profileYAML: profileYAML,
                routingMode: requestedMode,
                bypassPolicy: requestedBypassPolicy,
                dnsPolicy: requestedDNSPolicy,
                proxySelections: initialSelections,
                routingResources: routingResources,
                fakeIPCacheKey: requestedEngine == .tun
                    ? try DataProtectionProfileKeyStore(
                        service: DataProtectionProfileKeyStore.fakeIPCacheService
                    ).loadOrCreateKey(keyID: "fake-ip-cache.v1")
                    : nil,
                diagnosticLogLevel: (try? DiagnosticLogLevelStore
                    .applicationGroup())?.load() ?? .off,
                controlledListeners: requestedControlledListeners.isEmpty
                    ? nil
                    : requestedControlledListeners
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

    func reconnect(isAutomatic: Bool = false) async {
        guard !isApplicationTerminating,
              !isSwitchingNetworkEngine,
              !isUpdatingProfiles else {
            return
        }
        if isAutomatic, !userIntendsToConnect {
            return
        }
        guard reconnectToken == nil else { return }
        let token = UUID()
        reconnectToken = token
        defer {
            if reconnectToken == token {
                reconnectToken = nil
            }
        }
        let intentEpoch = userIntentEpoch

        if !isConnected && !managerConnectionIsActive {
            guard !Task.isCancelled,
                  !isApplicationTerminating,
                  reconnectToken == token,
                  userIntentEpoch == intentEpoch else {
                return
            }
            if isAutomatic, !userIntendsToConnect { return }
            await setEnabled(true, isAutomaticReconnect: isAutomatic)
            return
        }

        await setEnabled(false, isAutomaticReconnect: false, clearsUserIntent: false)
        let settled = await waitForProviderToBecomeInactive()
        guard settled || managerConnectionPermitsStart,
              !Task.isCancelled,
              !isApplicationTerminating,
              reconnectToken == token,
              userIntentEpoch == intentEpoch,
              !isSwitchingNetworkEngine,
              !isUpdatingProfiles else {
            return
        }
        if isAutomatic, !userIntendsToConnect { return }
        await setEnabled(true, isAutomaticReconnect: isAutomatic)
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

    /// Nothing listens on 127.0.0.1 unless a local proxy listener (TUN loopback,
    /// Transparent Proxy standalone loopback, System Proxy, or LAN gateway) is enabled.
    var canCopyTerminalProxyCommand: Bool {
#if AETHERROUTE_INDEPENDENT
        localProxySettings.isEnabled
            || localProxySettings.allowLAN
            || localProxySettings.setAsSystemProxy
#else
        false
#endif
    }

    func resumeAfterCancelledApplicationTermination() {
        isApplicationTerminating = false
        guard !isUIReviewMode else { return }
        startSubscriptionUpdateScheduleIfNeeded()
        if state == .connected {
            startTelemetryPollingIfNeeded()
            handleSystemProxyForStateTransition(from: .disconnecting, to: .connected)
            handleMITMStateTransition(to: .connected)
        } else {
            LANProxyServerController.shared.updateConfiguration(
                settings: localProxySettings,
                isTunnelConnected: false,
                allowStandaloneLoopback: false
            )
        }
    }

    var requiresDisconnectBeforeApplicationTermination: Bool {
        managerConnectionIsActive
            || hasUnsavedTrafficSamples
            || trafficStatisticsWriter.hasPendingOperations
            || isSystemProxyActive
            || systemProxyConfigurator.hasPendingBackup
            || systemProxyCoordinator.hasPendingOperations
    }

    func prepareForApplicationTermination() {
        if !isUIReviewMode {
            connectionIntentStore.saveForApplicationTermination(
                managerIsActive: managerConnectionIsActive,
                userIntendsToConnect: userIntendsToConnect,
                alreadyTerminating: isApplicationTerminating
            )
        }
        isApplicationTerminating = true
        userIntentEpoch &+= 1
        connectionGenerationToken &+= 1
        reconnectToken = nil
        cancelRecoveryRestart()
        cancelStartupRestore(reason: "applicationTermination")
        engineReconnect.cancel()
        userIntendsToConnect = false
        cancelAutomaticReconnect(reason: "applicationTermination")
        stopTelemetryPolling()
        cancelConnectionReadiness()
        cancelConnectionWatchdog()
        cancelDisconnectionWatchdog()
        cancelRecoveryWatchdog()
        subscriptionUpdateSchedule?.cancel()
        subscriptionUpdateSchedule = nil
        runtimeEnvironmentResetTask?.cancel()
        runtimeEnvironmentResetTask = nil
        LANProxyServerController.shared.stop()
        stopExternalControllerServer()
        restoreSystemProxyIfNeeded()
    }

    /// A VPN or transparent proxy must not outlive an intentional App quit.
    /// AppKit defers termination while this completes so NetworkExtension has
    /// time to restore the system route and DNS state. If shutdown does not
    /// settle, the delegate cancels termination instead of leaving an
    /// unmanaged network extension active in the background.
    func disconnectForApplicationTermination() async -> Bool {
        prepareForApplicationTermination()
        await trafficStatisticsWriter.flush()
        guard managerConnectionIsActive else {
            await restoreSystemProxyAndWait()
            return true
        }
        let wasActive = managerConnectionIsActive || userIntendsToConnect
        Self.runtimeLogger.info(
            "stage=applicationTermination disconnect begin wasActive=\(wasActive, privacy: .public)"
        )
        await setEnabled(false)
        let stopped = await waitForProviderToBecomeInactive(
            timeout: .seconds(30)
        )
        // The disconnect took one last statistics sample; write it before
        // the process exits.
        saveTrafficLedgerIfNeeded(force: true)
        await trafficStatisticsWriter.flush()
        await restoreSystemProxyAndWait()
        Self.runtimeLogger.info(
            "stage=applicationTermination disconnect complete stopped=\(stopped, privacy: .public)"
        )
        return stopped
    }

    /// Stops any active session and detaches cached NetworkExtension state for
    /// uninstallation without writing new preferences or traffic statistics,
    /// ensuring subsequent configuration removal and process exit cannot stall.
    /// Does not mark `isApplicationTerminating = true` so the app remains healthy
    /// if the user cancels or uninstall fails.
    func prepareForUninstall() async {
        userIntentEpoch &+= 1
        connectionGenerationToken &+= 1
        reconnectToken = nil
        cancelRecoveryRestart()
        hasUnsavedTrafficSamples = false
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        cancelStartupRestore(reason: "uninstall")
        engineReconnect.cancel()
        cancelEgressAvailabilityProbe()
        userIntendsToConnect = false
        cancelAutomaticReconnect(reason: "uninstall")
        stopTelemetryPolling()
        cancelConnectionReadiness()
        cancelConnectionWatchdog()
        cancelDisconnectionWatchdog()
        cancelRecoveryWatchdog()
        subscriptionUpdateSchedule?.cancel()
        subscriptionUpdateSchedule = nil
        runtimeEnvironmentResetTask?.cancel()
        runtimeEnvironmentResetTask = nil
        LANProxyServerController.shared.stop()
        await restoreSystemProxyAndWait()

        if managerConnectionIsActive || isEnabled {
            manager?.connection.stopVPNTunnel()
            _ = await waitForProviderToBecomeInactive(timeout: .seconds(3))
        }
        invalidateCachedManager()
        state = .disconnected
    }

    func tearDownForUninstall() async {
        isApplicationTerminating = true
        await prepareForUninstall()
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

    func setLocalProxyAllowLAN(_ allowLAN: Bool) {
        updateLocalProxySettings { settings in
            settings.allowLAN = allowLAN
        }
    }

    func setSystemProxyEnabled(_ enabled: Bool) {
        updateLocalProxySettings(allowWhileConnected: true) { settings in
            settings.setAsSystemProxy = enabled
        }
    }

    func setSystemProxyBypassDomains(_ domains: [String]) {
        updateLocalProxySettings(allowWhileConnected: true) { settings in
            settings.systemProxyBypassDomains = domains
        }
    }

    private static func loadOrCreateControlURLSchemeToken(in defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: controlURLSchemeTokenPreferenceKey),
           existing.count >= 32,
           existing.allSatisfy(\.isHexDigit) {
            return existing
        }
        return generateAndStoreControlURLSchemeToken(in: defaults)
    }

    @discardableResult
    private static func generateAndStoreControlURLSchemeToken(in defaults: UserDefaults) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for idx in bytes.indices {
                bytes[idx] = UInt8.random(in: .min ... .max, using: &rng)
            }
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        defaults.set(token, forKey: controlURLSchemeTokenPreferenceKey)
        return token
    }

    @discardableResult
    func regenerateControlURLSchemeToken() -> String {
        let token = Self.generateAndStoreControlURLSchemeToken(in: userDefaults)
        controlURLSchemeToken = token
        return token
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count, !lhsBytes.isEmpty else { return false }
        var diff: UInt8 = 0
        for index in lhsBytes.indices {
            diff |= lhsBytes[index] ^ rhsBytes[index]
        }
        return diff == 0
    }

    func setControlURLSchemeEnabled(_ enabled: Bool) {
        let updated = ControlURLSchemePreferences(allowControlURLScheme: enabled)
        controlURLSchemePreferences = updated
        if !enabled {
            pendingControlURLRequest = nil
        }
        guard !isUIReviewMode else { return }
        try? controlURLSchemePreferenceStore.save(updated)
    }

    func confirmPendingControlURLAction() {
        guard let pending = pendingControlURLRequest else { return }
        pendingControlURLRequest = nil
        externalSubscriptionLinkError = nil
        executeControlURLAction(pending.action)
    }

    func cancelPendingControlURLAction() {
        pendingControlURLRequest = nil
    }

    func handleIncomingExternalURL(_ url: URL) {
        do {
            let action = try ExternalSubscriptionLinkParser.parseAction(
                url,
                allowControlActions: controlURLSchemePreferences.allowControlURLScheme
            )
            switch action {
            case .importSubscription:
                handleExternalURL(url)
            case let .control(controlAction):
                let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let tokenItems = queryItems.filter { $0.name.lowercased() == "token" }
                if tokenItems.count > 1 {
                    pendingControlURLRequest = nil
                    externalSubscriptionLinkError = AppLocalization.string("Invalid control URL token.")
                    return
                }
                if let providedToken = tokenItems.first?.value?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    guard Self.constantTimeEquals(providedToken, controlURLSchemeToken) else {
                        pendingControlURLRequest = nil
                        externalSubscriptionLinkError = AppLocalization.string("Invalid control URL token.")
                        return
                    }
                    pendingControlURLRequest = nil
                    externalSubscriptionLinkError = nil
                    executeControlURLAction(controlAction)
                } else {
                    externalSubscriptionLinkError = nil
                    pendingControlURLRequest = PendingControlURLRequest(url: url, action: controlAction)
                    AppWindowManager.shared.showMainWindow()
                }
            }
        } catch ExternalSubscriptionLinkError.controlActionsDisabled {
            pendingControlURLRequest = nil
            externalSubscriptionLinkError = AppLocalization.string("Control URL actions are disabled. Enable them in Settings > General.")
        } catch {
            pendingControlURLRequest = nil
            handleExternalURL(url)
        }
    }

    private func executeControlURLAction(_ action: ExternalControlAction) {
        switch action {
        case .connect:
            guard !isEnabled, canPerformPrimaryAction else { return }
            Task { await setEnabled(true) }
        case .disconnect:
            guard isEnabled, canPerformPrimaryAction else { return }
            Task { await setEnabled(false) }
        case .toggle:
            guard canPerformPrimaryAction else { return }
            Task { await setEnabled(!isEnabled) }
        case let .setRoutingMode(mode):
            guard routingMode != mode, canChangeRoutingMode else { return }
            Task { await setRoutingMode(mode) }
        case let .setEngineMode(mode):
            guard networkEngineMode != mode, canChangeNetworkEngine else { return }
            Task { await setNetworkEngineMode(mode) }
        case let .switchProfile(name, id):
            let matchedProfile: ManagedProfile? = if let id {
                profiles.first(where: { $0.id == id })
            } else if let name {
                profiles.first(where: {
                    $0.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare(name) == .orderedSame
                })
            } else {
                nil
            }
            guard let matchedProfile, activeProfileID != matchedProfile.id, canActivateProfile else {
                return
            }
            Task { await activateProfile(id: matchedProfile.id) }
        }
    }

    private static func resolveNonFakeAddressesWithTimeout(
        for host: String,
        timeout: Duration = .milliseconds(1_500)
    ) async -> (addresses: [String], latencyMilliseconds: Int) {
        let resolved: (addresses: [String], latencyMilliseconds: Int) = await withTaskGroup(
            of: (addresses: [String], latencyMilliseconds: Int)?.self
        ) { group in
            group.addTask {
                await DNSLookupInspector.resolveSystemAddresses(for: host)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return ([], 0)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ([], 0)
        }
        let filtered = resolved.addresses.filter { !DNSLookupInspector.isFakeIPAddress($0) }
        return (filtered, filtered.isEmpty ? 0 : resolved.latencyMilliseconds)
    }

    nonisolated static func bypassDomainCustomRules(for policy: BypassPolicy) -> [CustomRule] {
        policy.rules.compactMap { rule in
            guard rule.kind == .domainSuffix else { return nil }
            return CustomRule(
                id: rule.id,
                kind: .domainSuffix,
                value: rule.value,
                target: .direct,
                isEnabled: true
            )
        }
    }

    var effectiveRuntimeCustomRules: [CustomRule] {
        Self.bypassDomainCustomRules(for: Self.sanitizeBypassPolicy(bypassPolicy)) + customRules
    }

    var effectiveCustomHosts: [CustomHostMapping] {
        let perProfile = activeProfileOverrides.customHosts
        let global = loadGlobalProfileOverride().customHosts
        guard !global.isEmpty else { return perProfile }
        let shadowed = Set(
            perProfile.map { $0.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        let inherited = global.filter {
            !shadowed.contains($0.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return inherited + perProfile
    }

    func slicedGeoSiteData(for summary: ProfileConfigurationSummary?) -> Data? {
        guard let summary else { return bundledGeoSiteData }
        guard let index = bundledGeoSiteSliceIndex else { return bundledGeoSiteData }
        return index.slice(forRules: summary.allRules)
    }

    func traceRoute(_ request: RouteTraceRequest) async -> RouteTraceResult {
        let trimmedIP = request.ip?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = DNSLookupInspector.normalizeHost(request.host)
            ?? request.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let customHosts = effectiveCustomHosts
        let requestProfileID = activeProfileID
        let requestConnectionID = providerConnectionID

        let preResolvedAddresses = request.resolvedAddresses.filter {
            !DNSLookupInspector.isFakeIPAddress($0)
        }
        let resolvedDNS: (addresses: [String], latencyMilliseconds: Int)
        if !preResolvedAddresses.isEmpty {
            resolvedDNS = (preResolvedAddresses, 0)
        } else if isUIReviewMode || normalizedHost.isEmpty || !(trimmedIP?.isEmpty ?? true) {
            resolvedDNS = ([], 0)
        } else {
            resolvedDNS = await Self.resolveNonFakeAddressesWithTimeout(for: normalizedHost)
        }

        let mergedCustomHosts = customHosts.isEmpty ? request.customHosts : customHosts
        let forwardedRequest = RouteTraceRequest(
            host: request.host,
            ip: trimmedIP?.isEmpty == true ? nil : trimmedIP,
            port: request.port,
            network: request.network,
            processPath: request.processPath,
            resolvedAddresses: resolvedDNS.addresses,
            customHosts: mergedCustomHosts
        )

        if state == .connected,
           !isUIReviewMode,
           providerConnectionID == requestConnectionID,
           activeProfileID == requestProfileID {
            let client = makeProxySelectionProviderClient()
            if var liveResult = try? await client.traceRoute(forwardedRequest),
               state == .connected,
               providerConnectionID == requestConnectionID,
               activeProfileID == requestProfileID {
                let liveNonFake = liveResult.dnsAddresses.filter { !DNSLookupInspector.isFakeIPAddress($0) }
                let mergedDNS = liveNonFake.isEmpty ? resolvedDNS.addresses : liveNonFake
                let resolvedIsFakeIP = liveResult.isFakeIP && liveNonFake.isEmpty
                if mergedDNS != liveResult.dnsAddresses || resolvedIsFakeIP != liveResult.isFakeIP {
                    liveResult = RouteTraceResult(
                        routingMode: liveResult.routingMode,
                        matchedRuleKind: liveResult.matchedRuleKind,
                        matchedRuleCriteria: liveResult.matchedRuleCriteria,
                        matchedRuleOrder: liveResult.matchedRuleOrder,
                        targetOutbound: liveResult.targetOutbound,
                        outboundChain: liveResult.outboundChain,
                        resolvedHostAlias: liveResult.resolvedHostAlias,
                        dnsAddresses: mergedDNS,
                        dnsLatencyMilliseconds: liveResult.dnsLatencyMilliseconds
                            ?? (mergedDNS.isEmpty || resolvedDNS.latencyMilliseconds == 0
                                ? nil
                                : resolvedDNS.latencyMilliseconds),
                        isFakeIP: resolvedIsFakeIP,
                        source: .liveProvider
                    )
                }
                return liveResult
            }
        }

        let currentSelections = proxySelections.compactMapValues(\.selectedMember)
        let effectiveMode = effectiveRoutingMode
        return RouteSimulationInspector.evaluate(
            request: forwardedRequest,
            routingMode: effectiveMode,
            profileYAML: activeProfile.map { effectiveProfileYAML(for: $0) },
            summary: activeProfileSummary,
            proxySelections: currentSelections,
            customRules: effectiveRuntimeCustomRules,
            customHosts: mergedCustomHosts,
            geoSiteData: slicedGeoSiteData(for: activeProfileSummary),
            resolvedAddresses: resolvedDNS.addresses,
            dnsLatencyMilliseconds: resolvedDNS.addresses.isEmpty || resolvedDNS.latencyMilliseconds == 0
                ? nil
                : resolvedDNS.latencyMilliseconds,
            source: .staticFallback
        )
    }

    func installLANProxyCallbacks() {
        LANProxyServerController.shared.onListenerReady = { [weak self] in
            guard let self, !self.isUIReviewMode, !self.isApplicationTerminating else { return }
            if self.state == .connected && self.localProxySettings.setAsSystemProxy {
                self.applySystemProxyIfNeeded()
            }
        }
        LANProxyServerController.shared.onListenerFailure = { [weak self] port, error in
            guard let self, !self.isUIReviewMode else { return }
            self.handleLocalProxyListenerFailure(port: port, error: error)
        }
    }

    func handleLocalProxyListenerFailure(port: Int, error: Error) {
        let wasSystemProxyRequested = localProxySettings.setAsSystemProxy || isSystemProxyActive
        isSystemProxyActive = false
        if wasSystemProxyRequested {
            restoreSystemProxyIfNeeded()
        }
        localProxySettingsMessage = AppLocalization.format(
            "Local proxy port %@ is already in use or failed to bind (%@). System Proxy has been rolled back.",
            String(port),
            localizedLocalProxyError(error)
        )
    }

    static func localizedLANProxyStatusFailure(_ failure: LANProxyStatusFailure) -> String {
        switch failure.kind {
        case let .portInUse(port):
            return AppLocalization.format("Port %@ is already in use by another app.", String(port))
        case let .invalidPort(port):
            return AppLocalization.format("Port %@ is not valid.", String(port))
        case let .permissionDenied(port):
            return AppLocalization.format("Permission was denied to listen on port %@.", String(port))
        case .invalidHandshake:
            return AppLocalization.string("Invalid proxy handshake.")
        case let .remoteConnectionFailed(reason):
            return AppLocalization.format("Remote connection failed: %@", reason)
        case let .listenerFailed(port, detail):
            return AppLocalization.format("Port %@ could not start: %@", String(port), detail)
        }
    }

    func localizedLANProxyStatusFailure(_ failure: LANProxyStatusFailure) -> String {
        Self.localizedLANProxyStatusFailure(failure)
    }

    func tunnelOwnsLoopbackListener(for settings: LocalProxySettings) -> Bool {
        networkEngineMode == .tun && !settings.allowLAN
    }

    func handleSystemProxyForStateTransition(from oldState: State, to newState: State) {
        guard !isUIReviewMode else { return }
        switch newState {
        case .connected:
            if !dnsRuntimePolicyMessageIsError {
                dnsRuntimePolicyMessage = nil
            }
            installLANProxyCallbacks()
            let usesHostProxyListener = !tunnelOwnsLoopbackListener(for: localProxySettings)
            if usesHostProxyListener,
               localProxySettings.allowLAN || localProxySettings.setAsSystemProxy || localProxySettings.isEnabled {
                LANProxyServerController.shared.updateConfiguration(
                    settings: localProxySettings,
                    isTunnelConnected: true,
                    allowStandaloneLoopback: networkEngineMode == .transparent
                )
            } else {
                LANProxyServerController.shared.updateConfiguration(
                    settings: localProxySettings,
                    isTunnelConnected: false,
                    allowStandaloneLoopback: false
                )
            }
            if localProxySettings.setAsSystemProxy {
                applySystemProxyIfNeeded()
            }
        case .recovering, .connecting, .disconnecting:
            if !dnsRuntimePolicyMessageIsError {
                dnsRuntimePolicyMessage = nil
            }
            if isSystemProxyActive || oldState == .connected {
                isSystemProxyActive = false
                restoreSystemProxyIfNeeded()
            }
            LANProxyServerController.shared.updateConfiguration(
                settings: localProxySettings,
                isTunnelConnected: false,
                allowStandaloneLoopback: false
            )
        case .disconnected, .failed:
            let wasActive = switch oldState {
            case .connected, .connecting, .recovering, .disconnecting: true
            default: isSystemProxyActive
            }
            if wasActive {
                isSystemProxyActive = false
                restoreSystemProxyIfNeeded()
            }
            LANProxyServerController.shared.updateConfiguration(
                settings: localProxySettings,
                isTunnelConnected: false,
                allowStandaloneLoopback: false
            )
        case .privacyConsentRequired, .loading:
            LANProxyServerController.shared.updateConfiguration(
                settings: localProxySettings,
                isTunnelConnected: false,
                allowStandaloneLoopback: false
            )
        }
    }

    func applySystemProxyIfNeeded(settings overrideSettings: LocalProxySettings? = nil) {
        let settings = overrideSettings ?? localProxySettings
        guard !isUIReviewMode,
              !isApplicationTerminating,
              state == .connected,
              settings.setAsSystemProxy else {
            isSystemProxyActive = false
            return
        }
        if !tunnelOwnsLoopbackListener(for: settings) {
            guard LANProxyServerController.shared.isReady else {
                isSystemProxyActive = false
                return
            }
        }
        systemProxyGeneration &+= 1
        let generation = systemProxyGeneration
        let configurator = systemProxyConfigurator
        systemProxyCoordinator.enqueueApply(settings: settings, configurator: configurator) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.systemProxyGeneration == generation else { return }
                guard self.state == .connected, !self.isApplicationTerminating else {
                    self.isSystemProxyActive = false
                    self.restoreSystemProxyIfNeeded()
                    return
                }
                if let error {
                    self.isSystemProxyActive = false
                    self.localProxySettingsMessage = error.localizedDescription
                    Self.runtimeLogger.error(
                        "stage=systemProxy apply failed error=\(error.localizedDescription, privacy: .public)"
                    )
                } else {
                    self.isSystemProxyActive = true
                }
            }
        }
    }

    func restoreSystemProxyIfNeeded() {
        isSystemProxyActive = false
        guard !isUIReviewMode else {
            return
        }
        systemProxyGeneration &+= 1
        let generation = systemProxyGeneration
        let configurator = systemProxyConfigurator
        systemProxyCoordinator.enqueueRestore(configurator: configurator) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.systemProxyGeneration == generation else { return }
                if let error {
                    Self.runtimeLogger.error(
                        "stage=systemProxy restore failed error=\(error.localizedDescription, privacy: .public)"
                    )
                } else {
                    self.isSystemProxyActive = false
                }
            }
        }
    }

    func restoreSystemProxyAndWait() async {
        guard !isUIReviewMode else {
            isSystemProxyActive = false
            return
        }
        systemProxyGeneration &+= 1
        let generation = systemProxyGeneration
        let configurator = systemProxyConfigurator
        let error = await systemProxyCoordinator.restoreAndWait(configurator: configurator)
        guard systemProxyGeneration == generation else { return }
        if let error {
            Self.runtimeLogger.error(
                "stage=systemProxy restore failed error=\(error.localizedDescription, privacy: .public)"
            )
        } else {
            isSystemProxyActive = false
        }
    }

    func setDomesticOptimizationEnabled(_ enabled: Bool) {
        isDomesticOptimizationEnabled = enabled
        DomesticRoutingOptimizer.setEnabled(enabled)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshActiveProfileSummaryOffMainActor()
            if self.state == .connected, !self.isUIReviewMode {
                await self.reloadCustomRulesLive()
            }
        }
    }

    func setUnifiedDelayEnabled(_ enabled: Bool) {
        isUnifiedDelayEnabled = enabled
        userDefaults.set(enabled, forKey: Self.unifiedDelayPreferenceKey)
        if userDefaults !== UserDefaults.standard {
            UserDefaults.standard.set(enabled, forKey: Self.unifiedDelayPreferenceKey)
        }
    }

    func setDNSRuntimePolicy(_ policy: DNSRuntimePolicy) async {
        guard canModifyDNSRuntimePolicy else { return }
        if isUpdatingDNSRuntimePolicy {
            pendingDNSRuntimePolicy = policy
            return
        }
        guard activeProfile != nil else { return }
        pendingDNSRuntimePolicy = policy
        isUpdatingDNSRuntimePolicy = true
        defer {
            isUpdatingDNSRuntimePolicy = false
            pendingDNSRuntimePolicy = nil
        }
        while let nextPolicy = pendingDNSRuntimePolicy {
            pendingDNSRuntimePolicy = nil
            guard !isTransitioning, let currentActive = activeProfile else { break }
            let previousPolicy = dnsRuntimePolicy
            do {
                let profileYAML = currentActive.yaml
                if !isUIReviewMode {
                    try await Task.detached(priority: .userInitiated) {
                        try DNSRuntimePolicyStore.applicationGroup().save(
                            nextPolicy,
                            forProfileYAML: profileYAML
                        )
                    }.value
                }
                dnsRuntimePolicy = nextPolicy
                if !isUIReviewMode, state == .connected, networkEngineMode == .tun {
                    do {
                        let currentRoutingMode = sessionRoutingMode ?? routingMode
                        let preparedReload = try await prepareReloadProfilePayload(
                            requestedMode: currentRoutingMode
                        )
                        let client = makeProxySelectionProviderClient()
                        try await reloadActiveProfileStagingResources(
                            preparedReload,
                            via: client,
                            strategy: .hotReloadRulesOnly
                        )
                        await syncGlobalSelector(client: client)
                        dnsRuntimePolicyMessage = nextPolicy.isInherited
                            ? AppLocalization.string("DNS behavior restored to follow the profile and applied immediately.")
                            : AppLocalization.string("DNS adjustments updated and applied immediately.")
                    } catch {
                        if !isUIReviewMode {
                            try? await Task.detached(priority: .userInitiated) {
                                try DNSRuntimePolicyStore.applicationGroup().save(
                                    previousPolicy,
                                    forProfileYAML: profileYAML
                                )
                            }.value
                        }
                        dnsRuntimePolicy = previousPolicy
                        throw error
                    }
                } else {
                    dnsRuntimePolicyMessage = nextPolicy.isInherited
                        ? AppLocalization.string("DNS behavior will follow the active profile on the next TUN connection.")
                        : AppLocalization.string("DNS overrides will apply on the next TUN connection.")
                }
                dnsRuntimePolicyMessageIsError = false
            } catch {
                dnsRuntimePolicyMessage = localizedLocalProxyError(error)
                dnsRuntimePolicyMessageIsError = true
            }
        }
    }

    func setRoutingMode(_ mode: RoutingMode) async {
        guard ensurePrivacyConsent(), canChangeRoutingMode else { return }
        guard mode != routingMode || sessionRoutingMode != mode else { return }
        cancelEgressAvailabilityProbe()

        if state != .connected {
            routingMode = mode
            sessionRoutingMode = nil
            routingModeMessage = nil
            routingModeMessageIsError = false
            if mode == .global {
                seedGlobalSelectionIfNeeded()
            }
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
                if mode == .global {
                    seedGlobalSelectionIfNeeded()
                }
                applied = mode
            } else {
                guard let client else {
                    throw TunnelManagerError.providerSessionUnavailable
                }
                if mode == .global {
                    await syncGlobalSelector(client: client)
                }
                applied = try await client.setRoutingMode(mode)
            }
            guard state == .connected, providerConnectionID == connectionID
            else { return }
            routingMode = applied
            sessionRoutingMode = applied
            if let closeRequest = ProxySelectionHotSwitchPolicy.routingModeCloseRequest(
                previousMode: previousMode,
                newMode: applied,
                closesConnectionsOnSwitch: closesConnectionsOnProxySwitch
            ) {
                await closeConnections(closeRequest)
            }
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
        let lastUpdatedAt: Date?
        let yamlLength: Int
        let overrides: ProfileOverride?
    }

    var currentLatencyRunToken: LatencyRunToken? {
        activeProfile.map {
            LatencyRunToken(
                profileName: $0.name,
                importedAt: $0.importedAt,
                lastUpdatedAt: $0.subscription?.lastUpdatedAt,
                yamlLength: $0.yaml.utf8.count,
                overrides: $0.overrides
            )
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

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
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

    var effectiveRoutingMode: RoutingMode {
        state == .connected ? (sessionRoutingMode ?? routingMode) : routingMode
    }

    var canChangeRoutingMode: Bool {
        let statePermitsChange = switch state {
        case .disconnected, .connected, .failed: true
        case .privacyConsentRequired, .loading, .connecting, .recovering, .disconnecting: false
        }
        return hasAcceptedPrivacyDisclosure
            && !isNetworkSetupRequired
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
            && !isNetworkSetupRequired
            && statePermitsChange
            && (!isPreparing || systemExtensionApprovalRequired)
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
            && !isNetworkSetupRequired
            && statePermitsChange
            && (!isPreparing || systemExtensionApprovalRequired)
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

    /// Why `canModifyProfiles` is false, for controls that would otherwise
    /// sit disabled without explanation. Nil when changes are allowed.
    var profileEditLockReason: String? {
        guard !canModifyProfiles else { return nil }
        if !hasAcceptedPrivacyDisclosure {
            return AppLocalization.string("Accept the privacy notice to make changes.")
        }
        if isTransitioning {
            return AppLocalization.string("The connection is changing state…")
        }
        if isEnabled {
            return AppLocalization.string("Can't change while connected. Disconnect to adjust; changes apply on the next connection.")
        }
        return AppLocalization.string("Saving other changes…")
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
        canModifyInactiveProfiles
    }

    var bypassPolicyLockReason: String? {
        guard !canModifyBypassPolicy else { return nil }
        if !hasAcceptedPrivacyDisclosure {
            return AppLocalization.string("Accept the privacy notice to make changes.")
        }
        if isTransitioning {
            return AppLocalization.string("The connection is changing state…")
        }
        return AppLocalization.string("Saving other changes…")
    }

    var canModifyDNSRuntimePolicy: Bool {
        hasAcceptedPrivacyDisclosure
            && !isTransitioning
            && !isRefreshingSubscription
            && !isImportingProfile
            && !isUpdatingProfiles
            && !isUpdatingBypassPolicy
            && !isTransferringProfiles
            && !isUpdatingRoutingMode
            && !isSwitchingNetworkEngine
            && !isUpdatingRoutingResources
            && proxySelectionRequests.isEmpty
            && activeProfile != nil
    }

    var dnsRuntimeEditLockReason: String? {
        guard !canModifyDNSRuntimePolicy else { return nil }
        if !hasAcceptedPrivacyDisclosure {
            return AppLocalization.string("Accept the privacy notice to make changes.")
        }
        if isTransitioning {
            return AppLocalization.string("The connection is changing state…")
        }
        return AppLocalization.string("Saving other changes…")
    }

    var canModifyLocalProxySettings: Bool {
        canChangeNetworkEngine
    }

    var canPerformPrimaryAction: Bool {
        if isNetworkSetupRequired { return false }
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

    /// One or two words for narrow places (sidebar, menu bar header). The
    /// full sentence stays in `statusTitle`; a 200 pt sidebar wrapped
    /// "Traffic routing active" onto two lines.
    var compactStatusTitle: String {
        if systemExtensionApprovalRequired {
            return AppLocalization.string("Needs approval")
        }
        if isSwitchingNetworkEngine {
            return AppLocalization.string("Switching")
        }
        return switch state {
        case .privacyConsentRequired: AppLocalization.string("Privacy review")
        case .loading: AppLocalization.string("Preparing")
        case .disconnected where !distributionConnectionAccess.permitsNewConnection:
            AppLocalization.string("License required")
        case .disconnected: AppLocalization.string("Not connected")
        case .connecting: AppLocalization.string("Connecting")
        case .recovering: AppLocalization.string("Recovering")
        case .connected where isAutomaticRouteRecovering: AppLocalization.string("Recovering")
        case .connected: AppLocalization.string("Connected")
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
            AppLocalization.string("The saved license has expired. Review Settings > About.")
        case .free, .unrestrictedDevelopment, .authorized, .authorizedUntil:
            AppLocalization.string("Traffic is using the normal network path")
        case .activationRequired:
            AppLocalization.string("Activate AetherRoute in Settings > About before connecting.")
        case .restricted(.expired):
            AppLocalization.string("The saved license has expired. Review Settings > About.")
        case .restricted(.revoked):
            AppLocalization.string("The saved license was revoked. Review Settings > About.")
        case .restricted(.deviceLimit):
            AppLocalization.string("This license reached its device limit. Review Settings > About.")
        case .restricted(.active):
            AppLocalization.string("The saved license cannot authorize a connection. Review Settings > About.")
        case .verificationUnavailable:
            AppLocalization.string("The saved license cannot be verified. Review Settings > About.")
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

    var canRefreshAnySubscription: Bool {
        let statePermitsRefresh = switch state {
        case .disconnected, .connected, .failed: true
        case .privacyConsentRequired, .loading, .connecting, .recovering, .disconnecting: false
        }
        return hasAcceptedPrivacyDisclosure
            && statePermitsRefresh
            && !isTransitioning
            && !isRefreshingSubscription
            && !isImportingProfile
            && !isUpdatingProfiles
            && !isTransferringProfiles
            && !isSwitchingNetworkEngine
    }

    func canRefreshSubscription(id: UUID) -> Bool {
        canRefreshAnySubscription
            && !refreshingSubscriptionProfileIDs.contains(id)
            && profiles.contains(where: { $0.id == id && $0.profile.subscription != nil })
    }

    nonisolated static func resolvedPrimaryRoutingGroup(
        in summary: ProfileConfigurationSummary
    ) -> ProxyGroupConfigurationSummary? {
        for rule in summary.allRules.reversed() {
            let kind = rule.kind.uppercased()
            guard kind == "MATCH" || kind == "FINAL" else { continue }
            if let group = summary.proxyGroups.first(where: {
                $0.name == rule.target && $0.name != "GLOBAL"
            }) {
                return group
            }
        }
        return summary.proxyGroups.first(where: {
            $0.strategy.caseInsensitiveCompare("select") == .orderedSame
                && $0.name != "GLOBAL"
        }) ?? summary.proxyGroups.first(where: { $0.name != "GLOBAL" })
            ?? summary.proxyGroups.first
    }

    func resolvedPrimaryRoutingGroup() -> ProxyGroupConfigurationSummary? {
        activeProfileSummary.flatMap(Self.resolvedPrimaryRoutingGroup(in:))
    }

    nonisolated static func validGlobalSelectorMembers(
        in summary: ProfileConfigurationSummary
    ) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        func append(_ item: String) {
            let upper = item.uppercased()
            guard !item.isEmpty,
                  item != "GLOBAL",
                  upper != "DIRECT",
                  upper != "REJECT",
                  upper != "REJECT-DROP",
                  seen.insert(item).inserted else { return }
            ordered.append(item)
        }
        if let explicitGlobal = summary.proxyGroups.first(where: { $0.name == "GLOBAL" }) {
            explicitGlobal.members.forEach(append)
        }
        for group in summary.proxyGroups where group.name != "GLOBAL" {
            append(group.name)
        }
        for proxy in summary.proxies {
            append(proxy.name)
        }
        return ordered
    }

    nonisolated static func resolvedGlobalTargetMember(
        in summary: ProfileConfigurationSummary,
        persistedSelections: [String: String] = [:],
        inMemorySelection: String? = nil
    ) -> String? {
        let validMembers = validGlobalSelectorMembers(in: summary)
        let validSet = Set(validMembers)
        if let inMemorySelection, validSet.contains(inMemorySelection) {
            return inMemorySelection
        }
        if let persisted = persistedSelections["GLOBAL"], validSet.contains(persisted) {
            return persisted
        }
        if let primaryGroup = resolvedPrimaryRoutingGroup(in: summary),
           validSet.contains(primaryGroup.name) {
            return primaryGroup.name
        }
        return validMembers.first
    }

    var menuGlobalProxyGroup: ProxyGroupConfigurationSummary? {
        guard let summary = activeProfileSummary else { return nil }
        let liveFiltered = (proxySelections["GLOBAL"]?.members ?? []).filter { member in
            let upper = member.uppercased()
            return member != "GLOBAL"
                && upper != "DIRECT"
                && upper != "REJECT"
                && upper != "REJECT-DROP"
        }
        let members = liveFiltered.isEmpty
            ? Self.validGlobalSelectorMembers(in: summary)
            : liveFiltered
        guard !members.isEmpty else { return nil }
        return ProxyGroupConfigurationSummary(
            id: -1,
            name: "GLOBAL",
            strategy: "select",
            memberCount: members.count,
            members: members
        )
    }

    func seedGlobalSelectionIfNeeded() {
        guard let summary = activeProfileSummary else { return }
        let persisted: [String: String]
        if !isUIReviewMode,
           let yaml = activeProfile?.yaml,
           let stored = try? ProxySelectionStore.applicationGroup().selections(forProfileYAML: yaml) {
            persisted = stored
        } else {
            persisted = [:]
        }
        guard let target = Self.resolvedGlobalTargetMember(
            in: summary,
            persistedSelections: persisted,
            inMemorySelection: proxySelections["GLOBAL"]?.selectedMember
        ) else { return }
        let members = Self.validGlobalSelectorMembers(in: summary)
        let next = ProxySelectionState(selectedMember: target, members: members)
        if proxySelections["GLOBAL"] != next {
            proxySelections["GLOBAL"] = next
        }
    }

    func syncGlobalSelector(
        client: ProxySelectionProviderClient,
        summary: ProfileConfigurationSummary? = nil
    ) async {
        guard let effectiveSummary = summary ?? activeProfileSummary else { return }
        let persisted: [String: String]
        if !isUIReviewMode,
           let yaml = activeProfile?.yaml,
           let stored = try? await Task.detached(priority: .utility, operation: {
               try ProxySelectionStore.applicationGroup().selections(forProfileYAML: yaml)
           }).value {
            persisted = stored
        } else {
            persisted = [:]
        }
        guard let target = Self.resolvedGlobalTargetMember(
            in: effectiveSummary,
            persistedSelections: persisted,
            inMemorySelection: proxySelections["GLOBAL"]?.selectedMember
        ) else { return }
        if let snapshot = try? await client.select(group: "GLOBAL", member: target) {
            let filteredMembers = snapshot.members.filter { member in
                let upper = member.uppercased()
                return member != "GLOBAL"
                    && upper != "DIRECT"
                    && upper != "REJECT"
                    && upper != "REJECT-DROP"
            }
            let normalized = ProxySelectionState(
                selectedMember: snapshot.selectedMember,
                members: filteredMembers.isEmpty ? Self.validGlobalSelectorMembers(in: effectiveSummary) : filteredMembers
            )
            if proxySelections["GLOBAL"] != normalized {
                proxySelections["GLOBAL"] = normalized
            }
        }
    }

    func setProxySelectionMode(
        _ mode: ProxySelectionMode,
        for groupName: String
    ) async {
        await setProxySelectionMode(group: groupName, mode: mode)
    }

    func selectGlobalOutlet(_ member: String) async {
        if selectableProxyGroup(named: "GLOBAL") != nil {
            await selectProxy(group: "GLOBAL", member: member)
            return
        }
        guard let globalGroup = menuGlobalProxyGroup,
              globalGroup.members.contains(member),
              !proxySelectionRequests.contains("GLOBAL") else { return }
        cancelEgressAvailabilityProbe()
        proxySelectionRequests.insert("GLOBAL")
        defer { proxySelectionRequests.remove("GLOBAL") }

        let previousMember = proxySelections["GLOBAL"]?.selectedMember
        if state == .connected {
            if isUIReviewMode {
                proxySelections["GLOBAL"] = ProxySelectionState(
                    selectedMember: member,
                    members: globalGroup.members
                )
                return
            }
            let connectionID = providerConnectionID
            let client = ProxySelectionProviderClient { [weak self] data in
                guard let self else {
                    throw TunnelManagerError.providerSessionUnavailable
                }
                return try await self.sendProviderMessage(data, for: connectionID)
            }
            do {
                let selected = try await client.select(group: "GLOBAL", member: member)
                guard state == .connected, providerConnectionID == connectionID else { return }
                let normalized = ProxySelectionState(
                    selectedMember: selected.selectedMember,
                    members: globalGroup.members
                )
                proxySelections["GLOBAL"] = normalized
                if let yaml = activeProfile?.yaml {
                    try? await Task.detached(priority: .utility) {
                        try ProxySelectionStore.applicationGroup().recordUserSelection(
                            group: "GLOBAL",
                            member: member,
                            allowedMembers: globalGroup.members,
                            profileYAML: yaml
                        )
                    }.value
                }
                if previousMember != member {
                    await closeConnectionsAfterProxySwitch(
                        group: "GLOBAL",
                        previousMember: previousMember,
                        newMember: member
                    )
                }
            } catch {
                proxySelectionMessages["GLOBAL"] = error.localizedDescription
            }
        } else {
            let next = ProxySelectionState(
                selectedMember: member,
                members: globalGroup.members
            )
            if proxySelections["GLOBAL"] != next {
                proxySelections["GLOBAL"] = next
            }
            if !isUIReviewMode, let yaml = activeProfile?.yaml {
                try? await Task.detached(priority: .userInitiated) {
                    try ProxySelectionStore.applicationGroup().recordUserSelection(
                        group: "GLOBAL",
                        member: member,
                        allowedMembers: globalGroup.members,
                        profileYAML: yaml
                    )
                }.value
            }
        }
    }

    func resolvedLeafNode(from member: String, maxDepth: Int = 6) -> String {
        var current = member
        var visited: Set<String> = [current]
        for _ in 0..<maxDepth {
            if let autoLeaf = automaticGroupLeaves[current],
               !autoLeaf.isEmpty,
               visited.insert(autoLeaf).inserted {
                current = autoLeaf
                continue
            }
            if let selected = proxySelections[current]?.selectedMember,
               !selected.isEmpty,
               visited.insert(selected).inserted {
                current = selected
                continue
            }
            if let group = activeProfileSummary?.proxyGroups.first(where: { $0.name == current }),
               let first = group.members.first,
               !first.isEmpty,
               visited.insert(first).inserted {
                current = first
                continue
            }
            break
        }
        return current
    }

    func resolvedOutletLatencyStatus(
        groupName: String,
        selectedMember: String
    ) -> (status: ProxyLatencyStatus, confidence: ProxyLatencyConfidence) {
        let leaf = resolvedLeafNode(from: selectedMember)
        var candidateGroups: [String] = []
        for candidate in [groupName, selectedMember] where !candidate.isEmpty && !candidateGroups.contains(candidate) {
            candidateGroups.append(candidate)
        }
        for group in activeProfileSummary?.proxyGroups ?? [] where !candidateGroups.contains(group.name) {
            if group.members.contains(leaf) || proxyLatencies[group.name]?.results.contains(where: { $0.member == leaf }) == true {
                candidateGroups.append(group.name)
            }
        }
        for candidateGroup in candidateGroups {
            let status = ProxyLatencyStatus.status(
                member: leaf,
                results: proxyLatencies[candidateGroup]?.results,
                isTesting: isTestingLatency(group: candidateGroup, member: leaf)
            )
            if status != .untested {
                return (status, latencyConfidence(group: candidateGroup, member: leaf))
            }
        }
        let fallbackStatus = ProxyLatencyStatus.status(
            member: selectedMember,
            results: proxyLatencies[groupName]?.results,
            isTesting: isTestingLatency(group: groupName, member: selectedMember)
        )
        return (fallbackStatus, latencyConfidence(group: groupName, member: selectedMember))
    }

    func recordSubscriptionUpdateError(_ message: String?, for profileID: UUID) {
        if let message, !message.isEmpty {
            subscriptionUpdateErrors[profileID] = SubscriptionUpdateFailureRecord(
                message: message,
                occurredAt: Date()
            )
        } else {
            subscriptionUpdateErrors.removeValue(forKey: profileID)
        }
        let encodedPayload: [String: SubscriptionUpdateFailureRecord] = Dictionary(
            uniqueKeysWithValues: subscriptionUpdateErrors.map { ($0.key.uuidString, $0.value) }
        )
        if encodedPayload.isEmpty {
            userDefaults.removeObject(forKey: Self.subscriptionUpdateErrorsPreferenceKey)
        } else if let data = try? JSONEncoder().encode(encodedPayload) {
            userDefaults.set(data, forKey: Self.subscriptionUpdateErrorsPreferenceKey)
        }
    }

    nonisolated static func loadSubscriptionUpdateErrors(
        from defaults: UserDefaults
    ) -> [UUID: SubscriptionUpdateFailureRecord] {
        guard let data = defaults.data(forKey: subscriptionUpdateErrorsPreferenceKey),
              let raw = try? JSONDecoder().decode([String: SubscriptionUpdateFailureRecord].self, from: data)
        else { return [:] }
        var resolved: [UUID: SubscriptionUpdateFailureRecord] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) {
                resolved[id] = value
            }
        }
        return resolved
    }

    static let networkEnginePreferenceKey =
        "AetherRoute.NetworkEngineMode"
    nonisolated static let unifiedDelayPreferenceKey =
        "aetherroute.latency.unifiedDelayEnabled"
    nonisolated static let subscriptionUpdateErrorsPreferenceKey =
        "aetherroute.subscription.lastUpdateErrors.v1"
    static let selectorLatencyTestURL =
        ProxyConnectionReadinessPolicy.requiredExternalProbeURLString
    public static let defaultLatencyTestURL =
        "http://cp.cloudflare.com/generate_204"
    public static let uiLatencyTimeoutMilliseconds: UInt32 = 5_000

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

    static func sanitizeBypassPolicy(_ policy: BypassPolicy) -> BypassPolicy {
        let filtered = policy.rules.filter { rule in
            if rule.kind == .ipv4CIDR || rule.kind == .ipv6CIDR {
                let addr = rule.value.split(separator: "/").first.map(String.init) ?? rule.value
                if PacketTunnelNetworkSettingsPlan.isVirtualOverlayRoute(destinationAddress: addr) {
                    return false
                }
            }
            return true
        }
        return BypassPolicy(rules: filtered)
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

#if DEBUG
extension TunnelManager {
    /// The "large" review profile: 500 nodes in one group and 10,000 rules,
    /// for measuring the lists. Generated, never bundled.
    static let largeReviewProfileYAML: String = {
        let kinds = ["vmess", "trojan", "vless", "ss", "hysteria2"]
        let regions = ["Singapore", "Tokyo", "Hong Kong", "US West", "Frankfurt", "London", "Taipei", "Seoul"]
        var lines = ["proxies:"]
        var names: [String] = []
        for index in 0..<500 {
            let name = "\(regions[index % regions.count]) \(index + 1)"
            names.append(name)
            lines.append("  - {name: \(name), type: \(kinds[index % kinds.count])}")
        }
        lines.append("proxy-groups:")
        lines.append("  - {name: Balanced, type: select, proxies: [\(names.joined(separator: ", "))]}")
        lines.append("rules:")
        for index in 0..<10_000 {
            switch index % 4 {
            case 0: lines.append("  - DOMAIN-SUFFIX,site\(index).example,Balanced")
            case 1: lines.append("  - DOMAIN,api\(index).example,DIRECT")
            case 2: lines.append("  - IP-CIDR,10.\(index / 256 % 256).\(index % 256).0/24,DIRECT,no-resolve")
            default: lines.append("  - DOMAIN-KEYWORD,kw\(index),Balanced")
            }
        }
        lines.append("  - MATCH,DIRECT")
        return lines.joined(separator: "\n")
    }()
}

extension TunnelManager {
    /// The "showcase" review profile behind the website's screenshots.
    static let showcaseReviewNodes: [(name: String, type: String, delay: Int)] = [
        ("Hong Kong 01", "vless", 38),
        ("Hong Kong 02", "hysteria2", 42),
        ("Taipei 01", "hysteria2", 49),
        ("Tokyo 01", "trojan", 61),
        ("Tokyo 02", "vless", 58),
        ("Singapore 01", "vmess", 74),
        ("Seoul 01", "trojan", 83),
        ("Los Angeles 01", "vless", 162),
        ("San Jose 01", "ss", 171),
        ("London 01", "trojan", 205),
        ("Frankfurt 01", "ss", 198),
    ]

    static let showcaseReviewProfileYAML: String = {
        let names = showcaseReviewNodes.map(\.name)
        var lines = [
            "dns:",
            "  enable: true",
            "  ipv6: true",
            "  respect-rules: true",
            "  enhanced-mode: fake-ip",
            "  fake-ip-range: 198.18.0.1/16",
            "  nameserver: [https://1.1.1.1/dns-query, tls://9.9.9.9:853]",
            "  fallback: [tcp://8.8.8.8:53]",
            "  default-nameserver: [1.0.0.1]",
            "proxies:",
        ]
        lines += showcaseReviewNodes.map { "  - {name: \($0.name), type: \($0.type)}" }
        lines += [
            "proxy-groups:",
            "  - {name: Balanced, type: select, proxies: [\(names.joined(separator: ", "))]}",
            "  - {name: Auto, type: url-test, proxies: [\(names.prefix(7).joined(separator: ", "))], url: 'https://www.gstatic.com/generate_204', interval: 300}",
            "  - {name: Streaming, type: fallback, proxies: [Hong Kong 02, Taipei 01, Tokyo 02, Singapore 01], url: 'https://www.gstatic.com/generate_204', interval: 300}",
            "rules:",
            "  - GEOSITE,category-ads-all,REJECT",
            "  - DOMAIN-SUFFIX,youtube.com,Streaming",
            "  - DOMAIN-SUFFIX,netflix.com,Streaming",
            "  - DOMAIN-SUFFIX,anthropic.com,Balanced",
            "  - DOMAIN-SUFFIX,claude.ai,Balanced",
            "  - DOMAIN-KEYWORD,openai,Balanced",
            "  - GEOSITE,github,Auto",
            "  - GEOSITE,google,Auto",
            "  - DOMAIN-SUFFIX,apple.com,DIRECT",
            "  - DOMAIN-SUFFIX,icloud.com,DIRECT",
            "  - DOMAIN-SUFFIX,bilibili.com,DIRECT",
            "  - DOMAIN-SUFFIX,taobao.com,DIRECT",
            "  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
            "  - GEOSITE,cn,DIRECT",
            "  - GEOIP,CN,DIRECT,no-resolve",
            "  - MATCH,Balanced",
        ]
        return lines.joined(separator: "\n")
    }()

    /// Failover mode on a backup: the first node is preferred and down, the
    /// second carries traffic, and two earlier switches are on record.
    func installReviewFailover() {
        guard let selection = proxySelections["Balanced"],
              selection.members.count > 1 else { return }
        let preferred = selection.members[0]
        let backup = selection.members[1]
        applyProxySelectionModes(["Balanced": .failover])
        preferredProxyMembers["Balanced"] = preferred
        proxySelections["Balanced"] = ProxySelectionState(
            selectedMember: backup,
            members: selection.members
        )
        if let latency = proxyLatencies["Balanced"] {
            proxyLatencies["Balanced"] = ProxyLatencyState(
                results: latency.results.map {
                    $0.member == preferred
                        ? ProxyLatencyResult(member: preferred, delayMilliseconds: nil)
                        : $0
                }
            )
        }
        let base = Date(timeIntervalSince1970: 1_775_005_320)
        proxySwitchLog = ProxySwitchLog(events: [
            ProxySwitchEvent(
                date: base,
                group: "Balanced",
                from: preferred,
                to: backup,
                reason: .unresponsive
            ),
            ProxySwitchEvent(
                date: base.addingTimeInterval(-3_480),
                group: "Balanced",
                from: backup,
                to: preferred,
                reason: .preferredRecovered
            ),
        ])
    }

    func installShowcaseReviewSelections() {
        let nodes = Self.showcaseReviewNodes
        let latencies = ProxyLatencyState(
            results: nodes.map {
                ProxyLatencyResult(member: $0.name, delayMilliseconds: UInt32($0.delay))
            }
        )
        proxySelections["Balanced"] = ProxySelectionState(
            selectedMember: "Hong Kong 01",
            members: nodes.map(\.name)
        )
        proxyLatencies["Balanced"] = latencies
        proxyLatencies["Auto"] = latencies
        proxyLatencies["Streaming"] = latencies
    }
}
#else
extension TunnelManager {
    static let largeReviewProfileYAML = ""
    static let showcaseReviewProfileYAML = ""
    func installShowcaseReviewSelections() {}
    func installReviewFailover() {}
}
#endif

/// Runs blocking `/usr/sbin/networksetup` mutations on an ordered background
/// queue off `@MainActor`, coalescing stale queued applies while preserving
/// exact FIFO guarantees for terminal/uninstall restores.
final class SystemProxyWorkCoordinator: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.aetherroute.desktop.system-proxy",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var latestSequence: UInt64 = 0
    private var activeOperations = 0

    var hasPendingOperations: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeOperations > 0
    }

    func enqueueApply(
        settings: LocalProxySettings,
        configurator: SystemProxyConfigurator,
        completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        let sequence = registerOperation()
        queue.async { [self] in
            defer { self.finishOperation() }
            if self.isSuperseded(sequence) {
                completion(nil)
                return
            }
            do {
                try configurator.apply(settings: settings)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func enqueueRestore(
        configurator: SystemProxyConfigurator,
        completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        _ = registerOperation()
        queue.async { [self] in
            defer { self.finishOperation() }
            do {
                try configurator.restorePendingIfNeeded()
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func restoreAndWait(configurator: SystemProxyConfigurator) async -> (any Error)? {
        _ = registerOperation()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                defer { self.finishOperation() }
                do {
                    try configurator.restorePendingIfNeeded()
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error)
                }
            }
        }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    private func registerOperation() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        latestSequence &+= 1
        activeOperations += 1
        return latestSequence
    }

    private func finishOperation() {
        lock.lock()
        activeOperations = max(0, activeOperations - 1)
        lock.unlock()
    }

    private func isSuperseded(_ sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sequence != latestSequence
    }
}

/// Single-pass protobuf entry index over `GeoSite.dat` (`GeoSiteList`: repeated field 1 length-delimited `GeoSite`).
/// Stores exact wire byte ranges for each `country_code` once so DNS lookup and route simulation
/// can materialize a compact `GeoSiteList` containing only categories referenced by active rules.
struct GeoSiteEntrySliceIndex: Sendable {
    private let rawData: Data
    private let entryWireRanges: [String: Range<Int>]

    init?(data: Data) {
        let bytes = [UInt8](data)
        var offset = 0
        var ranges: [String: Range<Int>] = [:]
        ranges.reserveCapacity(512)

        func readVarint(_ index: inout Int, end: Int) -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < end && shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7f) << shift
                if (byte & 0x80) == 0 {
                    return value
                }
                shift += 7
            }
            return nil
        }

        func skipField(wireType: UInt64, _ index: inout Int, end: Int) -> Bool {
            switch wireType {
            case 0:
                return readVarint(&index, end: end) != nil
            case 1:
                guard index + 8 <= end else { return false }
                index += 8
                return true
            case 2:
                guard let len = readVarint(&index, end: end),
                      len <= UInt64(end - index) else { return false }
                index += Int(len)
                return true
            case 5:
                guard index + 4 <= end else { return false }
                index += 4
                return true
            default:
                return false
            }
        }

        while offset < bytes.count {
            let recordStart = offset
            guard let key = readVarint(&offset, end: bytes.count) else { return nil }
            let field = key >> 3
            let wireType = key & 0x07
            guard field == 1, wireType == 2 else {
                guard skipField(wireType: wireType, &offset, end: bytes.count) else { return nil }
                continue
            }
            guard let len = readVarint(&offset, end: bytes.count),
                  len <= UInt64(bytes.count - offset) else { return nil }
            let entryStart = offset
            let entryEnd = offset + Int(len)
            offset = entryEnd

            var inner = entryStart
            var code: String?
            while inner < entryEnd {
                guard let innerKey = readVarint(&inner, end: entryEnd) else { break }
                let innerField = innerKey >> 3
                let innerWire = innerKey & 0x07
                if innerField == 1, innerWire == 2 {
                    guard let codeLen = readVarint(&inner, end: entryEnd),
                          codeLen <= UInt64(entryEnd - inner) else { break }
                    let slice = bytes[inner ..< (inner + Int(codeLen))]
                    code = String(bytes: slice, encoding: .utf8)?.lowercased()
                    break
                } else {
                    guard skipField(wireType: innerWire, &inner, end: entryEnd) else { break }
                }
            }
            if let code, !code.isEmpty, ranges[code] == nil {
                ranges[code] = recordStart ..< entryEnd
            }
        }
        guard !ranges.isEmpty else { return nil }
        self.rawData = data
        self.entryWireRanges = ranges
    }

    func slice(forRules rules: [RuleConfigurationSummary]) -> Data? {
        var neededCodes: [String] = []
        var seen = Set<String>()
        for rule in rules {
            if rule.kind.caseInsensitiveCompare("GEOSITE") == .orderedSame,
               let criteria = rule.criteria {
                let code = GeoSiteCategoryIndex.categoryCode(of: criteria)
                if !code.isEmpty, seen.insert(code).inserted {
                    neededCodes.append(code)
                }
            } else if let criteria = rule.criteria,
                      criteria.range(of: "GEOSITE,", options: .caseInsensitive) != nil {
                return rawData
            }
        }
        guard !neededCodes.isEmpty else { return nil }
        var totalBytes = 0
        for code in neededCodes {
            if let range = entryWireRanges[code] {
                totalBytes += range.count
            }
        }
        guard totalBytes > 0 else { return Data() }
        var output = Data()
        output.reserveCapacity(totalBytes)
        for code in neededCodes {
            if let range = entryWireRanges[code] {
                output.append(rawData.subdata(in: range))
            }
        }
        return output
    }
}
