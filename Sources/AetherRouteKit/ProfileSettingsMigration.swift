import Foundation

/// Preference keys for a group's node selection mode. Both are bound to the
/// profile's text and the group's name; the text changes whenever a
/// subscription update changes anything, see `ProfileSettingsMigration`.
public enum ProxySelectionPreferenceKeys {
    /// The 1.6.0 mode (`manual`, `fastest`, `failover`).
    public static func mode(profileYAML: String, group: String) -> String {
        "AetherRoute.ProxySelection.Mode."
            + ProxySelectionStore.profileDigest(
                yaml: profileYAML + "\u{0}selection-mode\u{0}" + group
            )
    }

    /// The on/off switch from before 1.6.0, still written so an older
    /// version keeps switching automatically.
    public static func legacyAutomatic(profileYAML: String, group: String) -> String {
        "AetherRoute.ProxySelection.Automatic."
            + ProxySelectionStore.profileDigest(
                yaml: profileYAML + "\u{0}automatic-selection\u{0}" + group
            )
    }
}

/// What a migration carried over, for logs and tests.
public struct ProfileSettingsMigrationReport: Equatable, Sendable {
    public var selections = 0
    public var preferredNodes = 0
    public var modes = 0
    public var dnsPolicy = false

    public init() {}

    public var isEmpty: Bool {
        selections == 0 && preferredNodes == 0 && modes == 0 && !dnsPolicy
    }
}

/// Carries a profile's settings over when its text changes (1.7.0).
///
/// The node each group uses, each group's selection mode and preferred node,
/// and the DNS override are stored under a digest of the profile's text, so
/// that a choice can never be applied to a different profile. A subscription
/// update that renames one node (many providers put the remaining traffic in
/// a name) changes the text, and every one of those settings fell back to
/// its default. This moves them to the new text, keeping only groups and
/// nodes the new profile still has, and never overwrites a setting the new
/// text already has.
public enum ProfileSettingsMigration {
    public static func migrate(
        fromYAML oldYAML: String,
        toYAML newYAML: String,
        selectionStore: ProxySelectionStore?,
        preferenceStore: ProxySelectionStore?,
        dnsStore: DNSRuntimePolicyStore?,
        defaults: UserDefaults
    ) -> ProfileSettingsMigrationReport {
        var report = ProfileSettingsMigrationReport()
        guard oldYAML != newYAML else { return report }

        let oldGroups = ProfileConfigurationInspector.inspect(yaml: oldYAML).proxyGroups
        let newGroups = Dictionary(
            ProfileConfigurationInspector.inspect(yaml: newYAML).proxyGroups
                .map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for store in [selectionStore, preferenceStore] {
            guard let store,
                  let old = try? store.selections(forProfileYAML: oldYAML),
                  !old.isEmpty else { continue }
            let kept = old.filter { group, member in
                guard let summary = newGroups[group] else { return false }
                return Self.groupMayContain(summary, member: member)
            }
            guard !kept.isEmpty else { continue }
            let before = (try? store.selections(forProfileYAML: newYAML)) ?? [:]
            guard (try? store.mergeSelections(kept, profileYAML: newYAML)) != nil
            else { continue }
            let carried = kept.keys.filter { before[$0] == nil }.count
            if store.kind == .selections {
                report.selections += carried
            } else {
                report.preferredNodes += carried
            }
        }

        for group in oldGroups where newGroups[group.name] != nil {
            let keys = [
                (
                    ProxySelectionPreferenceKeys.mode(profileYAML: oldYAML, group: group.name),
                    ProxySelectionPreferenceKeys.mode(profileYAML: newYAML, group: group.name)
                ),
                (
                    ProxySelectionPreferenceKeys.legacyAutomatic(profileYAML: oldYAML, group: group.name),
                    ProxySelectionPreferenceKeys.legacyAutomatic(profileYAML: newYAML, group: group.name)
                ),
            ]
            var carried = false
            for (oldKey, newKey) in keys {
                guard let value = defaults.object(forKey: oldKey),
                      defaults.object(forKey: newKey) == nil else { continue }
                defaults.set(value, forKey: newKey)
                carried = true
            }
            if carried { report.modes += 1 }
        }

        if let dnsStore,
           let policy = try? dnsStore.loadIfPresent(forProfileYAML: oldYAML),
           (try? dnsStore.loadIfPresent(forProfileYAML: newYAML)) == nil,
           (try? dnsStore.save(policy, forProfileYAML: newYAML)) != nil {
            report.dnsPolicy = true
        }
        return report
    }

    /// The same migration against the shared App Group stores.
    @discardableResult
    public static func migrateInApplicationGroup(
        fromYAML oldYAML: String,
        toYAML newYAML: String,
        defaults: UserDefaults
    ) -> ProfileSettingsMigrationReport {
        migrate(
            fromYAML: oldYAML,
            toYAML: newYAML,
            selectionStore: try? ProxySelectionStore.applicationGroup(kind: .selections),
            preferenceStore: try? ProxySelectionStore.applicationGroup(kind: .preferences),
            dnsStore: try? DNSRuntimePolicyStore.applicationGroup(),
            defaults: defaults
        )
    }

    /// A group's inline member list is bounded, so a member missing from a
    /// truncated list may still belong to it.
    static func groupMayContain(
        _ group: ProxyGroupConfigurationSummary,
        member: String
    ) -> Bool {
        group.members.contains(member) || group.members.count < group.memberCount
    }
}
