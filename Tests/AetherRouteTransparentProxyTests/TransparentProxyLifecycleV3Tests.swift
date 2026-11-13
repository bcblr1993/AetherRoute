import AetherRouteKit
import AetherRouteTransparentProxySupport
import Foundation
import XCTest

final class TransparentProxyLifecycleV3Tests: XCTestCase {
    private final class ConcurrencyTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private var maxObserved = 0
        private var resolvedCount = 0

        func enter() {
            lock.lock()
            current += 1
            if current > maxObserved {
                maxObserved = current
            }
            lock.unlock()
        }

        func leave() {
            lock.lock()
            current -= 1
            resolvedCount += 1
            lock.unlock()
        }

        var snapshot: (maxObserved: Int, resolvedCount: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (maxObserved, resolvedCount)
        }
    }

    func testUpstreamEndpointResolutionBoundsConcurrentWorkers() throws {
        let hostCount = 32
        let nodes = (0..<hostCount).map { index in
            "  - {name: N\(index), type: vless, server: node-\(index).example.com, port: 443}"
        }
        let yaml = "proxies:\n" + nodes.joined(separator: "\n")

        let tracker = ConcurrencyTracker()
        let exclusions = try TransparentProxyUpstreamEndpointResolver.resolve(
            profileYAML: yaml,
            maxResolutionDurationSeconds: 5.0,
            hostResolver: { _, index in
                tracker.enter()
                defer { tracker.leave() }
                Thread.sleep(forTimeInterval: 0.03)
                return [("203.0.113.\((index % 200) + 1)", .ipv4)]
            }
        )

        let stats = tracker.snapshot
        XCTAssertEqual(stats.resolvedCount, hostCount)
        XCTAssertEqual(exclusions.count, hostCount)
        XCTAssertLessThanOrEqual(
            stats.maxObserved,
            TransparentProxyUpstreamEndpointResolver.maxConcurrentResolutions
        )
        XCTAssertEqual(TransparentProxyUpstreamEndpointResolver.maxConcurrentResolutions, 8)
    }

    func testBoundedWorkerPoolStillRespectsMaxResolutionDuration() throws {
        let nodes = (0..<24).map { index in
            "  - {name: N\(index), type: trojan, server: slow-\(index).example.com, port: 443}"
        }
        let yaml = "proxies:\n" + nodes.joined(separator: "\n")

        let start = CFAbsoluteTimeGetCurrent()
        XCTAssertThrowsError(
            try TransparentProxyUpstreamEndpointResolver.resolve(
                profileYAML: yaml,
                maxResolutionDurationSeconds: 0.12,
                hostResolver: { _, index in
                    Thread.sleep(forTimeInterval: 0.5)
                    throw TransparentProxyUpstreamEndpointResolutionError.unresolvedEndpoint(index: index)
                }
            )
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 0.7)
    }
}
