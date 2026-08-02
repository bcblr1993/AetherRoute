import Foundation

/// Host-side client for the bounded provider-message protocol. The transport
/// is injected so protocol behavior can be tested without installing or
/// starting a Network Extension.
public struct ProxySelectionProviderClient: Sendable {
    public typealias Transport = @Sendable (Data) async throws -> Data

    private let transport: Transport

    public init(transport: @escaping Transport) {
        self.transport = transport
    }

    public func snapshot(group: String) async throws -> ProxySelectionState {
        switch try await send(.snapshot(group: group)) {
        case let .snapshot(snapshot): snapshot
        case .latency, .telemetry, .diagnostics:
            throw ProxySelectionProviderClientError.unexpectedResponse
        case let .failure(failure):
            throw ProxySelectionProviderClientError.providerFailure(failure)
        }
    }

    public func select(
        group: String,
        member: String
    ) async throws -> ProxySelectionState {
        let response = try await send(.select(group: group, member: member))
        guard case let .snapshot(snapshot) = response else {
            if case let .failure(failure) = response {
                throw ProxySelectionProviderClientError.providerFailure(failure)
            }
            throw ProxySelectionProviderClientError.unexpectedResponse
        }
        guard snapshot.selectedMember == member else {
            throw ProxySelectionProviderClientError.selectionNotApplied
        }
        return snapshot
    }

    public func latency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32
    ) async throws -> ProxyLatencyState {
        switch try await send(
            .latency(
                group: group,
                url: url,
                timeoutMilliseconds: timeoutMilliseconds
            )
        ) {
        case let .latency(state): state
        case .snapshot, .telemetry, .diagnostics:
            throw ProxySelectionProviderClientError.unexpectedResponse
        case let .failure(failure):
            throw ProxySelectionProviderClientError.providerFailure(failure)
        }
    }

    public func telemetry(
        maximumConnections: UInt16 = 50
    ) async throws -> NetworkTelemetrySnapshot {
        switch try await send(
            .telemetry(maximumConnections: maximumConnections)
        ) {
        case let .telemetry(snapshot): snapshot
        case .snapshot, .latency, .diagnostics:
            throw ProxySelectionProviderClientError.unexpectedResponse
        case let .failure(failure):
            throw ProxySelectionProviderClientError.providerFailure(failure)
        }
    }

    public func diagnostics() async throws -> ProviderDiagnosticSnapshot {
        switch try await send(.diagnostics) {
        case let .diagnostics(snapshot): snapshot
        case .snapshot, .latency, .telemetry:
            throw ProxySelectionProviderClientError.unexpectedResponse
        case let .failure(failure):
            throw ProxySelectionProviderClientError.providerFailure(failure)
        }
    }

    private func send(
        _ request: ProxySelectionProviderRequest
    ) async throws -> ProxySelectionProviderResponse {
        let requestData = try ProxySelectionProviderMessageCodec.encode(
            request: request
        )
        let responseData = try await transport(requestData)
        return try ProxySelectionProviderMessageCodec.decodeResponse(responseData)
    }
}

public enum ProxySelectionProviderClientError: LocalizedError, Sendable,
    Equatable
{
    case providerFailure(ProxySelectionProviderFailure)
    case selectionNotApplied
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case let .providerFailure(failure):
            switch failure {
            case .invalidRequest:
                "The network extension rejected an invalid proxy selection request."
            case .unavailable:
                "The live proxy selector is not available."
            case .rejected:
                "This proxy group does not support manual selection."
            case .responseTooLarge:
                "The proxy group is too large to display safely."
            case .internalFailure:
                "The network extension could not read the proxy selector."
            }
        case .selectionNotApplied:
            "The network extension did not confirm the selected proxy."
        case .unexpectedResponse:
            "The network extension returned an unexpected proxy response."
        }
    }
}
