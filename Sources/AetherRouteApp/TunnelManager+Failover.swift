import AetherRouteKit
import Foundation
import OSLog

/// Node selection modes and failover (1.6.0): manual, fastest, and failover
/// with a preferred node the group returns to once it answers again.
extension TunnelManager {
    func proxySelectionMode(for group: String) -> ProxySelectionMode {
        proxySelectionModes[group] ?? .manual
    }

    func proxySelectionModePreferenceKey(
        profileYAML: String,
        group: String
    ) -> String {
        ProxySelectionPreferenceKeys.mode(profileYAML: profileYAML, group: group)
    }

    /// Reads every `select` group's mode for the active profile. A group
    /// switched on before 1.6.0 reads as `fastest`.
    func loadProxySelectionModes(
        groups: [ProxyGroupConfigurationSummary],
        profileYAML: String?
    ) {
        var modes: [String: ProxySelectionMode] = [:]
        if let profileYAML {
            for group in groups where group.strategy
                .caseInsensitiveCompare("select") == .orderedSame {
                let mode = ProxySelectionMode.resolve(
                    stored: userDefaults.string(
                        forKey: proxySelectionModePreferenceKey(
                            profileYAML: profileYAML,
                            group: group.name
                        )
                    ),
                    legacyAutomatic: userDefaults.bool(
                        forKey: automaticProxySelectionPreferenceKey(
                            profileYAML: profileYAML,
                            group: group.name
                        )
                    )
                )
                if mode != .manual { modes[group.name] = mode }
            }
        }
        applyProxySelectionModes(modes)
        preferredProxyMembers = [:]
        // Custom groups (1.7.0) keep their mode in the profile's override.
        applyCustomGroupModes()
        failoverRecoveryTracker.resetAll()
        failoverRecoveryScannedAt = [:]
        guard !isUIReviewMode, let profileYAML,
              proxySelectionModes.values.contains(.failover) else { return }
        Task { await loadPreferredProxyMembers(profileYAML: profileYAML) }
    }

    func applyProxySelectionModes(_ modes: [String: ProxySelectionMode]) {
        proxySelectionModes = modes
        automaticProxySelectionGroups = Set(modes.keys)
    }

    private func loadPreferredProxyMembers(profileYAML: String) async {
        let stored = try? await Task.detached(priority: .utility) {
            try ProxySelectionStore.applicationGroup(kind: .preferences)
                .selections(forProfileYAML: profileYAML)
        }.value
        // The profile may have changed while the file was read.
        guard activeProfile?.yaml == profileYAML else { return }
        var preferred: [String: String] = [:]
        for (group, mode) in proxySelectionModes where mode == .failover {
            guard let summary = activeProfileSummary?.proxyGroups
                .first(where: { $0.name == group }) else { continue }
            preferred[group] = ProxyFailoverPolicy.preferredMember(
                stored: stored?[group],
                current: proxySelections[group]?.selectedMember,
                members: summary.members
            )
        }
        preferredProxyMembers = preferred
    }

    /// The preferred node of a failover group, read from disk when the
    /// profile was installed moments ago and the read has not finished.
    func ensurePreferredProxyMember(
        group summary: ProxyGroupConfigurationSummary
    ) async -> String? {
        if let preferred = preferredProxyMembers[summary.name] {
            return preferred
        }
        guard !isUIReviewMode, let yaml = activeProfile?.yaml else { return nil }
        let stored = try? await Task.detached(priority: .userInitiated) {
            try ProxySelectionStore.applicationGroup(kind: .preferences)
                .selections(forProfileYAML: yaml)
        }.value
        guard let member = stored?[summary.name],
              summary.members.contains(member) else { return nil }
        preferredProxyMembers[summary.name] = member
        return member
    }

