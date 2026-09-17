import Foundation

// 测试环境下提供轻量 AppLocalization 支持
enum AppLocalization {
    static func string(_ key: String) -> String { key }
}

@main
struct ProxyPageNodeOrderTests {
    static func main() {
        testDefaultSortPreservesSourceOrderRegardlessOfLatency()
        testLatencySort()
        testNameSort()
        testEdgeCases()
        testSortCases()
        print("ProxyPageNodeOrder tests passed: source configuration order strictly preserved in default mode; latency and name sorting verified.")
    }

    private static func testDefaultSortPreservesSourceOrderRegardlessOfLatency() {
        let originalNodes = [
            "US-West-01",
            "JP-Tokyo-02",
            "HK-Direct-01",
            "SG-Central-01",
            "UK-London-03",
            "DE-Frankfurt-01"
        ]

        // 场景 1: 全部未测速
        let initial = ProxyPageNodeOrder.sorted(
            members: originalNodes,
            by: .default,
            latencyRank: { _ in ProxyPageNodeOrder.rank(milliseconds: nil) }
        )
        precondition(initial == originalNodes, "Initial unmeasured list must preserve original source order")

        // 场景 2: 模拟部分测速中、部分先返回极快延迟（如 HK 12ms）、部分超时
        let step1Ranks: [String: Int] = [
            "HK-Direct-01": ProxyPageNodeOrder.rank(milliseconds: 12),
            "US-West-01": ProxyPageNodeOrder.rank(milliseconds: 240),
            "JP-Tokyo-02": ProxyPageNodeOrder.rank(milliseconds: nil, isTesting: true),
            "SG-Central-01": ProxyPageNodeOrder.rank(milliseconds: nil, isTimedOut: true)
        ]
        let step1Result = ProxyPageNodeOrder.sorted(
            members: originalNodes,
            by: .default,
            latencyRank: { step1Ranks[$0] ?? Int.max }
        )
        precondition(step1Result == originalNodes, "Default mode must NOT reorder when fast node (12ms) arrives or during testing")

        // 场景 3: 测速全部完成，延迟完全乱序返回
        let finalRanks: [String: Int] = [
            "US-West-01": ProxyPageNodeOrder.rank(milliseconds: 180),
            "JP-Tokyo-02": ProxyPageNodeOrder.rank(milliseconds: 45),
            "HK-Direct-01": ProxyPageNodeOrder.rank(milliseconds: 15),
            "SG-Central-01": ProxyPageNodeOrder.rank(milliseconds: 80),
            "UK-London-03": ProxyPageNodeOrder.rank(milliseconds: 220),
            "DE-Frankfurt-01": ProxyPageNodeOrder.rank(milliseconds: nil, isTimedOut: true)
        ]
        let finalResult = ProxyPageNodeOrder.sorted(
            members: originalNodes,
            by: .default,
            latencyRank: { finalRanks[$0] ?? Int.max }
        )
        precondition(finalResult == originalNodes, "Default mode must strictly keep configuration order even when all latencies are measured")
    }

    private static func testLatencySort() {
        let nodes = ["US-Slow", "HK-Fast", "JP-Medium", "Dead-Node", "Testing-Node", "Untested-Node"]
        let ranks: [String: Int] = [
            "HK-Fast": ProxyPageNodeOrder.rank(milliseconds: 20),
            "JP-Medium": ProxyPageNodeOrder.rank(milliseconds: 60),
            "US-Slow": ProxyPageNodeOrder.rank(milliseconds: 200),
            "Dead-Node": ProxyPageNodeOrder.rank(milliseconds: nil, isTimedOut: true),
            "Testing-Node": ProxyPageNodeOrder.rank(milliseconds: nil, isTesting: true),
            "Untested-Node": ProxyPageNodeOrder.rank(milliseconds: nil)
        ]

        let sorted = ProxyPageNodeOrder.sorted(
            members: nodes,
            by: .latency,
            latencyRank: { ranks[$0] ?? Int.max }
        )

        // 期望顺序: HK-Fast (20) -> JP-Medium (60) -> US-Slow (200) -> Dead-Node (max-2) -> Testing-Node (max-1) -> Untested-Node (max)
        precondition(sorted == ["HK-Fast", "JP-Medium", "US-Slow", "Dead-Node", "Testing-Node", "Untested-Node"], "Latency sort failed: got \(sorted)")
    }

    private static func testNameSort() {
        let nodes = ["Node 10", "Node 2", "Node 1", "Alpha", "Beta"]
        let sorted = ProxyPageNodeOrder.sorted(members: nodes, by: .name)
        // localizedStandardCompare: Alpha, Beta, Node 1, Node 2, Node 10
        precondition(sorted == ["Alpha", "Beta", "Node 1", "Node 2", "Node 10"], "Name sort failed: got \(sorted)")
    }

    private static func testEdgeCases() {
        precondition(ProxyPageNodeOrder.sorted(members: [], by: .default).isEmpty)
        precondition(ProxyPageNodeOrder.sorted(members: [], by: .latency).isEmpty)
        precondition(ProxyPageNodeOrder.sorted(members: [], by: .name).isEmpty)

        let single = ["Single-Node"]
        precondition(ProxyPageNodeOrder.sorted(members: single, by: .default) == single)
        precondition(ProxyPageNodeOrder.sorted(members: single, by: .latency) == single)
        precondition(ProxyPageNodeOrder.sorted(members: single, by: .name) == single)
    }

    private static func testSortCases() {
        let cases = ProxyNodeSort.allCases
        precondition(cases.count == 3)
        precondition(cases.contains(.default))
        precondition(cases.contains(.latency))
        precondition(cases.contains(.name))
        for item in cases {
            precondition(!item.localizedTitle.isEmpty)
        }
    }
}
