import Foundation
import AetherRouteKit

extension TunnelManager {
    func loadCustomRules() {
        do {
            self.customRules = try CustomRuleStore.applicationGroup().load()
            refreshActiveProfileSummary()
        } catch {
            Self.runtimeLogger.error("Failed to load custom rules: \(String(reflecting: error), privacy: .public)")
            self.customRules = []
        }
    }

    @discardableResult
    func addCustomRule(_ rule: CustomRule) async -> Bool {
        isUpdatingCustomRules = true
        defer { isUpdatingCustomRules = false }
        do {
            customRules = try CustomRuleStore.applicationGroup().add(rule)
            customRuleMessage = AppLocalization.string("Custom rule added and active at top priority")
            customRuleMessageIsError = false
            refreshActiveProfileSummary()
            await reloadCustomRulesLive()
            return true
        } catch {
            customRuleMessage = error.localizedDescription
            customRuleMessageIsError = true
            return false
        }
    }

    @discardableResult
    func updateCustomRule(_ rule: CustomRule) async -> Bool {
        isUpdatingCustomRules = true
        defer { isUpdatingCustomRules = false }
        do {
            customRules = try CustomRuleStore.applicationGroup().update(rule)
            customRuleMessage = AppLocalization.string("Custom rule updated")
            customRuleMessageIsError = false
            refreshActiveProfileSummary()
            await reloadCustomRulesLive()
            return true
        } catch {
            customRuleMessage = error.localizedDescription
            customRuleMessageIsError = true
            return false
        }
    }

    @discardableResult
    func deleteCustomRule(id: UUID) async -> Bool {
        isUpdatingCustomRules = true
        defer { isUpdatingCustomRules = false }
        do {
            customRules = try CustomRuleStore.applicationGroup().delete(id: id)
            customRuleMessage = AppLocalization.string("Custom rule deleted")
            customRuleMessageIsError = false
            refreshActiveProfileSummary()
            await reloadCustomRulesLive()
            return true
        } catch {
            customRuleMessage = error.localizedDescription
            customRuleMessageIsError = true
            return false
        }
    }

    @discardableResult
    func toggleCustomRule(id: UUID) async -> Bool {
        isUpdatingCustomRules = true
        defer { isUpdatingCustomRules = false }
        do {
            customRules = try CustomRuleStore.applicationGroup().toggle(id: id)
            customRuleMessage = nil
            customRuleMessageIsError = false
            refreshActiveProfileSummary()
            await reloadCustomRulesLive()
            return true
        } catch {
            customRuleMessage = error.localizedDescription
            customRuleMessageIsError = true
            return false
        }
    }

    func reloadCustomRulesLive() async {
        guard !isUIReviewMode, state == .connected else { return }
        do {
            let currentRoutingMode = sessionRoutingMode ?? routingMode
            let reloadPayloadData = try await prepareReloadProfilePayload(
                requestedMode: currentRoutingMode
            )
            let client = makeProxySelectionProviderClient()
            Self.runtimeLogger.info("stage=customRules liveReload sending payload bytes=\(reloadPayloadData.count)")
            try await client.reloadActiveProfile(payload: reloadPayloadData)
            Self.runtimeLogger.info("stage=customRules liveReload succeeded")
        } catch {
            Self.runtimeLogger.error(
                "stage=customRules liveReload failed error=\(String(reflecting: error), privacy: .public)"
            )
        }
    }

    func refreshActiveProfileSummary() {
        guard let activeProfile else { return }
        let rawProfileYAML = activeProfile.yaml
        let profileYAML = isDomesticOptimizationEnabled
            ? DomesticRoutingOptimizer.optimizedProfile(for: rawProfileYAML, customRules: customRules)
            : (customRules.isEmpty ? rawProfileYAML : DomesticRoutingOptimizer.optimizedProfile(for: rawProfileYAML, customRules: customRules))
        activeProfileSummary = ProfileConfigurationInspector.inspect(
            yaml: profileYAML,
            customRules: customRules
        )
    }
}
