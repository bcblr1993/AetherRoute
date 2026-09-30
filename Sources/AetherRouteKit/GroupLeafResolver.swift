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
        var counts: [String: Int] = [:]
        var firstSeen: [String] = []
        for chain in chains {
            let hops = hops(in: chain)
            guard let index = hops.firstIndex(of: group),
                  index < hops.count - 1,
                  let leaf = hops.last
            else { continue }
            if counts[leaf] == nil { firstSeen.append(leaf) }
            counts[leaf, default: 0] += 1
        }
        return firstSeen.max { lhs, rhs in
            let l = counts[lhs, default: 0], r = counts[rhs, default: 0]
            if l != r { return l < r }
            // Equal counts: prefer the earlier one.
            return firstSeen.firstIndex(of: lhs)! > firstSeen.firstIndex(of: rhs)!
        }
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
