import Foundation
import NetworkExtension

private enum ProbeError: Error {
    case managerNotFound
    case sessionUnavailable
    case missingResponse
    case malformedResponse
}

private let packetTunnelBundleIdentifier = "com.aetherroute.desktop.tunnel"

private func loadManagers() async throws -> [NETunnelProviderManager] {
    try await withCheckedThrowingContinuation { continuation in
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: managers ?? [])
            }
        }
    }
}

private func sendTelemetryRequest(
    through session: NETunnelProviderSession
) async throws -> Data {
    // ARQ1, telemetry operation, maximum 128 connections, empty names.
    let request = Data([
        0x41, 0x52, 0x51, 0x31,
        0x04, 0x00, 0x00, 0x80,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])
    return try await withCheckedThrowingContinuation { continuation in
        do {
            try session.sendProviderMessage(request) { response in
                guard let response else {
                    continuation.resume(throwing: ProbeError.missingResponse)
                    return
                }
                continuation.resume(returning: response)
            }
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= bytes.count else { return nil }
    return bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
}

private func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64? {
    guard offset >= 0, offset + 8 <= bytes.count else { return nil }
    return bytes[offset..<offset + 8].reduce(0) { ($0 << 8) | UInt64($1) }
}

private func decodeTelemetrySummary(
    _ response: Data
) throws -> (memoryBytes: UInt64, connectionCount: UInt32) {
    let bytes = [UInt8](response)
    let responseHeaderBytes = 16
    let telemetryHeaderBytes = 48
    guard
        bytes.count >= responseHeaderBytes + telemetryHeaderBytes,
        Array(bytes[0..<4]) == [0x41, 0x52, 0x50, 0x31],
        bytes[4] == 0x04,
        bytes[5] == 0,
        Array(bytes[responseHeaderBytes..<responseHeaderBytes + 4])
            == [0x41, 0x52, 0x54, 0x31],
        let outerCount = readUInt32(bytes, at: 12),
        let memoryBytes = readUInt64(bytes, at: responseHeaderBytes + 36),
        let connectionCount = readUInt32(bytes, at: responseHeaderBytes + 44),
        outerCount == connectionCount,
        connectionCount <= 128
    else { throw ProbeError.malformedResponse }
    return (memoryBytes, connectionCount)
}

@main
private struct ProviderTelemetryProbe {
    static func main() async {
        do {
            let managers = try await loadManagers()
            guard let manager = managers.first(where: { manager in
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == packetTunnelBundleIdentifier
                    && manager.connection.status == .connected
            }) else { throw ProbeError.managerNotFound }
            guard let session = manager.connection as? NETunnelProviderSession else {
                throw ProbeError.sessionUnavailable
            }
            let response = try await sendTelemetryRequest(through: session)
            let summary = try decodeTelemetrySummary(response)
            let output: [String: Any] = [
                "schema": 1,
                "provider_bundle": packetTunnelBundleIdentifier,
                "status": session.status.rawValue,
                "memory_bytes": summary.memoryBytes,
                "active_connection_count": summary.connectionCount,
            ]
            let encoded = try JSONSerialization.data(
                withJSONObject: output,
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(encoded)
            FileHandle.standardOutput.write(Data([0x0a]))
        } catch {
            FileHandle.standardError.write(
                Data("provider telemetry probe failed: \(error)\n".utf8)
            )
            Foundation.exit(1)
        }
    }
}
