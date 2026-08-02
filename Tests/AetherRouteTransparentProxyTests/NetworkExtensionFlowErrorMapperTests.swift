import AetherRouteKit
import Foundation
import NetworkExtension
import XCTest
@testable import AetherRouteTransparentProxySupport

final class NetworkExtensionFlowErrorMapperTests:
    XCTestCase,
    @unchecked Sendable
{
    func testKnownTerminalErrorsUseStableFlowCategories() {
        XCTAssertEqual(
            NetworkExtensionFlowErrorMapper.map(
                NEAppProxyFlowError(.aborted)
            ),
            .cancelled
        )
        XCTAssertEqual(
            NetworkExtensionFlowErrorMapper.map(
                NEAppProxyFlowError(.peerReset)
            ),
            .closed
        )
        XCTAssertEqual(
            NetworkExtensionFlowErrorMapper.map(
                NEAppProxyFlowError(.timedOut)
            ),
            .closed
        )
    }

    func testForeignErrorDescriptionDoesNotCrossPrivacyBoundary() {
        let secret = "credential-do-not-copy"
        let error = NSError(
            domain: "example",
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: secret]
        )
        let mapped = NetworkExtensionFlowErrorMapper.map(error)
        XCTAssertEqual(
            mapped,
            .transport("NetworkExtension operation failed")
        )
        XCTAssertFalse(String(describing: mapped).contains(secret))
    }

    func testWildcardUDPSourcesRequireSyntheticIdentityLease() throws {
        let wildcardV4 = FlowEndpoint(
            host: .ipv4([0, 0, 0, 0]),
            port: 49_152,
            transport: .udp
        )
        let wildcardV6 = FlowEndpoint(
            host: .ipv6(Array(repeating: 0, count: 16), scopeID: 0),
            port: 49_153,
            transport: .udp
        )
        let concrete = FlowEndpoint(
            host: .ipv4([127, 0, 0, 1]),
            port: 49_154,
            transport: .udp
        )

        XCTAssertNil(
            try NetworkExtensionFlowLifecycle.normalizeUDPLocalSource(wildcardV4)
        )
        XCTAssertNil(
            try NetworkExtensionFlowLifecycle.normalizeUDPLocalSource(wildcardV6)
        )
        XCTAssertEqual(
            try NetworkExtensionFlowLifecycle.normalizeUDPLocalSource(concrete),
            concrete
        )
    }

    func testNativeDrainWaitsForCloseAndEveryAcceptedCallback() {
        let gate = NativeFlowDrainGate()
        let completed = DrainCompletionCounter()

        XCTAssertTrue(gate.beginOperation())
        XCTAssertTrue(gate.beginOperation())
        let request = gate.requestCancel { completed.increment() }
        XCTAssertTrue(request.shouldIssueClose)
        XCTAssertTrue(request.completions.isEmpty)
        XCTAssertFalse(gate.beginOperation())

        XCTAssertTrue(gate.closeExecuted().isEmpty)
        XCTAssertTrue(gate.operationReturned().isEmpty)
        XCTAssertEqual(completed.value, 0)
        gate.operationReturned().forEach { $0() }
        XCTAssertEqual(completed.value, 1)

        // Duplicate native callbacks cannot underflow the count or replay a
        // previously delivered drain completion.
        XCTAssertTrue(gate.operationReturned().isEmpty)
        let repeated = gate.requestCancel { completed.increment() }
        XCTAssertFalse(repeated.shouldIssueClose)
        repeated.completions.forEach { $0() }
        XCTAssertEqual(completed.value, 2)
    }

    func testNativeUDPReadGuardRejectsCountBeforeInspectingPayloads() throws {
        let guardrail = try NativeUDPReadBatchGuard(
            maximumDatagrams: 2,
            maximumBytes: 32
        )
        var inspectedPayloads = 0

        XCTAssertFalse(
            guardrail.accepts([1, 1, 1]) { bytes in
                inspectedPayloads += 1
                return bytes
            }
        )
        XCTAssertEqual(inspectedPayloads, 0)
    }

    func testNativeUDPReadGuardRejectsSingleAndAggregateOversize() throws {
        let guardrail = try NativeUDPReadBatchGuard(
            maximumDatagrams: 4,
            maximumBytes: 100_000
        )

        XCTAssertFalse(
            guardrail.accepts(
                [UDPBatchPolicy.maximumPayloadBytes + 1],
                payloadByteCount: { $0 }
            )
        )
        XCTAssertFalse(
            guardrail.accepts(
                [60_000, 40_001],
                payloadByteCount: { $0 }
            )
        )
        XCTAssertTrue(
            guardrail.accepts(
                [60_000, 40_000],
                payloadByteCount: { $0 }
            )
        )
    }
}

private final class DrainCompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
