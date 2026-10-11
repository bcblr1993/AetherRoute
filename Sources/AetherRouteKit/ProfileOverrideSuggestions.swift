import Foundation

/// Suggestions for the override editors (1.7.0), from the node names alone.
public enum ProfileOverrideSuggestions {
    public struct Region: Equatable, Sendable, Identifiable {
        public let code: String
        public let flag: String
        public let nodeCount: Int
        public var id: String { code }
    }

    /// Regions named clearly by at least `minimumNodes` nodes, the largest
    /// first; ties keep the order the subscription lists them in.
    public static func regions(in nodes: [String], minimumNodes: Int = 1) -> [Region] {
        var counts: [String: (flag: String, count: Int, first: Int)] = [:]
        for (index, node) in nodes.enumerated() {
            guard let region = NodeRegion.resolve(from: node) else { continue }
            let entry = counts[region.code] ?? (region.flag, 0, index)
            counts[region.code] = (entry.flag, entry.count + 1, entry.first)
        }
        return counts
            .filter { $0.value.count >= minimumNodes }
            .sorted {
                $0.value.count == $1.value.count
                    ? $0.value.first < $1.value.first
                    : $0.value.count > $1.value.count
            }
            .map { Region(code: $0.key, flag: $0.value.flag, nodeCount: $0.value.count) }
    }

    /// Words providers use for entries that are notices, not nodes
    /// (remaining traffic, expiry, website), that appear in this profile.
    public static func noticeKeywords(in nodes: [String]) -> [String] {
        let candidates = ["剩余流量", "到期", "过期", "套餐", "官网", "重置", "Traffic", "Expire", "Website"]
        return candidates.filter { keyword in
            nodes.contains { $0.localizedCaseInsensitiveContains(keyword) }
        }
    }
}
