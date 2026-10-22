import Foundation

/// When each user rule last changed and when removed rules were deleted, so
/// iCloud sync can tell a deletion from a rule another device has not seen.
///
/// Kept beside the rule files rather than in the rules: the rule formats and
/// their equality stay unchanged, and rules written before 1.8.7 simply have
/// no entry (treated as changed long ago).
public struct RuleSyncMetadata: Codable, Equatable, Sendable {
    /// Deletions older than the newest this many are forgotten. A device
    /// offline across that many deletions may bring the oldest ones back.
    public static let maximumTombstones = 1_024

    /// Rule ID (uuidString) → last content change.
    public var modifiedAt: [String: Date]
    /// Rule ID (uuidString) → deletion time.
    public var deletedAt: [String: Date]

    public static let empty = RuleSyncMetadata(modifiedAt: [:], deletedAt: [:])

    public init(modifiedAt: [String: Date] = [:], deletedAt: [String: Date] = [:]) {
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }

    /// Records the edits and deletions that turn `old` into `new`. Order
    /// changes are not edits.
    public mutating func recordChanges<Rule: Identifiable & Equatable>(
        from old: [Rule],
        to new: [Rule],
        at date: Date = .now
    ) where Rule.ID == UUID {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(new.map(\.id))
        for rule in new where previous[rule.id] != rule {
            modifiedAt[rule.id.uuidString] = date
            deletedAt[rule.id.uuidString] = nil
        }
        for id in previous.keys where !currentIDs.contains(id) {
            deletedAt[id.uuidString] = date
            modifiedAt[id.uuidString] = nil
        }
        pruneTombstones()
    }

    mutating func pruneTombstones() {
        guard deletedAt.count > Self.maximumTombstones else { return }
        let kept = deletedAt.sorted { $0.value > $1.value }.prefix(Self.maximumTombstones)
        deletedAt = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}

public enum UserRuleSyncMerge {
    /// Merges two devices' rules by ID.
    ///
    /// - The newer change of a rule wins; ties keep the local one.
    /// - A rule deleted on either side after its last change stays deleted.
    /// - Local order is kept; rules only the remote has follow in its order.
    /// - Of rules matching the same thing (`dedupKey`), the first is kept, so
    ///   a target changed on one device no longer leaves both versions.
    public static func merge<Rule: Identifiable>(
        local: [Rule],
        localMetadata: RuleSyncMetadata,
        remote: [Rule],
        remoteMetadata: RuleSyncMetadata,
        dedupKey: (Rule) -> String,
        isValid: (Rule) -> Bool,
        limit: Int
    ) -> (rules: [Rule], metadata: RuleSyncMetadata) where Rule.ID == UUID {
        var metadata = localMetadata
        for (id, date) in remoteMetadata.deletedAt where date > (metadata.deletedAt[id] ?? .distantPast) {
            metadata.deletedAt[id] = date
        }
        for (id, date) in remoteMetadata.modifiedAt where date > (metadata.modifiedAt[id] ?? .distantPast) {
            metadata.modifiedAt[id] = date
        }

        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localIDs = Set(local.map(\.id))
        func chosen(_ rule: Rule) -> Rule {
            let key = rule.id.uuidString
            guard localIDs.contains(rule.id), let theirs = remoteByID[rule.id] else { return rule }
            let mine = localMetadata.modifiedAt[key] ?? .distantPast
            let others = remoteMetadata.modifiedAt[key] ?? .distantPast
            return others > mine ? theirs : rule
        }

        var merged: [Rule] = []
        var seenIDs = Set<UUID>()
        var seenKeys = Set<String>()
        for rule in local + remote.filter({ !localIDs.contains($0.id) }) {
            let key = rule.id.uuidString
            guard seenIDs.insert(rule.id).inserted else { continue }
            let lastChange = metadata.modifiedAt[key] ?? .distantPast
            if let deleted = metadata.deletedAt[key], deleted >= lastChange {
                continue
            }
            let candidate = chosen(rule)
            guard isValid(candidate), seenKeys.insert(dedupKey(candidate)).inserted else { continue }
            merged.append(candidate)
            if merged.count >= limit { break }
        }

        let keptIDs = Set(merged.map { $0.id.uuidString })
        metadata.modifiedAt = metadata.modifiedAt.filter { keptIDs.contains($0.key) }
        metadata.pruneTombstones()
        return (merged, metadata)
    }
}

/// Reads and writes a `RuleSyncMetadata` sidecar file next to a rule store.
struct RuleSyncMetadataFile {
    let url: URL

    func load() -> RuleSyncMetadata {
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(RuleSyncMetadata.self, from: data)
        else { return .empty }
        return metadata
    }

    func save(_ metadata: RuleSyncMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
