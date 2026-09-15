import Foundation

/// Stable ties and a fixed snapshot keep rows from moving under the pointer.
enum MenuProxyNodeOrder {
    static func sorted(
        members: [String],
        delays: [String: UInt32],
        unavailable: Set<String>
    ) -> [String] {
        var seen = Set<String>()
        return members.filter { seen.insert($0).inserted }.enumerated().sorted { lhs, rhs in
            func rank(_ member: String) -> UInt64 {
                if unavailable.contains(member) { return UInt64.max }
                return delays[member].map(UInt64.init) ?? (UInt64.max - 1)
            }
            let left = rank(lhs.element)
            let right = rank(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }
}
