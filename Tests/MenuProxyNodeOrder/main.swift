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
        precondition(ordered.count == 40, "All members beyond the old 16-row limit must remain, without duplicates")
        precondition(Array(ordered.prefix(5)) == [names[1], names[39], names[2], names[3], names[0]], "Ascending latency, including zero, and stable ties")
        precondition(ordered.last == names[4], "Unavailable nodes follow untested nodes")
        precondition(ordered[5] == names[5], "Untested nodes retain source order")
        precondition(MenuProxyNodeOrder.sorted(members: [], delays: [:], unavailable: []).isEmpty)
        precondition(MenuProxyNodeOrder.sorted(members: ["a", "b"], delays: ["a": 1], unavailable: ["a"]) == ["b", "a"], "Unsupported nodes remain last despite old measurements")
        print("Menu node ordering passed: 40 members, duplicates, ties, zero latency, empty list, untested and unavailable.")
    }
}
