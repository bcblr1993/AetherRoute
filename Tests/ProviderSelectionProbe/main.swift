import CryptoKit
import Foundation
import NetworkExtension

private enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments
    case managerNotFound
    case sessionUnavailable
    case missingResponse
    case malformedResponse

    var description: String {
        switch self {
        case .invalidArguments: "invalid-arguments"
        case .managerNotFound: "manager-not-found"
        case .sessionUnavailable: "session-unavailable"
        case .missingResponse: "missing-response"
        case .malformedResponse: "malformed-response"
        }
    }
}

private enum Engine: String {
    case tun
    case transparent

    var providerBundleIdentifier: String {
        switch self {
        case .tun: "com.aetherroute.desktop.tunnel"
        case .transparent: "com.aetherroute.desktop.transparent-proxy"
        }
    }
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= bytes.count else { return nil }
    return bytes[offset..<offset + 4].reduce(0) {
        ($0 << 8) | UInt32($1)
    }
}

private func loadManagers(for engine: Engine) async throws -> [NEVPNManager] {
    switch engine {
    case .tun:
        return try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    case .transparent:
        return try await withCheckedThrowingContinuation { continuation in
            NETransparentProxyManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }
}

private func snapshotRequest(group: String) throws -> Data {
    try request(operation: 1, group: group, member: nil)
}

private func selectRequest(group: String, member: String) throws -> Data {
    try request(operation: 2, group: group, member: member)
}

private func request(
    operation: UInt8,
    group: String,
    member: String?
) throws -> Data {
    let encoded = Data(group.utf8)
    guard !encoded.isEmpty, encoded.count <= 1_024 else {
        throw ProbeError.invalidArguments
    }
    let encodedMember = Data((member ?? "").utf8)
    guard encodedMember.count <= 1_024,
          operation == 1 ? encodedMember.isEmpty : !encodedMember.isEmpty
    else { throw ProbeError.invalidArguments }
    var request = Data([0x41, 0x52, 0x51, 0x31, operation, 0, 0, 0])
    appendUInt32(UInt32(encoded.count), to: &request)
    appendUInt32(UInt32(encodedMember.count), to: &request)
    request.append(encoded)
    request.append(encodedMember)
    return request
}

private func send(
    _ request: Data,
    through session: NETunnelProviderSession
) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
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

private func decodeSelectedHash(_ response: Data) throws -> (String, UInt32) {
    let bytes = [UInt8](response)
    guard bytes.count >= 16,
          Array(bytes[0..<4]) == [0x41, 0x52, 0x50, 0x31],
          bytes[4] == 1,
          bytes[5] == 0,
          bytes[6] == 0,
          bytes[7] == 0,
          let selectedIndex = readUInt32(bytes, at: 8),
          let memberCount = readUInt32(bytes, at: 12),
          memberCount > 0,
          memberCount <= 4_096,
          selectedIndex < memberCount
    else { throw ProbeError.malformedResponse }

    var offset = 16
    var selected = Data()
    for index in 0..<memberCount {
        guard let length = readUInt32(bytes, at: offset),
              length > 0,
              length <= 1_024
        else { throw ProbeError.malformedResponse }
        offset += 4
        let end = offset + Int(length)
        guard end <= bytes.count else { throw ProbeError.malformedResponse }
        if index == selectedIndex {
            selected = Data(bytes[offset..<end])
        }
        offset = end
    }
    guard offset == bytes.count, !selected.isEmpty else {
        throw ProbeError.malformedResponse
    }
    let digest = SHA256.hash(data: selected).map {
        String(format: "%02x", $0)
    }.joined()
    return (digest, memberCount)
}

@main
private struct ProviderSelectionProbe {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard (3...4).contains(arguments.count),
                  arguments[0] == "--engine",
                  let engine = Engine(rawValue: arguments[1])
            else {
                throw ProbeError.invalidArguments
            }
            let group = arguments[2]
            let requestedMember = arguments.count == 4 ? arguments[3] : nil
            let operation = requestedMember == nil
                ? "snapshot"
                : "select"
            let managers = try await loadManagers(for: engine)
            guard let manager = managers.first(where: { manager in
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == engine.providerBundleIdentifier
            }) else { throw ProbeError.managerNotFound }
            guard let session = manager.connection as? NETunnelProviderSession
            else { throw ProbeError.sessionUnavailable }
            let request = if requestedMember == nil {
                try snapshotRequest(group: group)
            } else {
                try selectRequest(
                    group: group,
                    member: requestedMember!
                )
            }
            let response = try await send(
                request,
                through: session
            )
            let (selectedHash, memberCount) = try decodeSelectedHash(response)
            let output: [String: Any] = [
                "schema": 1,
                "provider_bundle": engine.providerBundleIdentifier,
                "engine": engine.rawValue,
                "operation": operation,
                "status": session.status.rawValue,
                "member_count": memberCount,
                "selected_name_sha256": selectedHash,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: output,
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))
        } catch {
            let code = (error as? ProbeError)?.description ?? "system-error"
            FileHandle.standardError.write(
                Data("provider selection probe failed code=\(code)\n".utf8)
            )
            Foundation.exit(1)
        }
    }
}
