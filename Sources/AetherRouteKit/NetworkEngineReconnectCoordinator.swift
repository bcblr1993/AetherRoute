import Foundation

/// Serializes a break-before-make engine reconnect. Every suspension is a
/// cancellation boundary, including rollback. Adapters that suspend internally
/// must call checkActive() before changing state after each suspension.
@MainActor
public final class NetworkEngineReconnectCoordinator {
    public enum Outcome: Equatable { case switched, restoredPrevious }
    public enum Failure: Error { case stopTimedOut, connectionTimedOut, rollbackFailed }
    private var generation: UUID?
    private var isRunning = false

    public init() {}

    public func cancel() { generation = nil }

    public func checkActive() throws {
        guard generation != nil, !Task.isCancelled else { throw CancellationError() }
    }

    public func run(
        stop: () async -> Bool,
        prepare: (_ restoringPrevious: Bool) async throws -> Void,
        start: () throws -> Void,
        waitUntilConnected: () async -> Bool
    ) async throws -> Outcome {
        guard !isRunning else { throw CancellationError() }
        let id = UUID()
        generation = id
        isRunning = true
        defer {
            if generation == id { generation = nil }
            isRunning = false
        }
        func checkpoint() throws {
            guard generation == id else { throw CancellationError() }
            try checkActive()
        }
        func connect(restoring: Bool) async throws {
            try checkpoint()
            let stopped = await stop()
            try checkpoint()
            guard stopped else { throw Failure.stopTimedOut }
            try await prepare(restoring)
            try checkpoint()
            try start()
            let connected = await waitUntilConnected()
            try checkpoint()
            guard connected else { throw Failure.connectionTimedOut }
        }
        do {
            try await connect(restoring: false)
            return .switched
        } catch {
            try checkpoint() // Cancellation must never initiate rollback.
            if error is CancellationError { throw error }
            do {
                try await connect(restoring: true)
                return .restoredPrevious
            } catch {
                try checkpoint()
                if error is CancellationError { throw error }
                throw Failure.rollbackFailed
            }
        }
    }
}
