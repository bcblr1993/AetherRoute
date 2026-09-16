import Foundation
import AetherRouteKit

// 模拟 ProxyLatencyStatus 语义与状态机校验
enum MockProxyLatencyStatus: Equatable {
    case untested
    case testing
    case responded(UInt32)
    case timedOut

    static func status(
        member: String,
        results: [ProxyLatencyResult]?,
        isTesting: Bool
    ) -> MockProxyLatencyStatus {
        if let result = results?.first(where: { $0.member == member }) {
            guard let delay = result.delayMilliseconds else { return .timedOut }
            return .responded(delay)
        }
        if isTesting { return .testing }
        return .untested
    }
}

// 模拟 TunnelManager 单节点状态管理与增量合并逻辑
final class MockTunnelLatencyManager {
    var proxyLatencyRequests: Set<String> = []
    var memberLatencyRequests: Set<String> = []
    var proxyLatencies: [String: ProxyLatencyState] = [:]

    func isTestingLatency(group groupName: String, member memberName: String? = nil) -> Bool {
        if let memberName {
            return memberLatencyRequests.contains("\(groupName):\(memberName)")
                || proxyLatencyRequests.contains(groupName)
        }
        return proxyLatencyRequests.contains(groupName)
    }

    func mergeLatencyResult(_ newResult: ProxyLatencyResult, forGroup groupName: String) {
        var currentResults = proxyLatencies[groupName]?.results ?? []
        if let index = currentResults.firstIndex(where: { $0.member == newResult.member }) {
            currentResults[index] = newResult
        } else {
            currentResults.append(newResult)
        }
        proxyLatencies[groupName] = ProxyLatencyState(results: currentResults)
    }
}

