import AetherRouteKit
import Foundation
import Network
import NetworkExtension
import OSLog

extension TunnelManager {
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

    /// The primary retry follows the same offline-first path as Connect.
    /// Explicit remote refresh and manual file import remain advanced actions.
    func prepareRequiredRoutingResources() async {
        guard ensurePrivacyConsent(), canModifyProfiles,
              !isUpdatingRoutingResources, !isUIReviewMode,
              let rawYAML = activeProfile?.yaml else { return }
        let profileYAML = DomesticRoutingOptimizer.optimizedProfile(for: rawYAML)
        isUpdatingRoutingResources = true
        routingResourceMessage = nil
        routingResourceMessageIsError = false
        defer { isUpdatingRoutingResources = false }
        let storeFactory = routingResourceStoreFactory
        let downloadClient = routingResourceDownloadClient
        let bundleDirectory = bundledResourceDirectoryURL
        do {
            try await Task.detached(priority: .userInitiated) {
                let store = try storeFactory()
                try BundledRoutingResources(directoryURL: bundleDirectory)
                    .installMissingResources(for: profileYAML, in: store)
                try await downloadClient.ensureRequiredResources(for: profileYAML, in: store)
            }.value
            routingResourceMessage = AppLocalization.string("Routing rules are ready.")
        } catch {
            routingResourceMessage = localizedRoutingResourceOperationError(error)
            routingResourceMessageIsError = true
        }
        refreshRoutingResourceStatuses()
    }

    static let automaticRoutingResourceUpdatePreferenceKey =
        "AetherRoute.AutomaticRoutingResourceUpdate"
    /// How often a running connection looks for due resources. Each look is
    /// local unless a resource reached `RoutingResourceRefreshPolicy.checkInterval`.
    static let routingResourceScheduleInterval: TimeInterval = 6 * 60 * 60
    static let routingResourceScheduleJitter: TimeInterval = 15 * 60

    func setAutomaticRoutingResourceUpdateEnabled(_ enabled: Bool) {
        isAutomaticRoutingResourceUpdateEnabled = enabled
        userDefaults.set(enabled, forKey: Self.automaticRoutingResourceUpdatePreferenceKey)
        if enabled {
            automaticResourceRefreshFailures = 0
            nextAutomaticResourceRefreshAttempt = nil
            refreshDueRoutingResourcesInBackground()
        } else {
            routingResourceRefreshTask?.cancel()
        }
    }

    /// Manual checks also work while connected: the running tunnel keeps the
    /// copy it started with, and new data applies on the next connection.
    var canDownloadRoutingResources: Bool {
        guard hasAcceptedPrivacyDisclosure, !isUpdatingRoutingResources,
              !isRefreshingRoutingResources else { return false }
        return canModifyProfiles || (isConnected && !isTransitioning)
    }

    /// Runs on every connected report: starts the periodic schedule once and
    /// checks right away. Downloads go through the working tunnel.
    func refreshOlderRoutingResourcesAfterConnection() {
        startRoutingResourceRefreshSchedule()
        refreshDueRoutingResourcesInBackground()
    }

    private func startRoutingResourceRefreshSchedule() {
        guard routingResourceRefreshSchedule == nil, !isUIReviewMode else { return }
        routingResourceRefreshSchedule = Task { [weak self] in
            while !Task.isCancelled {
                // Jitter keeps Macs that connected together from all asking
                // the upstream at the same minute.
                let delay = Self.routingResourceScheduleInterval
                    + .random(in: 0...Self.routingResourceScheduleJitter)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.refreshDueRoutingResourcesInBackground()
            }
        }
    }

