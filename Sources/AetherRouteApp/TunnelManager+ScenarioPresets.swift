import AetherRouteKit
import Foundation
import OSLog

/// Built-in offline scenario rule presets (v3.1).
///
/// Preset states are persisted both in `ScenarioRulePresetStore` and inside the
/// global `ProfileOverride` so they take effect automatically on cold launch,
/// profile switch, and live reload without mutating any imported subscription.
extension TunnelManager {
    var scenarioRulePresetStates: [ScenarioRulePresetState] {
        let globalStates = loadGlobalProfileOverride().scenarioPresets
        if !globalStates.isEmpty {
            return ScenarioRulePresetState.normalized(globalStates)
        }
        if isUIReviewMode {
            return ScenarioRulePresetState.defaultStates()
        }
        return ScenarioRulePresetStore.applicationGroup().load()
    }

    var enabledScenarioRulePresetCount: Int {
        scenarioRulePresetStates.filter(\.isEnabled).count
    }

    func scenarioRulePresetState(for id: ScenarioRulePresetID) -> ScenarioRulePresetState {
        scenarioRulePresetStates.first(where: { $0.id == id })
            ?? ScenarioRulePresetState(id: id, isEnabled: false, target: id.defaultTarget)
    }

    var availableScenarioRulePresetGroups: [String] {
        (activeProfileSummary?.proxyGroups ?? []).map(\.name)
    }

    var primaryScenarioRulePresetGroupName: String? {
        availableScenarioRulePresetGroups.first { group in
            let upper = group.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return !upper.isEmpty && upper != "DIRECT" && upper != "REJECT" && upper != "REJECT-DROP"
        }
    }

    @discardableResult
    func setScenarioRulePresetEnabled(
        _ isEnabled: Bool,
        for id: ScenarioRulePresetID
    ) async -> Bool {
        await serializeScenarioPresetOperation {
            var states = self.scenarioRulePresetStates
            if let index = states.firstIndex(where: { $0.id == id }) {
                guard states[index].isEnabled != isEnabled else { return true }
                states[index].isEnabled = isEnabled
            } else {
                states.append(ScenarioRulePresetState(id: id, isEnabled: isEnabled))
            }
            return await self.persistAndApplyScenarioRulePresets(
                ScenarioRulePresetState.normalized(states),
                shouldReloadLive: true
            )
        }
    }

    @discardableResult
    func setScenarioRulePresetTarget(
        _ target: ScenarioRulePresetTarget,
        for id: ScenarioRulePresetID
    ) async -> Bool {
        await serializeScenarioPresetOperation {
            var states = self.scenarioRulePresetStates
            let wasEnabled: Bool
            if let index = states.firstIndex(where: { $0.id == id }) {
                guard states[index].target != target else { return true }
                states[index].target = target
                wasEnabled = states[index].isEnabled
            } else {
                states.append(ScenarioRulePresetState(id: id, isEnabled: false, target: target))
                wasEnabled = false
            }
            return await self.persistAndApplyScenarioRulePresets(
                ScenarioRulePresetState.normalized(states),
                shouldReloadLive: wasEnabled
            )
        }
    }

    private func serializeScenarioPresetOperation(
        _ operation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let previous = scenarioPresetQueueTask
        var result = false
        let task = Task { @MainActor in
            _ = await previous?.value
            result = await operation()
        }
        scenarioPresetQueueTask = task
        await task.value
        return result
    }

    private func persistAndApplyScenarioRulePresets(
        _ states: [ScenarioRulePresetState],
        shouldReloadLive: Bool
    ) async -> Bool {
        do {
            var globalOverride = loadGlobalProfileOverride()
            globalOverride.scenarioPresets = states
            let validated = try globalOverride.validated()
            if !isUIReviewMode {
                try await Task.detached(priority: .userInitiated) {
                    try ScenarioRulePresetStore.applicationGroup().save(states)
                    try ProfileOverrideStore.applicationGroup().saveGlobalOverride(validated)
                }.value
            }
            objectWillChange.send()
            cachedGlobalProfileOverride = validated
            cachedEffectiveProfileCompilation = nil
            refreshActiveProfileSummary()
            Self.runtimeLogger.info(
                "stage=scenarioPresets saved enabled=\(states.filter(\.isEnabled).count, privacy: .public)"
            )
            if shouldReloadLive {
                await reloadCustomRulesLive()
            }
            return true
        } catch {
            Self.runtimeLogger.error(
                "stage=scenarioPresets saveFailed error=\(String(reflecting: error), privacy: .public)"
            )
            customRuleMessage = error.localizedDescription
            customRuleMessageIsError = true
            return false
        }
    }
}
