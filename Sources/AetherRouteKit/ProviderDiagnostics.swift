import Foundation

/// Fixed, aggregate provider counters. No field can contain profile, endpoint,
/// rule, credential, or free-form error data.
public struct ProviderDiagnosticSnapshot: Codable, Equatable, Sendable {
    public static let empty = ProviderDiagnosticSnapshot()

    public let startupFailureCount: UInt64
    public let networkSettingsFailureCount: UInt64
    public let invalidControlRequestCount: UInt64
    public let unavailableControlRequestCount: UInt64
    public let rejectedControlRequestCount: UInt64
    public let oversizedControlResponseCount: UInt64
    public let internalControlFailureCount: UInt64
    public let flowAdmissionFailureCount: UInt64

    public init(
        startupFailureCount: UInt64 = 0,
        networkSettingsFailureCount: UInt64 = 0,
        invalidControlRequestCount: UInt64 = 0,
        unavailableControlRequestCount: UInt64 = 0,
        rejectedControlRequestCount: UInt64 = 0,
        oversizedControlResponseCount: UInt64 = 0,
        internalControlFailureCount: UInt64 = 0,
        flowAdmissionFailureCount: UInt64 = 0
    ) {
        self.startupFailureCount = startupFailureCount
        self.networkSettingsFailureCount = networkSettingsFailureCount
        self.invalidControlRequestCount = invalidControlRequestCount
        self.unavailableControlRequestCount = unavailableControlRequestCount
        self.rejectedControlRequestCount = rejectedControlRequestCount
        self.oversizedControlResponseCount = oversizedControlResponseCount
        self.internalControlFailureCount = internalControlFailureCount
        self.flowAdmissionFailureCount = flowAdmissionFailureCount
    }
}

public enum ProviderDiagnosticCounter: Int, CaseIterable, Sendable {
    case startupFailure
    case networkSettingsFailure
    case invalidControlRequest
    case unavailableControlRequest
    case rejectedControlRequest
    case oversizedControlResponse
    case internalControlFailure
    case flowAdmissionFailure
}

/// Thread-safe and saturating so an adversarial request stream cannot wrap a
/// counter or force unbounded storage.
public final class ProviderDiagnosticAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = Array(
        repeating: UInt64(0),
        count: ProviderDiagnosticCounter.allCases.count
    )

    public init() {}

    public func record(_ counter: ProviderDiagnosticCounter) {
        lock.withLock {
            let index = counter.rawValue
            if counts[index] < UInt64.max {
                counts[index] += 1
            }
        }
    }

    public func record(_ failure: ProxySelectionProviderFailure) {
        switch failure {
        case .invalidRequest: record(.invalidControlRequest)
        case .unavailable: record(.unavailableControlRequest)
        case .rejected: record(.rejectedControlRequest)
        case .responseTooLarge: record(.oversizedControlResponse)
        case .internalFailure: record(.internalControlFailure)
        }
    }

    public func snapshot() -> ProviderDiagnosticSnapshot {
        lock.withLock {
            ProviderDiagnosticSnapshot(
                startupFailureCount: counts[
                    ProviderDiagnosticCounter.startupFailure.rawValue
                ],
                networkSettingsFailureCount: counts[
                    ProviderDiagnosticCounter.networkSettingsFailure.rawValue
                ],
                invalidControlRequestCount: counts[
                    ProviderDiagnosticCounter.invalidControlRequest.rawValue
                ],
                unavailableControlRequestCount: counts[
                    ProviderDiagnosticCounter.unavailableControlRequest.rawValue
                ],
                rejectedControlRequestCount: counts[
                    ProviderDiagnosticCounter.rejectedControlRequest.rawValue
                ],
                oversizedControlResponseCount: counts[
                    ProviderDiagnosticCounter.oversizedControlResponse.rawValue
                ],
                internalControlFailureCount: counts[
                    ProviderDiagnosticCounter.internalControlFailure.rawValue
                ],
                flowAdmissionFailureCount: counts[
                    ProviderDiagnosticCounter.flowAdmissionFailure.rawValue
                ]
            )
        }
    }
}
