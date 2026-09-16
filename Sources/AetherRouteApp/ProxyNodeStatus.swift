import AetherRouteKit
import SwiftUI

/// How a member responded the last time it was measured.
///
/// The provider only ever reports members it actually tested, so "never
/// measured" and "measuring right now" are facts the app holds, not facts the
/// extension sends. Keeping all four in one type is what lets the list stop
/// showing an unmeasured node and a dead node the same way.
enum ProxyLatencyStatus: Equatable {
    case untested
    case testing
    case responded(UInt32)
    case timedOut

    /// The handoff keeps the existing 120 / 260 ms thresholds.
    enum Band {
        case fast
        case moderate
        case slow
    }

    var band: Band? {
        guard case let .responded(milliseconds) = self else { return nil }
        if milliseconds <= 120 { return .fast }
        if milliseconds <= 260 { return .moderate }
        return .slow
    }

    /// Colour is never the only cue: every case also carries text, and the
    /// measured cases differ in symbol from the unmeasured ones.
    var tint: Color {
        switch band {
        case .fast: .green
        case .moderate: .orange
        case .slow: .red
        case nil: self == .timedOut ? .red : .secondary
        }
    }

    /// A filled dot means measured. Timed out is deliberately hollow so it does
    /// not read as just another slow result at a glance.
    var symbol: String {
        switch self {
        case .responded: "circle.fill"
        case .timedOut: "circle"
        case .untested, .testing: "circle.fill"
        }
    }

    var isMeasured: Bool {
        if case .responded = self { return true }
        return false
    }
}

/// How much a measured number is worth.
///
/// Reachability is a TCP handshake to the node's advertised endpoint: it
/// proves a socket opened, not that the node's protocol, credentials, or
/// egress still work. A node that is reachable but unusable would otherwise
/// show the same green number as a working one, so the row states which of the
/// two it measured instead of letting the colour imply the stronger claim.
enum ProxyLatencyConfidence: Equatable {
    case reachability
    case verified

    /// Drawn next to the number, never instead of it.
    var symbol: String {
        switch self {
        case .reachability: "bolt.horizontal"
        case .verified: "checkmark.seal"
        }
    }

    var localizedHint: String {
        switch self {
        case .reachability:
            AppLocalization.string("TCP reachability only; not verified through the node")
        case .verified:
            AppLocalization.string("Verified through the node's protocol handler")
        }
    }
}

extension ProxyLatencyStatus {
    /// Presentation wrapper over `ProxyLatencyReading`, which owns the actual
    /// state machine. Keeping the decision in one place is what lets the test
    /// suite exercise the product's logic instead of a copy of it.
    static func status(
        member: String,
        results: [ProxyLatencyResult]?,
        isTesting: Bool
    ) -> ProxyLatencyStatus {
        switch ProxyLatencyReading.resolve(
            member: member,
            results: results,
            isTesting: isTesting
        ) {
        case .untested: .untested
        case .testing: .testing
        case let .responded(delay): .responded(delay)
        case .timedOut: .timedOut
        }
    }
}

/// Whether the protocol core can use a node at all. This is independent of
/// latency: an unsupported node cannot be fixed by measuring it faster.
extension ProxyConfigurationSummary.Recognition {
    var localizedTitle: String {
        switch self {
        case .recognized: AppLocalization.string("Recognized")
        case .requiresCoreValidation: AppLocalization.string("Pending core check")
        case .incomplete: AppLocalization.string("Unsupported")
        }
    }

    var tint: Color {
        switch self {
        case .recognized: .green
        case .requiresCoreValidation: .orange
        case .incomplete: .red
        }
    }

    var symbol: String {
        switch self {
        case .recognized: "checkmark.circle.fill"
        case .requiresCoreValidation: "clock.badge.questionmark"
        case .incomplete: "xmark.circle"
        }
    }

    /// An unsupported node is not selectable, so the list strikes it through
    /// rather than offering an action that cannot succeed.
    var isSelectable: Bool { self != .incomplete }
}

/// The filter chips above the node table.
enum ProxyNodeFilter: String, CaseIterable, Identifiable {
    case all
    case available
    case timedOut
    case untested

    var id: Self { self }

    var localizedTitle: String {
        switch self {
        case .all: AppLocalization.string("All")
        case .available: AppLocalization.string("Available")
        case .timedOut: AppLocalization.string("Timed out")
        case .untested: AppLocalization.string("Untested")
        }
    }

    func accepts(_ status: ProxyLatencyStatus) -> Bool {
        switch self {
        case .all: true
        case .available: status.isMeasured
        case .timedOut: status == .timedOut
        case .untested: status == .untested || status == .testing
        }
    }
}

/// The filter chips above the connection table.
enum ConnectionOutletFilter: String, CaseIterable, Identifiable {
    case all
    case proxied
    case direct
    case rejected

    var id: Self { self }

    var localizedTitle: String {
        switch self {
        case .all: AppLocalization.string("All")
        case .proxied: AppLocalization.string("Proxied")
        case .direct: AppLocalization.string("Direct")
        case .rejected: AppLocalization.string("Rejected")
        }
    }
}

/// Where a flow actually left the machine. This column is the page's reason to
/// exist: it makes "did my rules do anything" checkable.
enum ConnectionOutlet: Equatable {
    case proxied(String)
    case direct
    case rejected

    init(proxyChain: String) {
        let trimmed = proxyChain.trimmingCharacters(in: .whitespaces)
        let token = trimmed.uppercased()
        if token == "REJECT" || token == "REJECT-DROP" {
            self = .rejected
        } else if trimmed.isEmpty || token == "DIRECT" {
            self = .direct
        } else {
            // Telemetry may carry the complete selector chain. The table's
            // fixed outlet column shows the leaf that actually carried the
            // flow; the strategy group is routing context, not the outlet.
            let leaf = trimmed
                .components(separatedBy: "→")
                .last?
                .components(separatedBy: "->")
                .last?
                .trimmingCharacters(in: .whitespaces)
            self = .proxied(leaf.flatMap { $0.isEmpty ? nil : $0 } ?? trimmed)
        }
    }

    var localizedTitle: String {
        switch self {
        case let .proxied(name): name
        case .direct: AppLocalization.string("Direct")
        case .rejected: AppLocalization.string("Rejected")
        }
    }

    var tint: Color {
        switch self {
        case .proxied: .accentColor
        case .direct: .secondary
        case .rejected: .red
        }
    }

    func matches(_ filter: ConnectionOutletFilter) -> Bool {
        switch filter {
        case .all: true
        case .proxied: if case .proxied = self { true } else { false }
        case .direct: self == .direct
        case .rejected: self == .rejected
        }
    }
}