    /// Checks resources that reached the weekly interval. An unchanged
    /// upstream checksum only records the check; a changed one downloads and
    /// verifies the new database. Failures back off and never touch the
    /// connection or the verified data already installed.
    func refreshDueRoutingResourcesInBackground(now: Date = .now) {
        guard isAutomaticRoutingResourceUpdateEnabled, !isUIReviewMode,
              hasAcceptedPrivacyDisclosure, isConnected,
              routingResourceRefreshTask == nil,
              !isRefreshingRoutingResources, !isUpdatingRoutingResources,
              nextAutomaticResourceRefreshAttempt.map({ now >= $0 }) ?? true,
              let rawYAML = activeProfile?.yaml else { return }
        // Connected reports arrive often; the cached statuses avoid hashing
        // both databases again when nothing can be due yet.
        let mayBeDue = requiredRoutingResources.contains { kind in
            switch routingResourceStatuses[kind] {
            case nil: true
            case let .ready(record)?, let .stale(record)?:
                RoutingResourceRefreshPolicy.isDue(record, now: now)
            case .missing?, .invalid?: false
            }
        }
        guard mayBeDue else { return }
        let profileYAML = DomesticRoutingOptimizer.optimizedProfile(for: rawYAML)
        let storeFactory = routingResourceStoreFactory
        let downloadClient = routingResourceDownloadClient
        routingResourceRefreshTask = Task { [weak self] in
            let result: (checked: Bool, failure: Error?)
            do {
                result = try await Task.detached(priority: .utility) {
                    let store = try storeFactory()
                    let required = ProfileConfigurationInspector.inspect(yaml: profileYAML)
                        .requiredRoutingResources
                    var checked = false
                    var failure: Error?
                    for kind in RoutingResourceKind.allCases where required.contains(kind) {
                        let record: RoutingResourceRecord
                        switch store.status(for: kind) {
                        case let .ready(current), let .stale(current): record = current
                        case .missing, .invalid: continue
                        }
                        guard RoutingResourceRefreshPolicy.isDue(record, now: .now) else { continue }
                        try Task.checkCancellation()
                        do {
                            _ = try await downloadClient.refresh(
                                .maintainedDefault(for: kind), into: store, current: record
                            )
                            checked = true
                        } catch RoutingResourceError.superseded {
                            // A newer import or download won; nothing to retry.
                            checked = true
                        } catch {
                            if error is CancellationError { throw error }
                            failure = failure ?? error
                        }
                    }
                    return (checked, failure)
                }.value
            } catch {
                result = (false, nil)
            }
            guard let self else { return }
            routingResourceRefreshTask = nil
            if let failure = result.failure {
                automaticResourceRefreshFailures += 1
                let delay = RoutingResourceRefreshPolicy.retryDelay(
                    afterConsecutiveFailures: automaticResourceRefreshFailures
                )
                nextAutomaticResourceRefreshAttempt = Date.now.addingTimeInterval(delay)
                Self.runtimeLogger.info(
                    "stage=routingResourceRefresh deferred failures=\(self.automaticResourceRefreshFailures, privacy: .public) retryAfter=\(Int(delay), privacy: .public) error=\(String(describing: type(of: failure)), privacy: .public)"
                )
            } else if result.checked {
                automaticResourceRefreshFailures = 0
                nextAutomaticResourceRefreshAttempt = nil
                Self.runtimeLogger.info("stage=routingResourceRefresh checked")
            }
            if result.checked || result.failure != nil {
                refreshRoutingResourceStatuses()
            }
        }
    }

    func downloadRequiredRoutingResources() async {
        guard ensurePrivacyConsent(), canDownloadRoutingResources else { return }
        guard !isUIReviewMode else {
            routingResourceMessage = AppLocalization.string(
                "Routing resources are not written by the unsigned UI preview."
            )
            routingResourceMessageIsError = true
            return
        }
        let required = requiredRoutingResources
        guard !required.isEmpty else { return }

        // Connected: download beside the running tunnel without holding back
        // its controls. Disconnected: keep Connect waiting for the result.
        let appliesOnNextConnection = isEnabled
        if appliesOnNextConnection {
            isRefreshingRoutingResources = true
        } else {
            isUpdatingRoutingResources = true
        }
        routingResourceMessage = AppLocalization.string(
            "Downloading and verifying routing resources…"
        )
        routingResourceMessageIsError = false
        defer {
            if appliesOnNextConnection {
                isRefreshingRoutingResources = false
            } else {
                isUpdatingRoutingResources = false
            }
        }
        // Let a background check finish rather than racing its commit.
        await routingResourceRefreshTask?.value

        let storeFactory = routingResourceStoreFactory
        let downloadClient = routingResourceDownloadClient
        do {
            let outcomes = try await Task.detached(priority: .userInitiated) {
                let store = try storeFactory()
                var outcomes = [RoutingResourceRefreshOutcome]()
                for kind in required {
                    let current: RoutingResourceRecord? = switch store.status(for: kind) {
                    case let .ready(record), let .stale(record): record
                    case .missing, .invalid: nil
                    }
                    try Task.checkCancellation()
                    outcomes.append(try await downloadClient.refresh(
                        .maintainedDefault(for: kind), into: store, current: current
                    ))
                }
                return outcomes
            }.value
            automaticResourceRefreshFailures = 0
            nextAutomaticResourceRefreshAttempt = nil
            let anyUpdated = outcomes.contains {
                if case .updated = $0 { true } else { false }
            }
            routingResourceMessage = AppLocalization.string(
                !anyUpdated
                    ? "Routing resources are already up to date."
                    : appliesOnNextConnection
                        ? "Routing resources were downloaded and verified. They apply on the next connection."
                        : "Routing resources were downloaded and verified."
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

    func localizedRoutingResourceOperationError(
        _ error: Error
    ) -> String {
        localizedConnectionError(error).localizedDescription
    }

}
