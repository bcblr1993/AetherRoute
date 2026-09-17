import Foundation

/// Retains fixed source order from the configuration so nodes never reorder under the pointer
/// based on latency, selection, or availability.
enum MenuProxyNodeOrder {
    static func sorted(
        members: [String],
        delays: [String: UInt32] = [:],
        unavailable: Set<String> = []
    ) -> [String] {
        var seen = Set<String>()
        return members.filter { seen.insert($0).inserted }
    }
}