    private func persistPreferredProxy(group: String, member: String) {
        guard !isUIReviewMode, let yaml = activeProfile?.yaml,
              let members = activeProfileSummary?.proxyGroups
                .first(where: { $0.name == group })?.members else { return }
        Task.detached(priority: .utility) {
            try? ProxySelectionStore.applicationGroup(kind: .preferences)
                .recordUserSelection(
                    group: group,
                    member: member,
                    allowedMembers: members,
                    profileYAML: yaml
                )
        }
    }

    /// Changes a `select` group's mode. Turning on an automatic mode while
    /// connected selects a node right away and reverts when none passes.
    func setProxySelectionMode(
        group groupName: String,
        mode: ProxySelectionMode
    ) async {
        guard let group = activeProfileSummary?.proxyGroups.first(where: {
            $0.name == groupName
                && $0.strategy.caseInsensitiveCompare("select") == .orderedSame
        }), group.memberCount > 1 else { return }
        let yaml = activeProfile?.yaml
        guard yaml != nil || isUIReviewMode else { return }

        let previous = proxySelectionMode(for: groupName)
        guard previous != mode else { return }
        let isCustom = customProxyGroup(named: groupName) != nil
        if isCustom {
            guard await persistCustomGroupMode(mode, group: groupName) else { return }
        } else {
            persistProxySelectionMode(mode, group: groupName, profileYAML: yaml)
        }
        var modes = proxySelectionModes
        modes[groupName] = mode == .manual ? nil : mode
        applyProxySelectionModes(modes)
        failoverRecoveryTracker.reset(group: groupName)
        failoverRecoveryScannedAt[groupName] = nil
        proxySelectionMessages[groupName] = nil

        if mode == .failover {
            let preferred = ProxyFailoverPolicy.preferredMember(
                stored: preferredProxyMembers[groupName],
                current: proxySelections[groupName]?.selectedMember,
                members: group.members
            )
            preferredProxyMembers[groupName] = preferred
            if let preferred {
                persistPreferredProxy(group: groupName, member: preferred)
            }
        }

        guard mode != .manual else {
            automaticReadinessGroupNames.remove(groupName)
            automaticReadinessChildGroups[groupName] = nil
            automaticRouteFailureCounts[groupName] = nil
            updateAutomaticRouteRecoveryPresentation()
            return
        }
        guard isConnected, !isUIReviewMode else { return }

        // Failover keeps the node in use when it is already the preferred
        // one; there is nothing to move.
        if mode == .failover,
           proxySelections[groupName]?.selectedMember
            == preferredProxyMembers[groupName] {
            automaticReadinessGroupNames.insert(groupName)
            return
        }
        do {
            _ = try await selectFastestAvailableProxy(
                group: group,
                client: makeProxySelectionProviderClient(),
                preferredMember: mode == .failover
                    ? preferredProxyMembers[groupName]
                    : nil
            )
            automaticReadinessGroupNames.insert(groupName)
        } catch {
            if isCustom {
                _ = await persistCustomGroupMode(previous, group: groupName)
            } else {
                persistProxySelectionMode(previous, group: groupName, profileYAML: yaml)
            }
            var reverted = proxySelectionModes
            reverted[groupName] = previous == .manual ? nil : previous
            applyProxySelectionModes(reverted)
            proxySelectionMessages[groupName] = AppLocalization.string(
                "No proxy node in this group passed the automatic connection check."
            )
        }
    }

    /// Kept for callers from before 1.6.0: on means fastest.
    func setProxySelectionAutomatic(
        group groupName: String,
        isAutomatic: Bool
    ) async {
        await setProxySelectionMode(
            group: groupName,
            mode: isAutomatic ? .fastest : .manual
        )
    }

    private func persistProxySelectionMode(
        _ mode: ProxySelectionMode,
        group: String,
        profileYAML: String?
    ) {
        guard let profileYAML else { return }
        userDefaults.set(
            mode.rawValue,
            forKey: proxySelectionModePreferenceKey(
                profileYAML: profileYAML,
                group: group
            )
        )
        // An older version reading these defaults keeps switching
        // automatically, as close to failover as it can.
        userDefaults.set(
            mode.switchesAutomatically,
            forKey: automaticProxySelectionPreferenceKey(
                profileYAML: profileYAML,
                group: group
            )
        )
    }

