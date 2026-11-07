import AetherRouteKit
import Foundation

extension TunnelManager {
    func reloadCustomRuleProvidersFromEngine() async {
        guard !isUIReviewMode else { return }
        customRuleProviders = await RuleProviderEngine.shared.allProviders()
        compiledRemoteRulesCache = await RuleProviderEngine.shared.compileActiveRules()
    }

    @discardableResult
    func addCustomRuleProvider(_ provider: RuleProviderMetadata) async -> Bool {
        do {
            try await RuleProviderEngine.shared.registerProvider(provider)
            refreshingRuleProviderIDs.insert(provider.id)
            defer { refreshingRuleProviderIDs.remove(provider.id) }
            do {
                let count = try await RuleProviderEngine.shared.forceRefresh(id: provider.id)
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
            try await RuleProviderEngine.shared.registerProvider(provider)
            if previousURL != provider.url || provider.lastUpdatedAt == nil {
                refreshingRuleProviderIDs.insert(provider.id)
                defer { refreshingRuleProviderIDs.remove(provider.id) }
                do {
                    _ = try await RuleProviderEngine.shared.forceRefresh(id: provider.id)
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
        _ = await RuleProviderEngine.shared.toggleProvider(id: id)
        ruleProviderMessage = nil
        ruleProviderMessageIsError = false
        await reloadCustomRuleProvidersFromEngine()
        refreshActiveProfileSummary()
        await reloadCustomRulesLive()
        Task { _ = try? await ProfileCloudSyncManager.shared.sync() }
    }

    func deleteCustomRuleProvider(id: UUID) async {
        await RuleProviderEngine.shared.removeProvider(id: id)
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
            let count = try await RuleProviderEngine.shared.forceRefresh(id: id)
            ruleProviderMessage = String.localizedStringWithFormat(
                AppLocalization.string("Rule provider updated (%lld rules)"),
                Int64(count)
            )
            ruleProviderMessageIsError = false
            await reloadCustomRuleProvidersFromEngine()
            refreshActiveProfileSummary()
            await reloadCustomRulesLive()
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
                _ = try await RuleProviderEngine.shared.forceRefresh(id: id)
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
