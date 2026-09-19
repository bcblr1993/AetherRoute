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

    func refreshOlderRoutingResourcesAfterConnection() {
        guard !isUIReviewMode, hasAcceptedPrivacyDisclosure,
              routingResourceRefreshTask == nil,
              lastAutomaticResourceRefreshAttempt.map({ Date.now.timeIntervalSince($0) >= 86_400 }) ?? true,
              let rawYAML = activeProfile?.yaml else { return }
        let profileYAML = DomesticRoutingOptimizer.optimizedProfile(for: rawYAML)
        lastAutomaticResourceRefreshAttempt = .now
        let storeFactory = routingResourceStoreFactory
        let downloadClient = routingResourceDownloadClient
        routingResourceRefreshTask = Task { [weak self] in
            defer { self?.routingResourceRefreshTask = nil }
            do {
                try await Task.detached(priority: .utility) {
                    let store = try storeFactory()
                    let required = ProfileConfigurationInspector.inspect(yaml: profileYAML)
                        .requiredRoutingResources
                    for kind in required {
                        guard case let .stale(record) = store.status(for: kind),
                              record.origin != .userProvided else { continue }
                        try Task.checkCancellation()
                        try await downloadClient.downloadAndInstall(
                            .maintainedDefault(for: kind), into: store,
                            replacing: record
                        )
                    }
                }.value
                self?.refreshRoutingResourceStatuses()
            } catch {
                // An update failure never tears down a working connection or
                // removes the checksum-verified offline baseline.
                Self.runtimeLogger.info("stage=routingResourceRefresh deferred")
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

    func localizedRoutingResourceOperationError(
        _ error: Error
    ) -> String {
        localizedConnectionError(error).localizedDescription
    }

}
