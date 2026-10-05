import Foundation
import AetherRouteKit

extension TunnelManager {

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

    /// The application rule that names this app, if any.
    func applicationRule(
        bundleIdentifier: String?,
        bundlePath: String?
    ) -> CustomRule? {
        customRules.first { rule in
            guard let match = rule.applicationMatch else { return false }
            if let bundlePath, let path = match.bundlePath {
                return path == bundlePath
            }
            return bundleIdentifier != nil && match.bundleIdentifier == bundleIdentifier
        }
    }

    /// Sends one app's connections to `target`, replacing the app's existing
    /// rule so the list never holds two rules for the same app.
    @discardableResult
    func setApplicationRule(
        bundleIdentifier: String?,
        bundlePath: String?,
        displayName: String,
        target: CustomRuleTarget
    ) async -> Bool {
        let existing = applicationRule(
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath
        )
        guard let rule = CustomRule.application(
            id: existing?.id ?? UUID(),
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath,
            displayName: displayName,
            target: target
        ) else {
            customRuleMessage = AppLocalization.string("This app cannot be used in a rule.")
            customRuleMessageIsError = true
            return false
        }
        return existing == nil
            ? await addCustomRule(rule)
            : await updateCustomRule(rule)
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
