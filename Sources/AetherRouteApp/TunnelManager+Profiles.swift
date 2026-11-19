import AetherRouteKit
import CryptoKit
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
                let outcome = try await ProfileFileImporter.importProfileWithOutcome(
                    from: url,
                    into: store,
                    makeActive: shouldActivate
                )
                await applyProductionProfileCatalog(outcome.catalog)
                diagnosticEvents.record(.profileImported)
                let unreadable = outcome.unreadableCertificateAuthorityPaths
                if unreadable.isEmpty {
                    profileMessage = shouldActivate
                        ? AppLocalization.string("Profile imported and activated.")
                        : AppLocalization.string("Profile imported into library.")
                    profileMessageIsError = false
                } else {
                    // The profile works; only nodes pinned to these CA files
                    // will refuse to connect, so say which and how to fix it.
                    profileMessage = String.localizedStringWithFormat(
                        AppLocalization.string(
                            "Profile imported, but AetherRoute could not read the CA file %@. Nodes that use it will not connect; paste the certificate into ca-str instead."
                        ),
                        unreadable.joined(separator: ", ")
                    )
                    profileMessageIsError = true
                }
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
                let previousYAML = profiles.first(where: { $0.id == id })?.profile.yaml
                // UserDefaults is documented thread-safe; it is only
                // read and written here, off the main actor.
                nonisolated(unsafe) let defaults = userDefaults
                try await performProductionProfileCatalogOperation {
                    let catalog = try ProfileCatalogStore.applicationGroup().updateNative(
                        id: id,
                        nodes: nodes
                    )
                    // Editing nodes rewrites the profile's text; keep the
                    // node choices, modes and DNS override that still apply.
                    if let previousYAML,
                       let updated = catalog.profiles.first(where: { $0.id == id }) {
                        ProfileSettingsMigration.migrateInApplicationGroup(
                            fromYAML: previousYAML,
                            toYAML: updated.profile.yaml,
                            defaults: defaults,
                            overrides: updated.profile.overrides
                        )
                    }
                    return catalog
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
            profileMessage = AppLocalization.format(
                "%lld profiles are available after secure import.",
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
                let suggestedName = metadata.providerProfileName
                    ?? subscriptionDisplayName(for: url)
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
                let partialMsg: String = shouldActivate
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
        let intentEpoch = userIntentEpoch
        isUpdatingProfiles = true
        defer { isUpdatingProfiles = false }

        // Preflight target profile existence, syntax/plugin safety, and native
        // dialer-proxy links BEFORE touching the active profile or tearing down
        // a healthy running tunnel.
        guard let candidateManaged = profiles.first(where: { $0.id == id }) else {
            profileMessage = ProfileCatalogStoreError.activeProfileNotFound.localizedDescription
            profileMessageIsError = true
            return
        }
        let candidateProfile = candidateManaged.profile
        let prebuiltReload: PreparedReloadProfile?
        do {
            if let nativeNodes = candidateProfile.nativeNodes {
                try AetherNodeProfileCompiler.validateDialerProxies(in: nativeNodes)
            }
            let compiledCandidateYAML = effectiveProfileYAML(for: candidateProfile)
            _ = try ProfileImportValidator.validate(data: Data(compiledCandidateYAML.utf8))
            if !isUIReviewMode && shouldReconnect {
                let currentRoutingMode = sessionRoutingMode ?? routingMode
                prebuiltReload = try await prepareReloadProfilePayload(
                    for: candidateProfile,
                    requestedMode: currentRoutingMode
                )
            } else {
                prebuiltReload = nil
            }
        } catch {
            profileMessage = error.localizedDescription
            profileMessageIsError = true
            return
        }

        if !isUIReviewMode, state == .connected, let preparedReload = prebuiltReload {
            do {
                profileMessage = AppLocalization.string("Switching profile…")
                profileMessageIsError = false
                let client = makeProxySelectionProviderClient()
                Self.runtimeLogger.info(
                    "stage=activateProfile sending live reload payload bytes=\(preparedReload.payloadData.count) resources=\(preparedReload.routingResources.count)"
                )
                try await reloadActiveProfileStagingResources(preparedReload, via: client)
                Self.runtimeLogger.info("stage=activateProfile live reload succeeded")
                try await applyProfileActivation(
                    id: id,
                    preserveConnectedRuntimeState: true
                )
                clearProxySelectionRuntimeState()
                cancelConnectionReadiness()
                readinessVerifiedConnectionID = nil
                await finalizeLiveProfileReload(client: client, resetReadiness: false)
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
                await setEnabled(false, isAutomaticReconnect: false, clearsUserIntent: false)
                guard await waitForProviderToBecomeInactive() else {
                    throw LocalizedConnectionError(
                        message: AppLocalization.string(
                            "The current connection did not stop in time."
                        )
                    )
                }
                guard !isApplicationTerminating, userIntentEpoch == intentEpoch else {
                    return
                }
            }

            try await applyProfileActivation(id: id)
            guard shouldReconnect else {
                profileMessage = AppLocalization.string("Profile activated.")
                profileMessageIsError = false
                return
            }

            guard !isApplicationTerminating, userIntentEpoch == intentEpoch else {
                return
            }
            await setEnabled(true)
            let settled = await waitForConnectionToSettle()
            guard !isApplicationTerminating, userIntentEpoch == intentEpoch else {
                return
            }
            guard settled else {
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
            if shouldReconnect,
               let previousProfileID,
               !isApplicationTerminating,
               !isSwitchingNetworkEngine,
               userIntentEpoch == intentEpoch,
               userIntendsToConnect {
                if managerConnectionIsActive {
                    if state == .connected || state == .connecting || state == .recovering {
                        await setEnabled(false, isAutomaticReconnect: false, clearsUserIntent: false)
                    } else {
                        manager?.connection.stopVPNTunnel()
                    }
                    _ = await waitForProviderToBecomeInactive()
                }
                guard !isApplicationTerminating, userIntentEpoch == intentEpoch, userIntendsToConnect else {
                    return
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
            } else if isApplicationTerminating || userIntentEpoch != intentEpoch {
                return
            } else {
                profileMessage = error.localizedDescription
            }
            profileMessageIsError = true
        }
    }

    func finalizeLiveProfileReload(
        client: ProxySelectionProviderClient,
        resetReadiness: Bool = true
    ) async {
        if resetReadiness {
            clearProxySelectionRuntimeState()
            cancelConnectionReadiness()
            readinessVerifiedConnectionID = nil
        }
        await syncGlobalSelector(client: client)
        proxySelectionRefreshedAt.removeAll()
        for group in activeProfileSummary?.proxyGroups ?? [] where group.strategy.caseInsensitiveCompare("select") == .orderedSame {
            if let snapshot = try? await client.snapshot(group: group.name) {
                proxySelections[group.name] = snapshot
            }
        }
        startTelemetryPollingIfNeeded()
        if resetReadiness {
            let readinessGroups = activeProfileSummary.map {
                ProxyConnectionReadinessPolicy.groupsToVerify(summary: $0)
            } ?? []
            if let connectionID = providerConnectionID, !readinessGroups.isEmpty {
                startConnectionReadinessCheck(
                    groups: readinessGroups,
                    connectionID: connectionID
                )
            }
        }
    }

    func applyProfileActivation(
        id: UUID,
        preserveConnectedRuntimeState: Bool = false
    ) async throws {
        if isUIReviewMode {
            guard profiles.contains(where: { $0.id == id }) else {
                throw ProfileCatalogStoreError.activeProfileNotFound
            }
            installReviewProfileCatalog(
                ProfileCatalog(activeProfileID: id, profiles: profiles),
                preserveConnectedRuntimeState: preserveConnectedRuntimeState
            )
            return
        }
        try await performProductionProfileCatalogOperation(
            preserveConnectedRuntimeState: preserveConnectedRuntimeState
        ) {
            try ProfileCatalogStore.applicationGroup().activate(id: id)
        }
    }

    struct PreparedReloadProfile: Sendable {
        let payloadData: Data
        let routingResources: [RoutingResourceKind: Data]
    }

    func reloadActiveProfileStagingResources(
        _ prepared: PreparedReloadProfile,
        via client: ProxySelectionProviderClient
    ) async throws {
        try await client.stageRoutingResources(prepared.routingResources)
        try await client.reloadActiveProfile(payload: prepared.payloadData)
    }

    func prepareReloadProfilePayload(
        for explicitProfile: ActiveProfile? = nil,
        requestedMode: RoutingMode
    ) async throws -> PreparedReloadProfile {
        guard let targetProfile = explicitProfile ?? activeProfile else {
            throw ActiveProfileStoreError.noActiveProfile
        }
        if let nativeNodes = targetProfile.nativeNodes {
            try AetherNodeProfileCompiler.validateDialerProxies(in: nativeNodes)
        }
        Self.runtimeLogger.info("stage=prepareReloadProfilePayload begin")
        isUpdatingRoutingResources = true
        defer { isUpdatingRoutingResources = false }
        let rawProfileYAML = targetProfile.yaml
        let baseProfileYAML = effectiveProfileYAML(for: targetProfile)
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
        let inMemoryGlobalSelection = proxySelections["GLOBAL"]?.selectedMember
        let reloadInput = try await Task.detached(
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
            let routingResources = try store.launchResourceSnapshot(for: profileYAML)
            if let geoSiteData = routingResources[.geoSite],
               let unknown = try GeoSiteCategoryIndex(data: geoSiteData)
                .unknownCategories(in: currentCustomRules).first {
                throw CustomRuleGeoSiteError.unknownCategory(unknown)
            }
            let persistedSelections = (try? ProxySelectionStore
                .applicationGroup()
                .selections(forProfileYAML: rawProfileYAML)) ?? [:]
            let profileSummary = ProfileConfigurationInspector.inspect(
                yaml: profileYAML,
                customRules: currentCustomRules,
                remoteRules: remoteRules
            )
            var initialSelections = InitialProxySelectionPolicy
                .selections(
                    persisted: persistedSelections,
                    summary: profileSummary
                )
            if initialSelections["GLOBAL"] == nil,
               let globalTarget = Self.resolvedGlobalTargetMember(
                   in: profileSummary,
                   persistedSelections: persistedSelections,
                   inMemorySelection: inMemoryGlobalSelection
               ) {
                initialSelections["GLOBAL"] = globalTarget
            }
            let payload = ReloadProfilePayload(
                profileYAML: profileYAML,
                routingMode: requestedMode,
                bypassPolicy: requestedBypassPolicy,
                dnsPolicy: requestedDNSPolicy,
                proxySelections: initialSelections,
                diagnosticLogLevel: (try? DiagnosticLogLevelStore
                    .applicationGroup())?.load() ?? .off
            )
            return (
                PreparedReloadProfile(
                    payloadData: try ReloadProfilePayloadCodec.encode(payload),
                    routingResources: routingResources
                ),
                bundled.union(downloaded)
            )
        }.value
        if !reloadInput.1.isEmpty {
            routingResourceMessage = AppLocalization.string(
                "Routing rules are ready."
            )
            routingResourceMessageIsError = false
            refreshRoutingResourceStatuses()
        }
        Self.runtimeLogger.info("stage=prepareReloadProfilePayload success")
        return reloadInput.0
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

    func updateSubscriptionInterval(
        id: UUID,
        interval: TimeInterval?,
        followProvider: Bool = false
    ) async {
        guard canModifyProfile(id: id) || canRefreshAnySubscription,
              let index = profiles.firstIndex(where: { $0.id == id }),
              let sub = profiles[index].profile.subscription else { return }
        let keepRuntime = state == .connected
        isUpdatingProfiles = true
        defer { isUpdatingProfiles = false }
        do {
            let updatedSub = try sub.withAutoUpdate(
                interval: interval,
                followProvider: followProvider
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
                    ),
                    preserveConnectedRuntimeState: keepRuntime
                )
            } else {
                try await performProductionProfileCatalogOperation(
                    preserveConnectedRuntimeState: keepRuntime
                ) {
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
        let removedProfile = profiles.first(where: { $0.id == id })?.profile
        isUpdatingProfiles = true
        defer { isUpdatingProfiles = false }
        if isUIReviewMode {
            guard id != activeProfileID else { return }
            installReviewProfileCatalog(
                ProfileCatalog(
                    activeProfileID: activeProfileID,
                    profiles: profiles.filter { $0.id != id }
                ),
                preserveConnectedRuntimeState: state == .connected
            )
            recordSubscriptionUpdateError(nil, for: id)
            profileMessage = AppLocalization.string("Profile removed.")
            profileMessageIsError = false
            return
        }
        do {
            try await performProductionProfileCatalogOperation(
                preserveConnectedRuntimeState: state == .connected
            ) {
                try ProfileCatalogStore.applicationGroup().remove(id: id)
            }
            if let removedProfile,
               !profiles.contains(where: { $0.profile.yaml == removedProfile.yaml }) {
                ProfileSettingsMigration.removeSettingsInApplicationGroup(
                    forYAML: removedProfile.yaml,
                    defaults: userDefaults,
                    overrides: removedProfile.overrides
                )
            }
            recordSubscriptionUpdateError(nil, for: id)
            profileMessage = AppLocalization.string("Profile removed.")
            profileMessageIsError = false
        } catch {
            profileMessage = error.localizedDescription
            profileMessageIsError = true
        }
    }

    var shouldRunAutomaticSubscriptionCheck: Bool {
        guard hasAcceptedPrivacyDisclosure else { return false }
        switch state {
        case .disconnected, .connected, .failed:
            return !isTransitioning && !isSwitchingNetworkEngine
        case .privacyConsentRequired, .loading, .connecting, .recovering, .disconnecting:
            return false
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
            if shouldRunAutomaticSubscriptionCheck {
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
        let dueIDs = profiles
            .filter { $0.profile.subscription?.isDue() == true }
            .map(\.id)
        for id in dueIDs {
            guard !Task.isCancelled, shouldRunAutomaticSubscriptionCheck else { break }
            await refreshSubscription(id: id, isAutomatic: true)
        }
    }

    func refreshAllSubscriptions() async {
        guard ensurePrivacyConsent(), canRefreshAnySubscription else { return }
        let subscriptionIDs = profiles
            .filter { $0.profile.subscription != nil }
            .map(\.id)
        guard !subscriptionIDs.isEmpty else { return }
        var succeededCount = 0
        var failedCount = 0
        for id in subscriptionIDs {
            guard !Task.isCancelled, canRefreshAnySubscription else { break }
            await refreshSubscription(id: id, isAutomatic: false)
            if subscriptionUpdateErrors[id] == nil {
                succeededCount += 1
            } else {
                failedCount += 1
            }
        }
        if subscriptionIDs.count > 1 {
            if failedCount == 0 {
                profileMessage = aetherBilingualText(
                    en: "Updated \(succeededCount) subscriptions.",
                    zhHans: "已更新 \(succeededCount) 个订阅。"
                )
                profileMessageIsError = false
            } else {
                profileMessage = aetherBilingualText(
                    en: "Updated \(succeededCount) subscriptions; \(failedCount) failed.",
                    zhHans: "已更新 \(succeededCount) 个订阅，\(failedCount) 个失败。"
                )
                profileMessageIsError = true
            }
        }
    }

    /// Replaces a profile's contents as a subscription update does: the
    /// overrides stay with the profile, and settings bound to the old text
    /// move to the new text before the new profile is installed and read.
    nonisolated static func replaceProfileContents(
        id: UUID,
        previous: ActiveProfile,
        with updated: ActiveProfile,
        defaults: UserDefaults
    ) throws -> ProfileCatalog {
        let catalog = try ProfileCatalogStore.applicationGroup().replace(
            id: id,
            with: updated
        )
        let shouldPrunePrevious = !catalog.profiles.contains {
            $0.profile.yaml == previous.yaml
        }
        ProfileSettingsMigration.migrateInApplicationGroup(
            fromYAML: previous.yaml,
            toYAML: updated.yaml,
            defaults: defaults,
            overrides: previous.overrides,
            pruneOldSettings: shouldPrunePrevious
        )
        return catalog
    }

    func refreshSubscription(isAutomatic: Bool) async {
        guard let activeProfileID else {
            if !isAutomatic {
                profileMessage = AppLocalization.string("The active profile is not a subscription.")
                profileMessageIsError = true
            }
            return
        }
        await refreshSubscription(id: activeProfileID, isAutomatic: isAutomatic)
    }

    func refreshSubscription(id: UUID,
                             isAutomatic: Bool = false,
                             prefetchedUpdate: ProfileSubscriptionUpdate? = nil,
                             rebuildDependents: Bool = true,
                             allowLiveReload: Bool = true) async {
        guard ensurePrivacyConsent() else { return }
        guard let managed = profiles.first(where: { $0.id == id }),
              let subscription = managed.profile.subscription else {
            if !isAutomatic {
                profileMessage = AppLocalization.string("The active profile is not a subscription.")
                profileMessageIsError = true
            }
            return
        }
        if prefetchedUpdate == nil {
            guard canRefreshSubscription(id: id) else { return }
        }
        if isUIReviewMode {
            recordSubscriptionUpdateError(nil, for: id)
            if !isAutomatic {
                profileMessage = AppLocalization.string("Subscription is already up to date.")
                profileMessageIsError = false
            }
            return
        }

        let manageRefreshTracking = prefetchedUpdate == nil
        if manageRefreshTracking {
            refreshingSubscriptionProfileIDs.insert(id)
            isRefreshingSubscription = !refreshingSubscriptionProfileIDs.isEmpty
        }
        defer {
            if manageRefreshTracking {
                refreshingSubscriptionProfileIDs.remove(id)
                isRefreshingSubscription = !refreshingSubscriptionProfileIDs.isEmpty
            }
        }

        do {
            let update: ProfileSubscriptionUpdate
            if let prefetchedUpdate {
                update = prefetchedUpdate
            } else {
                update = try await subscriptionClient.fetch(subscription)
            }
            guard !isApplicationTerminating else { return }
            guard let currentManaged = profiles.first(where: { $0.id == id }) else {
                return
            }
            let profile = currentManaged.profile
            let keepRuntime = state == .connected
            // UserDefaults is documented thread-safe; it is only read and
            // written here, off the main actor.
            nonisolated(unsafe) let defaults = userDefaults
            try await performProductionProfileCatalogOperation(
                preserveConnectedRuntimeState: keepRuntime
            ) {
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
                        importedAt: profile.importedAt,
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
                let updatedCatalog = try Self.replaceProfileContents(
                    id: id,
                    previous: profile,
                    with: updated,
                    defaults: defaults
                )
                if rebuildDependents, case .updated = update {
                    return (try? ProfileCatalogStore.applicationGroup().rebuildDependentMergedProfiles(referencing: id))
                        ?? updatedCatalog
                }
                return updatedCatalog
            }
            recordSubscriptionUpdateError(nil, for: id)

            let activeIsDependentMerge = activeProfileID.flatMap { activeID in
                profiles.first(where: { $0.id == activeID })?.mergedSpec?.sourceProfileIDs.contains(id)
            } ?? false
            let isActiveTarget = id == activeProfileID || activeIsDependentMerge
            if allowLiveReload, isActiveTarget, state == .connected, case .updated = update {
                let currentRoutingMode = sessionRoutingMode ?? routingMode
                let preparedReload = try await prepareReloadProfilePayload(
                    requestedMode: currentRoutingMode
                )
                let client = makeProxySelectionProviderClient()
                Self.runtimeLogger.info(
                    "stage=subscriptionRefresh liveReload sending payload bytes=\(preparedReload.payloadData.count) resources=\(preparedReload.routingResources.count)"
                )
                try await reloadActiveProfileStagingResources(preparedReload, via: client)
                await finalizeLiveProfileReload(client: client)
                Self.runtimeLogger.info("stage=subscriptionRefresh liveReload succeeded")
            }

            switch update {
            case let .updated(_, _, report):
                if isActiveTarget {
                    profileMessage = subscriptionSuccessMessage(
                        base: "Subscription updated and activated.",
                        partial: "Subscription updated and activated. %lld usable nodes imported; %lld invalid nodes skipped.",
                        report: report
                    )
                } else {
                    profileMessage = aetherBilingualText(
                        en: "Updated subscription “\(profile.name)”.",
                        zhHans: "已更新订阅「\(profile.name)」。"
                    )
                }
            case .notModified:
                if !isAutomatic || isActiveTarget {
                    profileMessage = AppLocalization.string(
                        "Subscription is already up to date."
                    )
                }
            }
            diagnosticEvents.record(.subscriptionRefreshed)
            profileMessageIsError = false
        } catch {
            diagnosticEvents.record(.profileOperationFailed)
            let errorText = localizedProfileOperationError(error)
            recordSubscriptionUpdateError(errorText, for: id)
            profileMessage = errorText
            profileMessageIsError = true
        }
    }

    func localizedProfileOperationError(_ error: Error) -> String {
        if let compilerError = error as? AetherNodeProfileCompilerError {
            return compilerError.localizedAppDescription
        }
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
        case let .reservedRule(kind):
            return String.localizedStringWithFormat(
                AppLocalization.string("The profile uses the rule type ‘%@’, which is reserved for AetherRoute’s application rules."),
                kind
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
        partial: String,
        report: SubscriptionPayloadReport
    ) -> String {
        guard report.skippedNodeCount > 0,
              let usableNodeCount = report.usableNodeCount else {
            return AppLocalization.string(base)
        }
        return AppLocalization.format(
            partial,
            Int64(usableNodeCount),
            Int64(report.skippedNodeCount)
        )
    }

    func installReviewProfileCatalog(
        _ catalog: ProfileCatalog,
        preserveConnectedRuntimeState: Bool = false
    ) {
        let currentGlobalOverride = loadGlobalProfileOverride()
        var projection = ProfileCatalogProjectionBuilder.review(
            catalog,
            globalOverride: currentGlobalOverride,
            bypassPolicy: bypassPolicy
        )
        let effectiveRules = effectiveRuntimeCustomRules
        if let active = catalog.activeProfile?.profile,
           !effectiveRules.isEmpty || !compiledRemoteRulesCache.isEmpty {
            let optimized = DomesticRoutingOptimizer.optimizedProfile(
                for: effectiveProfileYAML(for: active),
                customRules: effectiveRules,
                remoteRules: compiledRemoteRulesCache,
                enableDomesticDirect: isDomesticOptimizationEnabled
            )
            let summary = ProfileConfigurationInspector.inspect(
                yaml: optimized,
                customRules: effectiveRules,
                remoteRules: compiledRemoteRulesCache
            )
            projection = ProfileCatalogProjection(
                catalog: projection.catalog,
                summary: summary,
                dnsPolicy: projection.dnsPolicy,
                dnsErrorDescription: projection.dnsErrorDescription
            )
        }
        installProfileProjection(
            projection,
            preserveConnectedRuntimeState: preserveConnectedRuntimeState
        )
    }

    func installProfileProjection(
        _ projection: ProfileCatalogProjection,
        preserveConnectedRuntimeState: Bool = false
    ) {
        if !(preserveConnectedRuntimeState && state == .connected) {
            clearProxySelectionRuntimeState()
        }
        profiles = projection.catalog.profiles
        activeProfileID = projection.catalog.activeProfileID
        activeProfile = projection.catalog.activeProfile?.profile
        activeProfileSummary = projection.summary
        loadProxySelectionModes(
            groups: activeProfileSummary?.proxyGroups ?? [],
            profileYAML: projection.catalog.activeProfile?.profile.yaml
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
        ProxySelectionPreferenceKeys.legacyAutomatic(profileYAML: profileYAML, group: group)
    }

    func applyProductionProfileCatalog(
        _ catalog: ProfileCatalog,
        preserveConnectedRuntimeState: Bool = false
    ) async {
        cachedGlobalProfileOverride = nil
        await reloadCustomRuleProvidersFromEngine(
            additionalProfileYAMLs: catalog.profiles.map(\.profile.yaml)
        )
        let currentCustomRules = customRules
        let currentRemoteRules = compiledRemoteRulesCache
        let currentGlobalOverride = loadGlobalProfileOverride()
        let activeRuleProviders = customRuleProviders.filter(\.isEnabled)
        let currentBypassPolicy = bypassPolicy
        let currentDomesticEnabled = isDomesticOptimizationEnabled
        let projection = await Task.detached(priority: .userInitiated) {
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
        installProfileProjection(
            projection,
            preserveConnectedRuntimeState: preserveConnectedRuntimeState
        )
    }

    func performProductionProfileCatalogOperation(
        preserveConnectedRuntimeState: Bool = false,
        _ operation: @escaping @Sendable () throws -> ProfileCatalog
    ) async throws {
        let catalog = try await Task.detached(priority: .userInitiated) {
            try operation()
        }.value
        await reloadCustomRuleProvidersFromEngine(
            additionalProfileYAMLs: catalog.profiles.map(\.profile.yaml)
        )
        let currentCustomRules = customRules
        let currentRemoteRules = compiledRemoteRulesCache
        let currentGlobalOverride = loadGlobalProfileOverride()
        let activeRuleProviders = customRuleProviders.filter(\.isEnabled)
        let currentBypassPolicy = bypassPolicy
        let currentDomesticEnabled = isDomesticOptimizationEnabled
        let projection = await Task.detached(priority: .userInitiated) {
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
        installProfileProjection(
            projection,
            preserveConnectedRuntimeState: preserveConnectedRuntimeState
        )
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
        refreshActiveProfileSummary()
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

    // MARK: - Providers, Global Override & Merged Profiles (V3)

    func effectiveOverrideResult(
        for profile: ActiveProfile,
        overrides overrideCandidate: ProfileOverride? = nil
    ) -> ProfileOverrideResult {
        let globalOverride = loadGlobalProfileOverride()
        let activeRuleProviders = isUIReviewMode ? [] : customRuleProviders.filter(\.isEnabled)
        let effectivePerProfile = overrideCandidate ?? profile.overrides
        let digest = SHA256.hash(data: Data(profile.yaml.utf8))
        let cacheKey = EffectiveProfileCompilationKey(
            yamlDigest: digest,
            profileOverrides: effectivePerProfile,
            globalOverride: globalOverride,
            enabledProviders: activeRuleProviders
        )
        if let cached = cachedEffectiveProfileCompilation, cached.key == cacheKey {
            return cached.result
        }
        let canonicalYAML = ProfileRuntimeYAML.canonicalize(profile.yaml)
        let compiled = ProfileOverrideCompiler.apply(
            effectivePerProfile,
            globalOverride: globalOverride,
            externalRuleProviders: activeRuleProviders,
            to: canonicalYAML
        )
        cachedEffectiveProfileCompilation = (cacheKey, compiled)
        return compiled
    }

    func effectiveProfileYAML(for profile: ActiveProfile) -> String {
        effectiveOverrideResult(for: profile).yaml
    }

    func loadGlobalProfileOverride() -> ProfileOverride {
        if let cachedGlobalProfileOverride {
            return cachedGlobalProfileOverride
        }
        guard !isUIReviewMode else { return ProfileOverride() }
        let loaded = ProfileOverrideStore.applicationGroup().loadGlobalOverride()
        cachedGlobalProfileOverride = loaded
        return loaded
    }

    #if DEBUG
    func setGlobalProfileOverrideForTesting(_ override: ProfileOverride?) {
        cachedGlobalProfileOverride = override
        cachedEffectiveProfileCompilation = nil
    }
    #endif

    @discardableResult
    func saveGlobalProfileOverride(_ override: ProfileOverride) async -> Bool {
        guard ensurePrivacyConsent() else { return false }
        do {
            let validated = try override.validated()
            if !isUIReviewMode {
                try await Task.detached(priority: .userInitiated) {
                    try ProfileOverrideStore.applicationGroup().saveGlobalOverride(validated)
                }.value
            }
            cachedGlobalProfileOverride = validated
            cachedEffectiveProfileCompilation = nil
            refreshActiveProfileSummary()
            if state == .connected {
                await reloadCustomRulesLive()
            }
            profileMessage = AppLocalization.inline(
                "Global override template saved.",
                chinese: "已保存全局覆写模板。"
            )
            profileMessageIsError = false
            return true
        } catch {
            profileMessage = error.overrideMessage
            profileMessageIsError = true
            return false
        }
    }

    @discardableResult
    func createMergedProfile(
        name: String,
        spec: MergedProfileSpec
    ) async -> Bool {
        guard ensurePrivacyConsent(), !isUpdatingProfiles, canActivateProfile else {
            return false
        }
        isUpdatingProfiles = true
        defer { isUpdatingProfiles = false }

        let previousActiveProfileID = activeProfileID
        let keepRuntime = state == .connected
        var catalogUpdated = false
        do {
            if isUIReviewMode {
                profileMessage = AppLocalization.inline(
                    "Merged profile preview is unavailable in review mode.",
                    chinese: "预览模式下不支持创建组合订阅。"
                )
                profileMessageIsError = true
                return false
            } else {
                try await performProductionProfileCatalogOperation(
                    preserveConnectedRuntimeState: keepRuntime
                ) {
                    try ProfileCatalogStore.applicationGroup().createMergedProfile(
                        name: name,
                        spec: spec,
                        makeActive: true
                    )
                }
                catalogUpdated = true
            }
            if state == .connected, !isUIReviewMode {
                let currentRoutingMode = sessionRoutingMode ?? routingMode
                let preparedReload = try await prepareReloadProfilePayload(
                    requestedMode: currentRoutingMode
                )
                let client = makeProxySelectionProviderClient()
                try await reloadActiveProfileStagingResources(preparedReload, via: client)
                await finalizeLiveProfileReload(client: client)
            }
            profileMessage = AppLocalization.inline(
                "Created and activated merged profile.",
                chinese: "已创建并启用组合订阅。"
            )
            profileMessageIsError = false
            return true
        } catch {
            if catalogUpdated, state == .connected, !isUIReviewMode,
               let previousActiveProfileID, previousActiveProfileID != activeProfileID {
                try? await applyProfileActivation(id: previousActiveProfileID)
            }
            profileMessage = localizedProfileOperationError(error)
            profileMessageIsError = true
            return false
        }
    }

    @discardableResult
    func rebuildMergedProfile(id: UUID) async -> Bool {
        guard ensurePrivacyConsent(), !isUpdatingProfiles, canActivateProfile else {
            return false
        }
        isUpdatingProfiles = true
        defer { isUpdatingProfiles = false }

        let previousManagedProfile = profiles.first(where: { $0.id == id })?.profile
        let remoteSources: [(id: UUID, subscription: ProfileSubscription)]
        if let targetManaged = profiles.first(where: { $0.id == id }),
           let spec = targetManaged.mergedSpec,
           !isUIReviewMode {
            let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            remoteSources = spec.sourceProfileIDs.compactMap { sourceID in
                guard let source = profilesByID[sourceID],
                      let subscription = source.profile.subscription,
                      canRefreshSubscription(id: sourceID) else {
                    return nil
                }
                return (sourceID, subscription)
            }
        } else {
            remoteSources = []
        }

        if !remoteSources.isEmpty {
            let sourceIDs = remoteSources.map(\.id)
            refreshingSubscriptionProfileIDs.formUnion(sourceIDs)
            isRefreshingSubscription = !refreshingSubscriptionProfileIDs.isEmpty
            defer {
                refreshingSubscriptionProfileIDs.subtract(sourceIDs)
                isRefreshingSubscription = !refreshingSubscriptionProfileIDs.isEmpty
            }

            let client = subscriptionClient
            let fetchedUpdates: [(UUID, Result<ProfileSubscriptionUpdate, Error>)] = await withTaskGroup(
                of: (UUID, Result<ProfileSubscriptionUpdate, Error>).self
            ) { group in
                for source in remoteSources {
                    group.addTask {
                        do {
                            let update = try await client.fetch(source.subscription)
                            return (source.id, .success(update))
                        } catch {
                            return (source.id, .failure(error))
                        }
                    }
                }
                var collected: [(UUID, Result<ProfileSubscriptionUpdate, Error>)] = []
                for await item in group {
                    collected.append(item)
                }
                return collected
            }

            for (sourceID, result) in fetchedUpdates {
                do {
                    let update = try result.get()
                    await refreshSubscription(
                        id: sourceID,
                        isAutomatic: true,
                        prefetchedUpdate: update,
                        rebuildDependents: false,
                        allowLiveReload: false
                    )
                } catch {
                    diagnosticEvents.record(.profileOperationFailed)
                    recordSubscriptionUpdateError(localizedProfileOperationError(error), for: sourceID)
                }
            }
        }

        let keepRuntime = state == .connected
        var rebuiltCatalog = false
        do {
            try await performProductionProfileCatalogOperation(
                preserveConnectedRuntimeState: keepRuntime
            ) {
                try ProfileCatalogStore.applicationGroup().rebuildMergedProfile(id: id)
            }
            rebuiltCatalog = true
            if id == activeProfileID, state == .connected, !isUIReviewMode {
                let currentRoutingMode = sessionRoutingMode ?? routingMode
                let preparedReload = try await prepareReloadProfilePayload(
                    requestedMode: currentRoutingMode
                )
                let client = makeProxySelectionProviderClient()
                try await reloadActiveProfileStagingResources(preparedReload, via: client)
                await finalizeLiveProfileReload(client: client)
            }
            profileMessage = AppLocalization.inline(
                "Rebuilt merged profile from source subscriptions.",
                chinese: "已根据源订阅重新合并节点。"
            )
            profileMessageIsError = false
            return true
        } catch {
            if rebuiltCatalog, id == activeProfileID, state == .connected, !isUIReviewMode {
                await setEnabled(false, isAutomaticReconnect: false, clearsUserIntent: false)
                _ = await waitForProviderToBecomeInactive()
                await setEnabled(true)
                if await waitForConnectionToSettle() {
                    profileMessage = AppLocalization.inline(
                        "Rebuilt merged profile from source subscriptions.",
                        chinese: "已根据源订阅重新合并节点。"
                    )
                    profileMessageIsError = false
                    return true
                }
                if let previousManagedProfile,
                   let currentProfile = profiles.first(where: { $0.id == id })?.profile {
                    nonisolated(unsafe) let defaults = userDefaults
                    try? await performProductionProfileCatalogOperation(preserveConnectedRuntimeState: false) {
                        try Self.replaceProfileContents(
                            id: id,
                            previous: currentProfile,
                            with: previousManagedProfile,
                            defaults: defaults
                        )
                    }
                }
            }
            profileMessage = localizedProfileOperationError(error)
            profileMessageIsError = true
            return false
        }
    }

    func loadAllExternalProviders() async -> (rules: [RuleProviderMetadata], proxies: [ProxyProviderMetadata]) {
        let yaml = activeProfile?.yaml ?? ""
        guard !yaml.isEmpty else { return ([], []) }
        let rules = await ruleProviderEngine.stagedProviders(inProfileYAML: yaml)
        let proxies = await proxyProviderEngine.stagedProviders(inProfileYAML: yaml)
        return (rules, proxies)
    }

    @discardableResult
    func refreshAllExternalProviders() async -> (rules: [RuleProviderMetadata], proxies: [ProxyProviderMetadata]) {
        let yaml = activeProfile?.yaml ?? ""
        let stagedRules: [RuleProviderMetadata]
        let stagedProxies: [ProxyProviderMetadata]
        if !yaml.isEmpty {
            stagedRules = await ruleProviderEngine.stageProviders(inProfileYAML: yaml, force: true)
            stagedProxies = await proxyProviderEngine.stageProviders(inProfileYAML: yaml, force: true)
        } else {
            stagedRules = []
            stagedProxies = []
        }
        _ = await ruleProviderEngine.updateAllExpired()

        await reloadCustomRuleProvidersFromEngine()
        refreshActiveProfileSummary()
        if state == .connected, !isUIReviewMode {
            await reloadCustomRulesLive()
        }
        profileMessage = AppLocalization.inline(
            "External rule and proxy providers staged.",
            chinese: "已刷新并暂存外部规则集与代理集合。"
        )
        profileMessageIsError = false
        return (stagedRules, stagedProxies)
    }

}
