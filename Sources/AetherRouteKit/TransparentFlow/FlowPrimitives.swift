import Foundation

public enum FlowIOError: Error, Sendable, Equatable {
    case cancelled
    case closed
    case invalidData(String)
    case transport(String)
}

public enum FlowLifecycle: Sendable, Equatable {
    case idle
    case running
    case finished
    case cancelled
    case failed(FlowIOError)
}

/// Called synchronously on the state-machine actor exactly once after a flow
/// enters a terminal state. Providers use this to remove completed sessions
/// from their registry without polling or retaining a finished bridge.
public typealias FlowTerminationHandler = @Sendable (FlowLifecycle) -> Void

public enum FlowOperationKind: String, Sendable, Hashable {
    case flowRead
    case flowWrite
    case flowFinishWriting
    case bridgeRead
    case bridgeWrite
    case bridgeFinishWriting
}

/// Every asynchronous operation carries both a session and sequence number.
/// Completions are accepted only when the token still matches the in-flight
/// slot; duplicated, reordered, or post-cancellation callbacks are ignored.
public struct FlowOperationToken: Sendable, Hashable {
    public let sessionID: UUID
    public let sequence: UInt64
    public let kind: FlowOperationKind

    public init(
        sessionID: UUID,
        sequence: UInt64,
        kind: FlowOperationKind
    ) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.kind = kind
    }
}

public enum FlowStateMachineConfigurationError: Error, Sendable, Equatable {
    case invalidMaximumReadBytes(Int)
    case invalidMaximumDatagrams(Int)
    case invalidMaximumBatchBytes(Int)
}

public enum FlowStateMachineStartError: Error, Sendable, Equatable {
    case alreadyStarted
}
