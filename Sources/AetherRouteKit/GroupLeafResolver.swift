import Foundation

/// Works out which node an automatic group (url-test, fallback,
/// load-balance) is actually using, from the proxy chains of live
/// connections. The core only reports a current member for `select`
/// groups, but every connection's chain ends at the node that carried it,
/// so "Auto" can be shown as the node behind it instead of a bare group name.
public enum GroupLeafResolver {
    /// Returns the node most live connections through `group` ended at, or
    /// nil when no live connection passes through it. Ties go to the node
    /// seen first, which keeps the answer stable between refreshes.
    public static func leaf(throughGroup group: String, chains: [String]) -> String? {
        leaves(forGroups: [group], chains: chains)[group]
    }

    public static func leaves(
        forGroups groups: Set<String>,
        chains: [String]
    ) -> [String: String] {
        guard !groups.isEmpty, !chains.isEmpty else { return [:] }
        var chainCounts: [String: Int] = [:]
        var uniqueChains: [String] = []
        uniqueChains.reserveCapacity(min(chains.count, 128))
        for chain in chains where !chain.isEmpty {
            if chainCounts[chain] == nil {
                uniqueChains.append(chain)
            }
            chainCounts[chain, default: 0] += 1
        }
        guard !uniqueChains.isEmpty else { return [:] }

        var countsByGroup: [String: [String: Int]] = [:]
        var firstSeenByGroup: [String: [String]] = [:]
        for chain in uniqueChains {
            let weight = chainCounts[chain, default: 1]
            let parsedHops = hops(in: chain)
            guard parsedHops.count >= 2, let leaf = parsedHops.last else { continue }
            for index in 0..<(parsedHops.count - 1) {
                let hop = parsedHops[index]
                guard groups.contains(hop) else { continue }
                if countsByGroup[hop]?[leaf] == nil {
                    firstSeenByGroup[hop, default: []].append(leaf)
                }
                countsByGroup[hop, default: [:]][leaf, default: 0] += weight
            }
        }

        var result: [String: String] = [:]
        result.reserveCapacity(firstSeenByGroup.count)
        for (group, firstSeen) in firstSeenByGroup {
            guard let counts = countsByGroup[group] else { continue }
            var bestLeaf: String?
            var bestCount = 0
            for candidate in firstSeen {
                let count = counts[candidate, default: 0]
                if count > bestCount {
                    bestCount = count
                    bestLeaf = candidate
                }
            }
            if let bestLeaf {
                result[group] = bestLeaf
            }
        }
        return result
    }

    /// Splits "Proxy → Auto → Tokyo" (or the ASCII "->" form) into hops.
    static func hops(in chain: String) -> [String] {
        chain
            .replacingOccurrences(of: "->", with: "→")
            .components(separatedBy: "→")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
