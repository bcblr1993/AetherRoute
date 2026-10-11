import AetherRouteKit
import Foundation
import OSLog

/// Profile overrides (1.7.0): custom groups and hidden nodes. Saving one
/// while connected reloads the running profile in place, the way custom
/// rules do, instead of reinstalling the profile and clearing every live
/// selection and latency.
extension TunnelManager {
    var activeProfileOverrides: ProfileOverride {
        activeProfile?.overrides ?? ProfileOverride()
    }

    func customProxyGroup(named name: String) -> CustomProxyGroup? {
        activeProfile?.overrides?.groups.first { $0.name == name }
    }

    /// What the override does to the active profile right now: each custom
    /// group's members and the diagnostics, for the editor and the cards.
    func activeOverrideResult(_ overrides: ProfileOverride? = nil) -> ProfileOverrideResult? {
        guard let activeProfile else { return nil }
        return ProfileOverrideCompiler.apply(overrides ?? activeProfile.overrides, to: activeProfile.yaml)
    }

    /// Every node name in the active profile, in order, for pickers and
    /// previews (the profile itself, before any override).
    var activeProfileNodeNames: [String] {
        guard let activeProfile else { return [] }
        return ProfileOverrideCompiler.nodeNames(in: activeProfile.yaml)
    }

    /// Saves a profile's overrides. Returns false and sets `profileMessage`
    /// when they cannot be saved.
    @discardableResult
    func setProfileOverrides(
        _ overrides: ProfileOverride?,
        profileID: UUID? = nil,
        reloadsRunningProfile: Bool = true
    ) async -> Bool {
        guard ensurePrivacyConsent(),
              let id = profileID ?? activeProfileID,
              profiles.contains(where: { $0.id == id }) else { return false }
        let validated: ProfileOverride?
        do {
            validated = try overrides?.validated()
        } catch {
            profileMessage = error.overrideMessage
            profileMessageIsError = true
            return false
        }
        do {
            let catalog: ProfileCatalog
            if isUIReviewMode {
                var updated = profiles
                guard let index = updated.firstIndex(where: { $0.id == id }) else { return false }
                updated[index] = ManagedProfile(id: id, profile: updated[index].profile.withOverrides(validated))
                catalog = ProfileCatalog(activeProfileID: activeProfileID, profiles: updated)
            } else {
                catalog = try await Task.detached(priority: .userInitiated) {
                    try ProfileCatalogStore.applicationGroup().setOverrides(id: id, overrides: validated)
                }.value
            }
            profiles = catalog.profiles
            guard id == activeProfileID else { return true }
            let previousCustomGroups = Set(activeProfile?.overrides?.groups.map(\.name) ?? [])
            activeProfile = catalog.profiles.first { $0.id == id }?.profile
            refreshActiveProfileSummary()
            applyCustomGroupModes(removing: previousCustomGroups)
            Self.runtimeLogger.info(
                "stage=profileOverrides saved groups=\(validated?.groups.count ?? 0, privacy: .public) hidden=\(validated?.hiddenNodeKeywords.count ?? 0, privacy: .public)"
            )
            if reloadsRunningProfile {
                await reloadCustomRulesLive()
                await activateCustomGroupsAfterReload()
            }
            return true
        } catch {
            profileMessage = localizedProfileOperationError(error)
            profileMessageIsError = true
            return false
        }
    }

    /// Custom groups carry their own mode; other groups keep the mode saved
    /// for them.
    func applyCustomGroupModes(removing previous: Set<String> = []) {
        var modes = proxySelectionModes
        for name in previous { modes[name] = nil }
        var preferred = preferredProxyMembers
        for group in activeProfile?.overrides?.groups ?? [] {
            modes[group.name] = group.mode == .manual ? nil : group.mode
            if group.mode != .failover { preferred[group.name] = nil }
        }
        applyProxySelectionModes(modes)
        preferredProxyMembers = preferred
    }

    /// After the running profile was reloaded, read each custom group's
    /// selection and let automatic ones pick a working node.
    private func activateCustomGroupsAfterReload() async {
        guard state == .connected, !isUIReviewMode,
              let summary = activeProfileSummary else { return }
        let client = makeProxySelectionProviderClient()
        for custom in activeProfile?.overrides?.groups ?? [] {
            guard let group = summary.proxyGroups.first(where: { $0.name == custom.name }) else { continue }
            if custom.mode == .manual || group.memberCount < 2 {
                await refreshProxySelection(group: custom.name, now: .distantFuture)
                continue
            }
            let preferred = custom.mode == .failover
                ? await ensurePreferredProxyMember(group: group)
                : nil
            if let selected = try? await selectFastestAvailableProxy(
                group: group,
                client: client,
                preferredMember: preferred
            ), custom.mode == .failover, preferredProxyMembers[custom.name] == nil,
               let member = selected.selectedMember {
                preferredProxyMembers[custom.name] = member
            }
            if automaticReadinessGroupNames.count
                < TunnelStartupTimingPolicy.maximumMonitoredAutomaticGroupCount + 1 {
                automaticReadinessGroupNames.insert(custom.name)
            }
        }
    }

    /// Changes a custom group's mode in its override, without reloading
    /// the running profile: the groups themselves did not change.
    func persistCustomGroupMode(_ mode: ProxySelectionMode, group name: String) async -> Bool {
        var overrides = activeProfileOverrides
        guard let index = overrides.groups.firstIndex(where: { $0.name == name }) else { return false }
        overrides.groups[index].mode = mode
        return await setProfileOverrides(overrides, reloadsRunningProfile: false)
    }
}
