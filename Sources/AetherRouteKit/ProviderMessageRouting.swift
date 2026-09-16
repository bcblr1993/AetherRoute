import Foundation

/// Which queue a decoded provider request belongs on.
///
/// Latency probes and selector traffic have very different shapes. A probe
/// runs for as long as its timeout allows and the core serializes it behind
/// an engine lock, so putting it on the same serial queue as `snapshot` and
/// `select` makes the UI's selector calls wait out an entire sweep. Splitting
/// them is what keeps a selection responsive while a measurement is running.
///
/// Both providers classify identically, so the rule lives here rather than
/// being duplicated in each of them.
public enum ProviderMessageClass: Sendable, Equatable {
    /// Bounded selector and telemetry traffic.
    case control
    /// Latency measurement, which may run for the length of its timeout.
    case probe

    public init(_ request: ProxySelectionProviderRequest) {
        switch request {
        case .latency, .activeLatency:
            self = .probe
        case .snapshot, .select, .telemetry, .diagnostics,
             .setRoutingMode, .resetNetwork:
            self = .control
        }
    }
}

/// Decodes one provider message, bounded before any work is scheduled.
///
/// Decoding stays off the caller's thread in the sense that matters: it is a
/// fixed-size parse with no core calls and no I/O, so it cannot block the
/// Network Extension's callback thread the way a probe would. A malformed
/// message is answered with `invalidRequest` rather than being dispatched.
public enum ProviderMessageRouting {
    public enum Classification: Sendable {
        case routed(
            request: ProxySelectionProviderRequest,
            kind: ProviderMessageClass
        )
        case undecodable(ProxySelectionProviderFailure)
    }

    public static func classify(_ messageData: Data) -> Classification {
        do {
            let request = try ProxySelectionProviderMessageCodec
                .decodeRequest(messageData)
            return .routed(request: request, kind: ProviderMessageClass(request))
        } catch {
            return .undecodable(.invalidRequest)
        }
    }

    /// The encoded reply for a request that could not be decoded, or `nil`
    /// when even that reply cannot be encoded.
    public static func encodedFailure(
        _ failure: ProxySelectionProviderFailure
    ) -> Data? {
        try? ProxySelectionProviderMessageCodec.encode(
            response: .failure(failure)
        )
    }
}
