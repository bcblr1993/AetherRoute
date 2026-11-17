import AetherRouteKit
import Foundation

extension TunnelManager {
    func reloadCustomRuleProvidersFromEngine(additionalProfileYAMLs: [String] = []) async {
        guard !isUIReviewMode || ruleProviderEngine !== RuleProviderEngine.shared else { return }
        var yamls = profiles.map(\.profile.yaml)
        if let activeYAML = activeProfile?.yaml {
            yamls.append(activeYAML)
        }
        yamls.append(contentsOf: additionalProfileYAMLs)
        if !yamls.isEmpty {
            await ruleProviderEngine.reconcileLegacyProfileProviders(inProfileYAMLs: yamls)
        }
        customRuleProviders = await ruleProviderEngine.allProviders()
        compiledRemoteRulesCache = await ruleProviderEngine.compileActiveRules()
    }

    @discardableResult
    func addCustomRuleProvider(_ provider: RuleProviderMetadata) async -> Bool {
        do {
            try await ruleProviderEngine.registerProvider(provider)
            refreshingRuleProviderIDs.insert(provider.id)
            defer { refreshingRuleProviderIDs.remove(provider.id) }
            do {
                let count = try await ruleProviderEngine.forceRefresh(id: provider.id)
                ruleProviderMessage = String.localizedStringWithFormat(
                    AppLocalization.string("Rule provider added (%lld rules loaded)"),
                    Int64(count)
                )
                ruleProviderMessageIsError = false
            } catch {
                ruleProviderMessage = error.localizedDescription
                ruleProviderMessageIsError = true
            }
            await reloadCustomRuleProvidersFromEngine()
            refreshActiveProfileSummary()
            await reloadCustomRulesLive()
            Task { _ = try? await ProfileCloudSyncManager.shared.sync() }
            return true
        } catch {
            ruleProviderMessage = error.localizedDescription
            ruleProviderMessageIsError = true
            return false
        }
    }

    @discardableResult
    func updateCustomRuleProvider(_ provider: RuleProviderMetadata) async -> Bool {
        let previousURL = customRuleProviders.first(where: { $0.id == provider.id })?.url
        do {
            try await ruleProviderEngine.registerProvider(provider)
            if previousURL != provider.url || provider.lastUpdatedAt == nil {
                refreshingRuleProviderIDs.insert(provider.id)
                defer { refreshingRuleProviderIDs.remove(provider.id) }
                do {
                    _ = try await ruleProviderEngine.forceRefresh(id: provider.id)
                    ruleProviderMessage = AppLocalization.string("Rule provider updated")
                    ruleProviderMessageIsError = false
                } catch {
                    ruleProviderMessage = error.localizedDescription
                    ruleProviderMessageIsError = true
                }
            } else {
                ruleProviderMessage = AppLocalization.string("Rule provider updated")
                ruleProviderMessageIsError = false
            }
            await reloadCustomRuleProvidersFromEngine()
            refreshActiveProfileSummary()
            await reloadCustomRulesLive()
            Task { _ = try? await ProfileCloudSyncManager.shared.sync() }
            return true
        } catch {
            ruleProviderMessage = error.localizedDescription
            ruleProviderMessageIsError = true
            return false
        }
    }

    func toggleCustomRuleProvider(id: UUID) async {
        _ = await ruleProviderEngine.toggleProvider(id: id)
        ruleProviderMessage = nil
        ruleProviderMessageIsError = false
        await reloadCustomRuleProvidersFromEngine()
        refreshActiveProfileSummary()
        await reloadCustomRulesLive()
        Task { _ = try? await ProfileCloudSyncManager.shared.sync() }
    }

    func deleteCustomRuleProvider(id: UUID) async {
        await ruleProviderEngine.removeProvider(id: id)
        ruleProviderMessage = AppLocalization.string("Rule provider removed")
        ruleProviderMessageIsError = false
        await reloadCustomRuleProvidersFromEngine()
        refreshActiveProfileSummary()
        await reloadCustomRulesLive()
        Task { _ = try? await ProfileCloudSyncManager.shared.sync() }
    }

    func refreshCustomRuleProvider(id: UUID) async {
        guard !refreshingRuleProviderIDs.contains(id) else { return }
        refreshingRuleProviderIDs.insert(id)
        defer { refreshingRuleProviderIDs.remove(id) }
        do {
            let count = try await ruleProviderEngine.forceRefresh(id: id)
            ruleProviderMessage = String.localizedStringWithFormat(
                AppLocalization.string("Rule provider updated (%lld rules)"),
                Int64(count)
            )
            ruleProviderMessageIsError = false
            await reloadCustomRuleProvidersFromEngine()
            refreshActiveProfileSummary()
            await reloadCustomRulesLive()
        } catch is CancellationError {
            // Provider URL/format was edited mid-refresh and superseded by a newer fetch.
        } catch RuleProviderError.providerNotFound {
            // Provider was deleted while the refresh request was in flight.
        } catch {
            ruleProviderMessage = error.localizedDescription
            ruleProviderMessageIsError = true
        }
    }

    func refreshAllCustomRuleProviders() async {
        guard !isRefreshingAllRuleProviders else { return }
        isRefreshingAllRuleProviders = true
        defer { isRefreshingAllRuleProviders = false }
        var updatedCount = 0
        var lastError: Error?
        let ids = customRuleProviders.map(\.id)
        for id in ids {
            refreshingRuleProviderIDs.insert(id)
            do {
                _ = try await ruleProviderEngine.forceRefresh(id: id)
                updatedCount += 1
            } catch {
                lastError = error
            }
            refreshingRuleProviderIDs.remove(id)
        }
        await reloadCustomRuleProvidersFromEngine()
        refreshActiveProfileSummary()
        await reloadCustomRulesLive()
        if let lastError, updatedCount == 0 {
            ruleProviderMessage = lastError.localizedDescription
            ruleProviderMessageIsError = true
        } else {
            ruleProviderMessage = String.localizedStringWithFormat(
                AppLocalization.string("Updated %lld rule providers"),
                Int64(updatedCount)
            )
            ruleProviderMessageIsError = false
        }
    }
}
