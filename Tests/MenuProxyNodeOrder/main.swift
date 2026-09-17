import Foundation

@main
struct MenuProxyNodeOrderTests {
    static func main() {
        let names = (0..<40).map { "节点-\($0)" }
        let ordered = MenuProxyNodeOrder.sorted(
            members: names + [names[0]],
            delays: [names[0]: 100, names[1]: 0, names[2]: 28, names[3]: 28, names[39]: 8],
            unavailable: [names[4]]
        )
        precondition(ordered.count == 40, "All members must remain without duplicates")
        precondition(ordered == names, "Nodes must strictly retain their fixed source configuration order regardless of latency, availability, or selection")
        precondition(MenuProxyNodeOrder.sorted(members: [], delays: [:], unavailable: []).isEmpty)
        precondition(MenuProxyNodeOrder.sorted(members: ["a", "b"], delays: ["a": 1], unavailable: ["a"]) == ["a", "b"], "Source order is preserved regardless of delays or availability")
        print("Menu node ordering passed: fixed order preserved across duplicates, delays, and unavailable states.")
    }
}
