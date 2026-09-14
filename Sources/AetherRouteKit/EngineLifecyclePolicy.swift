import Foundation

/// Which engine, if any, the process currently owns.
///
/// The embedded protocol core exposes a handle-free C ABI: `clash_shutdown()`,
/// `clash_packet_flow_ready()` and `clash_uninstall_packet_flow()` all take no
/// arguments and act on one process-wide instance, and the cancellation tokens
/// live in a single global registry that a shutdown drains wholesale. A
/// `NEPacketTunnelProvider` subclass, by contrast, is instantiated afresh for
/// every `startTunnel`, so lifecycle state held per provider cannot enforce
/// that invariant — a replacement provider begins with a clean slate and will
/// happily launch a second engine while the previous one is still winding down,
/// or send a shutdown that cancels whichever engine replaced its own.
///
/// Keying every decision on a process-wide generation closes both holes. The
/// policy has no NetworkExtension or engine dependency, so the cross-instance
/// transitions — which on a live host only occur after a shutdown overruns its
/// budget — are reachable from unit tests.
public enum EngineLifecyclePhase: Sendable, Equatable {
    case idle
    case running(generation: UInt64)
    case stopping(generation: UInt64)

    public var generation: UInt64? {
        switch self {
        case .idle: nil
        case let .running(generation), let .stopping(generation): generation
        }
    }
}

public enum EngineStartAdmission: Sendable, Equatable {
    /// No engine is live. The caller owns the supplied generation.
    case admit(generation: UInt64)
    /// A previous engine is still winding down. It must be joined before a
    /// replacement may start, because the two would share one cancellation
    /// registry and one packet-flow bridge.
    case awaitStop(generation: UInt64)
    /// An engine is already running and nobody asked it to stop.
    case reject
}

public enum EngineStopAdmission: Sendable, Equatable {
    case begin(generation: UInt64)
    /// A shutdown is already in flight. Signalling again would drain the global
    /// cancellation registry a second time for no benefit.
    case alreadyStopping(generation: UInt64)
    /// The request names a generation that is no longer live — a stale provider
    /// instance, or one that never owned an engine. Honouring it would cancel
    /// whichever engine took its place.
    case ignore
}

public enum EngineLifecyclePolicy {
    public static func startAdmission(
        for phase: EngineLifecyclePhase,
        currentGeneration: UInt64
    ) -> EngineStartAdmission {
        switch phase {
        case .idle:
            .admit(generation: nextGeneration(currentGeneration))
        case .running:
            .reject
        case let .stopping(generation):
            .awaitStop(generation: generation)
        }
    }

    /// `requestedBy` is the generation the caller believes it owns. A caller
    /// that never acquired one passes `nil` and is always ignored: a bridge
    /// which failed before admission has no engine to stop, and acting on its
    /// request would tear down a live tunnel belonging to someone else.
    public static func stopAdmission(
        for phase: EngineLifecyclePhase,
        requestedBy requested: UInt64?
    ) -> EngineStopAdmission {
        guard let requested else { return .ignore }
        switch phase {
        case .idle:
            return .ignore
        case let .running(live):
            return requested == live ? .begin(generation: live) : .ignore
        case let .stopping(live):
            return requested == live
                ? .alreadyStopping(generation: live)
                : .ignore
        }
    }

    /// Zero is reserved for "no engine", so a wrapping counter skips it rather
    /// than handing out a generation that compares equal to the absent case.
    public static func nextGeneration(_ current: UInt64) -> UInt64 {
        let next = current &+ 1
        return next == 0 ? 1 : next
    }
}
