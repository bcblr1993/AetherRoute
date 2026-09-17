import Foundation

@main struct ReconnectRegression {
    enum TestFailure: Error { case prepare }
    @MainActor static func main() async throws {
        for cancelStage in ["stop", "prepare", "wait", "none"] {
            let coordinator = NetworkEngineReconnectCoordinator()
            var starts = 0
            var prepares = 0
            do {
                let result = try await coordinator.run(stop: {
                    if cancelStage == "stop" { coordinator.cancel() }
                    return true
                }, prepare: { restoring in
                    precondition(!restoring)
                    prepares += 1
                    if cancelStage == "prepare" { coordinator.cancel() }
                }, start: { starts += 1 }, waitUntilConnected: {
                    if cancelStage == "wait" { coordinator.cancel() }
                    return true
                })
                precondition(cancelStage == "none" && result == .switched)
            } catch is CancellationError {
                precondition(cancelStage != "none")
            }
            precondition(starts == (["wait", "none"].contains(cancelStage) ? 1 : 0))
            precondition(prepares <= 1, "Cancellation must never start rollback")
        }
        for cancelRollback in [false, true] {
            let coordinator = NetworkEngineReconnectCoordinator()
            var events: [String] = []
            do {
                let result = try await coordinator.run(stop: { events.append("stop"); return true }, prepare: { restoring in
                    events.append(restoring ? "restore" : "target")
                    if !restoring { throw TestFailure.prepare }
                    if cancelRollback { coordinator.cancel() }
                }, start: { events.append("start") }, waitUntilConnected: { events.append("ready"); return true })
                precondition(!cancelRollback && result == .restoredPrevious)
                precondition(events == ["stop", "target", "stop", "restore", "start", "ready"])
            } catch is CancellationError {
                precondition(cancelRollback && events == ["stop", "target", "stop", "restore"])
            }
        }
        let failed = NetworkEngineReconnectCoordinator()
        do {
            _ = try await failed.run(stop: { false }, prepare: { _ in preconditionFailure("Must drain first") },
                                     start: { preconditionFailure("Must drain first") }, waitUntilConnected: { true })
            preconditionFailure("Drain failure must fail")
        } catch NetworkEngineReconnectCoordinator.Failure.rollbackFailed {}
        let timedOut = NetworkEngineReconnectCoordinator()
        var attempts = 0
        do {
            _ = try await timedOut.run(stop: { true }, prepare: { _ in }, start: { attempts += 1 }, waitUntilConnected: { false })
            preconditionFailure("Both readiness timeouts must fail")
        } catch NetworkEngineReconnectCoordinator.Failure.rollbackFailed { precondition(attempts == 2) }
        print("Engine reconnect: stop-before-start, cancellation, rollback and timeout regressions passed")
    }
}