    /// A node picked by the person in failover mode becomes the preferred
    /// node, and the group moves to it.
    func setPreferredProxy(group groupName: String, member: String) async {
        guard proxySelectionMode(for: groupName) == .failover else { return }
        preferredProxyMembers[groupName] = member
        persistPreferredProxy(group: groupName, member: member)
        failoverRecoveryTracker.reset(group: groupName)
        failoverRecoveryScannedAt[groupName] = nil
        await performProxySelectionRequest(
            group: groupName,
            requestedMember: member
        )
    }

    /// Records an automatic switch, tells observers, and drops connections
    /// the switch left behind.
    func recordAutomaticProxySwitch(
        group: String,
        from previous: String?,
        to member: String,
        reason: ProxySwitchEvent.Reason,
        at date: Date = .now
    ) async {
        guard previous != member else { return }
        let event = ProxySwitchEvent(
            date: date,
            group: group,
            from: previous,
            to: member,
            reason: reason
        )
        proxySwitchLog.record(event)
        proxySwitchEvents.send(event)
        Self.runtimeLogger.info(
            "stage=automaticSwitch reason=\(reason.rawValue, privacy: .public)"
        )
        if let request = ProxyFailoverPolicy.closeRequest(
            reason: reason,
            group: group,
            previousMember: previous,
            closesConnectionsOnSwitch: closesConnectionsOnProxySwitch
        ) {
            await closeConnections(request)
        }
    }

    /// While failover mode uses a backup, scans the group now and then and
    /// returns to the preferred node once it has answered in enough scans
    /// in a row. A failed return goes back to the backup.
    func checkFailoverRecovery(
        group summary: ProxyGroupConfigurationSummary,
        client: ProxySelectionProviderClient,
        now: Date = .now
    ) async {
        let group = summary.name
        guard proxySelectionMode(for: group) == .failover,
              let preferred = preferredProxyMembers[group],
              let current = proxySelections[group]?.selectedMember,
              current != preferred else {
            failoverRecoveryTracker.reset(group: group)
            return
        }
        guard ProxyFailoverPolicy.recoveryScanIsDue(
            lastScan: failoverRecoveryScannedAt[group],
            now: now
        ) else { return }
        failoverRecoveryScannedAt[group] = now

        let responded: Bool
        do {
            let latency = try await client.latency(
                group: group,
                url: Self.selectorLatencyTestURL,
                timeoutMilliseconds: TunnelStartupTimingPolicy
                    .selectorReadinessPerMemberTimeoutMilliseconds
            )
            adoptProviderLatency(latency, forGroup: group)
            responded = latency.results.contains {
                $0.member == preferred && $0.delayMilliseconds != nil
            }
        } catch is CancellationError {
            return
        } catch {
            responded = false
        }
        guard failoverRecoveryTracker.record(
            group: group,
            preferredResponded: responded
        ) else { return }
        failoverRecoveryTracker.reset(group: group)

        do {
            let selected = try await client.select(group: group, member: preferred)
            guard selected.selectedMember == preferred else {
                throw TunnelManagerError.providerSelectorUnavailable
            }
            if isCatchAllRouteGroup(group) {
                try await verifyCurrentRouteDataPlane()
            }
            proxySelections[group] = selected
            await recordAutomaticProxySwitch(
                group: group,
                from: current,
                to: preferred,
                reason: .preferredRecovered,
                at: now
            )
            if let yaml = activeProfile?.yaml {
                try? await Task.detached(priority: .utility) {
                    try ProxySelectionStore.applicationGroup().recordVerified(
                        snapshot: selected,
                        group: group,
                        profileYAML: yaml
                    )
                }.value
            }
        } catch is CancellationError {
            return
        } catch {
            Self.runtimeLogger.error("stage=failoverRecovery returnFailed")
            if let restored = try? await client.select(group: group, member: current) {
                proxySelections[group] = restored
            }
        }
    }
}