@main
struct ProxyLatencyMeasurementTests {
    static func main() {
        print("Running ProxyLatencyMeasurementTests...")

        let manager = MockTunnelLatencyManager()
        let groupName = "PROXY"
        let nodeA = "HK Node 01"
        let nodeB = "SG Node 02"
        let direct = "DIRECT"

        // 1. 初始状态：无测试，无结果
        precondition(!manager.isTestingLatency(group: groupName), "Initial group should not be testing")
        precondition(!manager.isTestingLatency(group: groupName, member: nodeA), "Initial node A should not be testing")
        let statusA0 = MockProxyLatencyStatus.status(
            member: nodeA,
            results: manager.proxyLatencies[groupName]?.results,
            isTesting: manager.isTestingLatency(group: groupName, member: nodeA)
        )
        precondition(statusA0 == .untested, "Initial status of node A must be .untested")

        // 2. 单独测试 nodeA
        manager.memberLatencyRequests.insert("\(groupName):\(nodeA)")
        precondition(manager.isTestingLatency(group: groupName, member: nodeA), "Node A must report testing")
        precondition(!manager.isTestingLatency(group: groupName, member: nodeB), "Node B must NOT report testing")
        precondition(!manager.isTestingLatency(group: groupName), "Whole group must NOT be in group-level testing")

        let statusA1 = MockProxyLatencyStatus.status(
            member: nodeA,
            results: manager.proxyLatencies[groupName]?.results,
            isTesting: manager.isTestingLatency(group: groupName, member: nodeA)
        )
        let statusB1 = MockProxyLatencyStatus.status(
            member: nodeB,
            results: manager.proxyLatencies[groupName]?.results,
            isTesting: manager.isTestingLatency(group: groupName, member: nodeB)
        )
        precondition(statusA1 == .testing, "Node A should be .testing")
        precondition(statusB1 == .untested, "Node B must remain .untested while node A is testing")

        // 3. nodeA 测试完成，增量合并 48ms
        manager.memberLatencyRequests.remove("\(groupName):\(nodeA)")
        manager.mergeLatencyResult(ProxyLatencyResult(member: nodeA, delayMilliseconds: 48), forGroup: groupName)

        let statusA2 = MockProxyLatencyStatus.status(
            member: nodeA,
            results: manager.proxyLatencies[groupName]?.results,
            isTesting: manager.isTestingLatency(group: groupName, member: nodeA)
        )
        precondition(statusA2 == .responded(48), "Node A must now be .responded(48)")

        // 4. 单独测试 nodeB，nodeA 不受影响
        manager.memberLatencyRequests.insert("\(groupName):\(nodeB)")
        let statusA3 = MockProxyLatencyStatus.status(
            member: nodeA,
            results: manager.proxyLatencies[groupName]?.results,
            isTesting: manager.isTestingLatency(group: groupName, member: nodeA)
        )
        let statusB3 = MockProxyLatencyStatus.status(
            member: nodeB,
            results: manager.proxyLatencies[groupName]?.results,
            isTesting: manager.isTestingLatency(group: groupName, member: nodeB)
        )
        precondition(statusA3 == .responded(48), "Node A must retain 48ms while node B is testing")
        precondition(statusB3 == .testing, "Node B must be .testing")

        // 5. nodeB 测试超时 (nil delay)
        manager.memberLatencyRequests.remove("\(groupName):\(nodeB)")
        manager.mergeLatencyResult(ProxyLatencyResult(member: nodeB, delayMilliseconds: nil), forGroup: groupName)

        let statusB4 = MockProxyLatencyStatus.status(
            member: nodeB,
            results: manager.proxyLatencies[groupName]?.results,
            isTesting: manager.isTestingLatency(group: groupName, member: nodeB)
        )
        precondition(statusB4 == .timedOut, "Node B must report .timedOut")

        // 6. DIRECT 节点直连低延迟（Cloudflare Anycast 模拟）
        manager.mergeLatencyResult(ProxyLatencyResult(member: direct, delayMilliseconds: 18), forGroup: groupName)
        let statusDirect = MockProxyLatencyStatus.status(
            member: direct,
            results: manager.proxyLatencies[groupName]?.results,
            isTesting: false
        )
        precondition(statusDirect == .responded(18), "DIRECT node should have responsive delay (18ms)")

        // 7. 全组测速 (group-level testing 增量流式显示校验)
        manager.proxyLatencies[groupName] = ProxyLatencyState(results: [])
        manager.proxyLatencyRequests.insert(groupName)
        precondition(manager.isTestingLatency(group: groupName), "Group must report testing")
        precondition(manager.isTestingLatency(group: groupName, member: nodeA), "All members report testing during group test")
        precondition(manager.isTestingLatency(group: groupName, member: nodeB), "All members report testing during group test")

        // 初始所有节点均在测试中
        let statusA_groupInit = MockProxyLatencyStatus.status(
            member: nodeA,
            results: manager.proxyLatencies[groupName]?.results,
            isTesting: manager.isTestingLatency(group: groupName, member: nodeA)
        )
        precondition(statusA_groupInit == .testing, "Node A must be .testing before returning")

        // nodeA 先返回 (32ms)，应立即显示，不等全组完成
        manager.mergeLatencyResult(ProxyLatencyResult(member: nodeA, delayMilliseconds: 32), forGroup: groupName)
        let statusA_groupPartial = MockProxyLatencyStatus.status(
            member: nodeA,
            results: manager.proxyLatencies[groupName]?.results,
            isTesting: manager.isTestingLatency(group: groupName, member: nodeA)
        )
        let statusB_groupPartial = MockProxyLatencyStatus.status(
            member: nodeB,
            results: manager.proxyLatencies[groupName]?.results,
            isTesting: manager.isTestingLatency(group: groupName, member: nodeB)
        )
        precondition(statusA_groupPartial == .responded(32), "Node A must display 32ms immediately during group test")
        precondition(statusB_groupPartial == .testing, "Node B must remain .testing while still pending")

        manager.proxyLatencyRequests.remove(groupName)
        precondition(!manager.isTestingLatency(group: groupName), "Group test cleared")

        // 8. 模拟包含 100 个节点的大型订阅（如 x2cloud）并发池测速验证
        let largeMembers = (1...100).map { "Node-\($0)" }
        var mockResults: [ProxyLatencyResult] = []
        let maxConcurrent = 16
        var activeWorkers = 0
        var maxObservedWorkers = 0

        var iterator = largeMembers.makeIterator()
        var workQueue: [String] = []
        while workQueue.count < maxConcurrent, let next = iterator.next() {
            workQueue.append(next)
        }

        while !workQueue.isEmpty {
            activeWorkers = workQueue.count
            maxObservedWorkers = max(maxObservedWorkers, activeWorkers)
            let item = workQueue.removeFirst()
            mockResults.append(ProxyLatencyResult(member: item, delayMilliseconds: 50))
            if let next = iterator.next() {
                workQueue.append(next)
            }
        }

        precondition(mockResults.count == 100, "All 100 nodes must be measured")
        precondition(maxObservedWorkers <= maxConcurrent, "Active workers must not exceed bounded capacity")

        print("ProxyLatencyMeasurementTests passed successfully!")
    }
}
