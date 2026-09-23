import AetherRouteKit
import Foundation
import Network
import NetworkExtension
import OSLog

extension TunnelManager {
    func importProfile(from url: URL) {
        guard ensurePrivacyConsent() else {
            profileMessage = PrivacyConsentError.required.localizedDescription
            return
        }
        guard canImportOrAddProfile else {
            profileMessage = AppLocalization.string(
                "Wait for current profile operations to finish before importing."
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
                let shouldActivate = !isEnabled || activeProfileID == nil
                let catalog = try await ProfileFileImporter.importProfile(
                    from: url,
                    into: store,
                    makeActive: shouldActivate
                )
                await applyProductionProfileCatalog(catalog)
                diagnosticEvents.record(.profileImported)
                profileMessage = shouldActivate
                    ? AppLocalization.string("Profile imported and activated.")
                    : AppLocalization.string("Profile imported into library.")
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
        guard ensurePrivacyConsent(), canImportOrAddProfile else {
            profileMessage = AppLocalization.string(
                "Wait for current profile operations to finish before adding node."
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
            let shouldActivate = !isEnabled || activeProfileID == nil
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
                        activeProfileID: shouldActivate ? managed.id : activeProfileID,
                        profiles: profiles + [managed]
                    )
                )
            } else {
                try await performProductionProfileCatalogOperation {
                    try ProfileCatalogStore.applicationGroup().addNative(
                        nodes: [node],
                        suggestedName: profileName,
                        makeActive: shouldActivate
                    )
                }
            }
            diagnosticEvents.record(.profileImported)
            profileMessage = shouldActivate
                ? AppLocalization.string("Manual node created and activated.")
                : AppLocalization.string("Manual node created in library.")
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
        guard ensurePrivacyConsent(), canModifyProfile(id: id) else {
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
        guard ensurePrivacyConsent(), !isTransferringProfiles, !profiles.isEmpty else {
            profileMessage = AppLocalization.string(
                "No profiles available to export."
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
        if url.isFileURL {
            importProfile(from: url)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        let host = (url.host ?? "").lowercased()

        if scheme == "aetherroute" {
            switch host {
            case "connect":
                Task {
                    if !hasAcceptedPrivacyDisclosure {
                        await acceptPrivacyDisclosure()
                    }
                    await setEnabled(true)
                }
                return
            case "disconnect":
                Task {
                    await setEnabled(false)
                }
                return
            case "toggle":
                Task {
                    if !hasAcceptedPrivacyDisclosure {
                        await acceptPrivacyDisclosure()
                    }
                    await setEnabled(!isEnabled)
                }
                return
            case "check-updates":
                SparkleUpdaterController.shared.checkForUpdates()
                return
            case "navigate":
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let sectionItem = components.queryItems?.first(where: { $0.name.lowercased() == "section" }),
                   let section = sectionItem.value?.lowercased() {
                    NotificationCenter.default.post(
                        name: .aetherRouteNavigateToSection,
                        object: section
                    )
                }
                return
            case "mode":
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let modeItem = components.queryItems?.first(where: { $0.name.lowercased() == "mode" })?.value?.lowercased() {
                    let targetMode: RoutingMode? = switch modeItem {
                    case "rule": .rule
                    case "global": .global
                    case "direct": .direct
                    default: nil
                    }
                    if let targetMode {
                        Task { await setRoutingMode(targetMode) }
                    }
                }
                return
            case "profile":
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    if let idString = components.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value,
                       let id = UUID(uuidString: idString) {
                        Self.runtimeLogger.info("stage=handleExternalURL targetID=\(id)")
                        Task { await activateProfile(id: id) }
                    } else if let name = components.queryItems?.first(where: { $0.name.lowercased() == "name" })?.value {
                        let availableNames = profiles.map { "\($0.profile.name)[\($0.id)]" }.joined(separator: ", ")
                        Self.runtimeLogger.info("stage=handleExternalURL targetName=\(name, privacy: .public) activeID=\(String(describing: self.activeProfileID)) profiles=[\(availableNames, privacy: .public)]")
                        if let target = profiles.first(where: { $0.profile.name == name }) {
                            Task { await activateProfile(id: target.id) }
                        } else {
                            Self.runtimeLogger.error("stage=handleExternalURL targetName=\(name, privacy: .public) notFound")
                        }
                    }
                }
                return
            default:
                break
            }
        }

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
        if !hasAcceptedPrivacyDisclosure {
            await acceptPrivacyDisclosure()
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
        guard ensurePrivacyConsent(), canImportOrAddProfile else {
            profileMessage = AppLocalization.string(
                "Wait for current profile operations to finish before adding subscription."
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

            let shouldActivate = !isEnabled || activeProfileID == nil
            switch try await subscriptionClient.fetch(subscription) {
            case let .updated(data, metadata, report):
                let suggestedName = subscriptionDisplayName(for: url)
#if AETHERROUTE_DEVELOPMENT_PREVIEW
                if isUIReviewMode {
                    try installPreviewSubscriptionProfile(
                        data: data,
                        suggestedName: suggestedName,
                        subscription: metadata,
                        makeActive: shouldActivate
                    )
                } else {
                    try await performProductionProfileCatalogOperation {
                        try ProfileCatalogStore.applicationGroup().addValidated(
                            data: data,
                            suggestedName: suggestedName,
                            subscription: metadata,
                            makeActive: shouldActivate
                        )
                    }
                }
#else
                try await performProductionProfileCatalogOperation {
                    try ProfileCatalogStore.applicationGroup().addValidated(
                        data: data,
                        suggestedName: suggestedName,
                        subscription: metadata,
                        makeActive: shouldActivate
                    )
                }
#endif
                let baseMsg: String.LocalizationValue = shouldActivate
                    ? "Subscription downloaded and activated."
                    : "Subscription downloaded into library."
                let partialMsg: String.LocalizationValue = shouldActivate
                    ? "Subscription downloaded and activated. %lld usable nodes imported; %lld invalid nodes skipped."
                    : "Subscription downloaded into library. %lld usable nodes imported; %lld invalid nodes skipped."
                profileMessage = subscriptionSuccessMessage(
                    base: baseMsg,
                    partial: partialMsg,
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
    func installPreviewSubscriptionProfile(
        data: Data,
        suggestedName: String,
        subscription: ProfileSubscription,
        makeActive: Bool = true
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
        let shouldActivate = makeActive || profiles.isEmpty
        installReviewProfileCatalog(
            ProfileCatalog(
                activeProfileID: shouldActivate ? managed.id : activeProfileID,
                profiles: profiles + [managed]
            )
        )
    }
#endif

    func refreshSubscription() async {
        await refreshSubscription(isAutomatic: false)
    }

    func activateProfile(id: UUID) async {
        Self.runtimeLogger.info("stage=activateProfile requested id=\(id.uuidString, privacy: .public) activeProfileID=\(String(describing: self.activeProfileID), privacy: .public) canActivate=\(self.canActivateProfile)")
        guard id != activeProfileID else {
            Self.runtimeLogger.info("stage=activateProfile alreadyActive id=\(id.uuidString, privacy: .public)")
            return
        }
        guard canActivateProfile else {
            Self.runtimeLogger.error("stage=activateProfile blocked by canActivateProfile")
            profileMessage = AppLocalization.string(
                "Wait for the current network operation to finish before changing profiles."
            )
            profileMessageIsError = true
            return
        }
        let previousProfileID = activeProfileID
        let shouldReconnect = isEnabled || managerConnectionIsActive
        isUpdatingProfiles = true
        defer { isUpdatingProfiles = false }

        if !isUIReviewMode, state == .connected {
            do {
                profileMessage = AppLocalization.string("Switching profile…")
                profileMessageIsError = false
                try await applyProfileActivation(id: id)
                let currentRoutingMode = sessionRoutingMode ?? routingMode
                let reloadPayloadData = try await prepareReloadProfilePayload(
                    requestedMode: currentRoutingMode
                )
                let client = makeProxySelectionProviderClient()
                Self.runtimeLogger.info("stage=activateProfile sending live reload payload bytes=\(reloadPayloadData.count)")
                try await client.reloadActiveProfile(payload: reloadPayloadData)
                Self.runtimeLogger.info("stage=activateProfile live reload succeeded")
                clearProxySelectionRuntimeState()
                let readinessGroups = activeProfileSummary.map {
                    ProxyConnectionReadinessPolicy.groupsToVerify(summary: $0)
                } ?? []
                if let connectionID = providerConnectionID, !readinessGroups.isEmpty {
                    startConnectionReadinessCheck(
                        groups: readinessGroups,
                        connectionID: connectionID
                    )
                }
                profileMessage = AppLocalization.string(
                    "Profile switched without manual disconnection."
                )
                profileMessageIsError = false
                return
            } catch {
                Self.runtimeLogger.error(
                    "stage=activateProfile liveReloadFailed error=\(String(reflecting: error), privacy: .public), falling back to reconnect"
                )
            }
        }

        do {
            if shouldReconnect {
                profileMessage = AppLocalization.string("Switching profile…")
                profileMessageIsError = false
                await setEnabled(false)
                guard await waitForProviderToBecomeInactive() else {
                    throw LocalizedConnectionError(
                        message: AppLocalization.string(
                            "The current connection did not stop in time."
                        )
                    )
                }
            }

            try await applyProfileActivation(id: id)
            guard shouldReconnect else {
                profileMessage = AppLocalization.string("Profile activated.")
                profileMessageIsError = false
                return
            }

            await setEnabled(true)
            guard await waitForConnectionToSettle() else {
                throw LocalizedConnectionError(
                    message: AppLocalization.string(
                        "The selected profile could not establish a working connection."
                    )
                )
            }
            profileMessage = AppLocalization.string(
                "Profile switched without manual disconnection."
            )
            profileMessageIsError = false
        } catch {
            if shouldReconnect, let previousProfileID {
                if managerConnectionIsActive {
                    if state == .connected || state == .connecting || state == .recovering {
                        await setEnabled(false)
                    } else {
                        manager?.connection.stopVPNTunnel()
                    }
                    _ = await waitForProviderToBecomeInactive()
                }
                do {
                    if previousProfileID != activeProfileID {
                        try await applyProfileActivation(id: previousProfileID)
                    }
                    await setEnabled(true)
                    let restored = await waitForConnectionToSettle()
                    profileMessage = restored
                        ? AppLocalization.string(
                            "The selected profile failed. The previous profile was restored."
                        )
                        : AppLocalization.string(
                            "The selected profile and automatic rollback both failed."
                        )
                } catch {
                    profileMessage = AppLocalization.string(
                        "The selected profile and automatic rollback both failed."
                    )
                }
            } else {
                profileMessage = error.localizedDescription
            }
            profileMessageIsError = true
        }
    }

    func applyProfileActivation(id: UUID) async throws {
        if isUIReviewMode {
            guard profiles.contains(where: { $0.id == id }) else {
                throw ProfileCatalogStoreError.activeProfileNotFound
            }
            installReviewProfileCatalog(
                ProfileCatalog(activeProfileID: id, profiles: profiles)
            )
            return
        }
        try await performProductionProfileCatalogOperation {
            try ProfileCatalogStore.applicationGroup().activate(id: id)
        }
    }

    func prepareReloadProfilePayload(
        requestedMode: RoutingMode
    ) async throws -> Data {
        guard let activeProfile else {
            throw ActiveProfileStoreError.noActiveProfile
        }
        let rawProfileYAML = activeProfile.yaml
        let profileYAML = isDomesticOptimizationEnabled
            ? DomesticRoutingOptimizer.optimizedProfile(for: rawProfileYAML, customRules: customRules)
            : (customRules.isEmpty ? rawProfileYAML : DomesticRoutingOptimizer.optimizedProfile(for: rawProfileYAML, customRules: customRules))
#if AETHERROUTE_QA_AUTOMATION
        if let appGroupDir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroup)?
            .appendingPathComponent("Library/Application Support/AetherRoute", isDirectory: true) {
            try? FileManager.default.createDirectory(at: appGroupDir, withIntermediateDirectories: true)
            try? rawProfileYAML.write(to: appGroupDir.appendingPathComponent("debug_profile_raw.yaml"), atomically: true, encoding: .utf8)
            try? profileYAML.write(to: appGroupDir.appendingPathComponent("debug_profile_optimized.yaml"), atomically: true, encoding: .utf8)
        }
#endif
        let persistedSelections = (try? ProxySelectionStore
            .applicationGroup()
            .selections(forProfileYAML: rawProfileYAML)) ?? [:]
        let profileSummary = ProfileConfigurationInspector.inspect(
            yaml: profileYAML,
            customRules: customRules
        )
        let initialSelections = InitialProxySelectionPolicy
            .selections(
                persisted: persistedSelections,
                summary: profileSummary
            )
        let payload = ReloadProfilePayload(
            profileYAML: profileYAML,
            routingMode: requestedMode,
            bypassPolicy: bypassPolicy,
            dnsPolicy: dnsRuntimePolicy,
            proxySelections: initialSelections
        )
        return try ReloadProfilePayloadCodec.encode(payload)
    }

    @discardableResult
    func renameProfile(id: UUID, name: String) async -> Bool {
        guard canModifyProfile(id: id) else { return false }
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

    func updateSubscriptionInterval(id: UUID, interval: TimeInterval?) async {
        guard canModifyProfile(id: id),
              let index = profiles.firstIndex(where: { $0.id == id }),
              let sub = profiles[index].profile.subscription else { return }
        isUpdatingProfiles = true
        defer { isUpdatingProfiles = false }
        do {
            let updatedSub = try ProfileSubscription(
                url: sub.url,
                etag: sub.etag,
                lastModified: sub.lastModified,
                lastCheckedAt: sub.lastCheckedAt,
                lastUpdatedAt: sub.lastUpdatedAt,
                autoUpdateInterval: interval
            )
            let existing = profiles[index].profile
            let updatedProfile = ActiveProfile(
                name: existing.name,
                yaml: existing.yaml,
                importedAt: existing.importedAt,
                subscription: updatedSub,
                nativeNodes: existing.nativeNodes
            )
            if isUIReviewMode {
                var updatedProfiles = profiles
                updatedProfiles[index] = ManagedProfile(id: id, profile: updatedProfile)
                installReviewProfileCatalog(
                    ProfileCatalog(
                        activeProfileID: activeProfileID,
                        profiles: updatedProfiles
                    )
                )
            } else {
                try await performProductionProfileCatalogOperation {
                    try ProfileCatalogStore.applicationGroup().replace(
                        id: id,
                        with: updatedProfile
                    )
                }
            }
            profileMessage = AppLocalization.string("Auto-update interval updated.")
            profileMessageIsError = false
        } catch {
            profileMessage = error.localizedDescription
            profileMessageIsError = true
        }
    }

    func removeProfile(id: UUID) async {
        guard canModifyProfile(id: id) else { return }
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

    func mergeReviewCatalog(
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

    func refreshSubscriptionIfDue() async {
        guard activeProfile?.subscription?.isDue() == true else { return }
        await refreshSubscription(isAutomatic: true)
    }

    func refreshSubscription(isAutomatic: Bool) async {
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

    func localizedProfileOperationError(_ error: Error) -> String {
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

    func subscriptionDisplayName(for url: URL) -> String {
        let filename = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !filename.isEmpty, filename != "/" { return filename }
        return url.host ?? AppLocalization.string("Subscribed profile")
    }

    func subscriptionSuccessMessage(
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

    func installReviewProfileCatalog(_ catalog: ProfileCatalog) {
        installProfileProjection(
            ProfileCatalogProjectionBuilder.review(catalog)
        )
    }

    func installProfileProjection(
        _ projection: ProfileCatalogProjection
    ) {
        clearProxySelectionRuntimeState()
        profiles = projection.catalog.profiles
        activeProfileID = projection.catalog.activeProfileID
        activeProfile = projection.catalog.activeProfile?.profile
        if let active = projection.catalog.activeProfile?.profile, !customRules.isEmpty {
            let optimized = isDomesticOptimizationEnabled
                ? DomesticRoutingOptimizer.optimizedProfile(for: active.yaml, customRules: customRules)
                : DomesticRoutingOptimizer.optimizedProfile(for: active.yaml, customRules: customRules)
            activeProfileSummary = ProfileConfigurationInspector.inspect(yaml: optimized, customRules: customRules)
        } else {
            activeProfileSummary = projection.summary
        }
        automaticProxySelectionGroups = Set(
            projection.summary?.proxyGroups.filter { group in
                group.strategy.caseInsensitiveCompare("select") == .orderedSame
                    && projection.catalog.activeProfile.map { active in
                        userDefaults.bool(
                            forKey: automaticProxySelectionPreferenceKey(
                                profileYAML: active.profile.yaml,
                                group: group.name
                            )
                        )
                    } == true
            }.map(\.name) ?? []
        )
        dnsRuntimePolicy = projection.dnsPolicy
        dnsRuntimePolicyMessage = projection.dnsErrorDescription
        dnsRuntimePolicyMessageIsError =
            projection.dnsErrorDescription != nil
        refreshRoutingResourceStatuses()
    }

    func automaticProxySelectionPreferenceKey(
        profileYAML: String,
        group: String
    ) -> String {
        let digest = ProxySelectionStore.profileDigest(
            yaml: profileYAML + "\u{0}automatic-selection\u{0}" + group
        )
        return "AetherRoute.ProxySelection.Automatic.\(digest)"
    }

    func applyProductionProfileCatalog(
        _ catalog: ProfileCatalog
    ) async {
        let projection = await Task.detached(priority: .userInitiated) {
            ProfileCatalogProjectionBuilder.production(catalog)
        }.value
        installProfileProjection(projection)
    }

    func performProductionProfileCatalogOperation(
        _ operation: @escaping @Sendable () throws -> ProfileCatalog
    ) async throws {
        let projection = try await Task.detached(priority: .userInitiated) {
            ProfileCatalogProjectionBuilder.production(try operation())
        }.value
        installProfileProjection(projection)
    }

    func canModifyProfile(id: UUID) -> Bool {
        if id == activeProfileID {
            return canModifyProfiles
        } else {
            return canModifyInactiveProfiles
        }
    }

    func persistBypassPolicy(_ policy: BypassPolicy) async throws {
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
    func installReviewBypassPolicy() {
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

}
