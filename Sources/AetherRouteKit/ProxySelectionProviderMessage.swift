import Foundation

/// A verified selector projection shared by the host app and both Network
/// Extension providers. Names are profile data, never localized UI strings.
public struct ProxySelectionState: Sendable, Equatable {
    public let selectedMember: String?
    public let members: [String]

    public init(selectedMember: String?, members: [String]) {
        self.selectedMember = selectedMember
        self.members = members
    }
}

public struct ProxyLatencyResult: Sendable, Equatable {
    public let member: String
    public let delayMilliseconds: UInt32?

    public init(member: String, delayMilliseconds: UInt32?) {
        self.member = member
        self.delayMilliseconds = delayMilliseconds
    }
}

public struct ProxyLatencyState: Sendable, Equatable {
    public let results: [ProxyLatencyResult]

    public init(results: [ProxyLatencyResult]) {
        self.results = results
    }
}

public enum ProxySelectionProviderRequest: Sendable, Equatable {
    case snapshot(group: String)
    case select(group: String, member: String)
    case latency(group: String, url: String, timeoutMilliseconds: UInt32)
    case telemetry(maximumConnections: UInt16)
    case diagnostics
}

public enum ProxySelectionProviderFailure: UInt8, Sendable, Equatable {
    case invalidRequest = 1
    case unavailable = 2
    case rejected = 3
    case responseTooLarge = 4
    case internalFailure = 5
}

public enum ProxySelectionProviderResponse: Sendable, Equatable {
    case snapshot(ProxySelectionState)
    case latency(ProxyLatencyState)
    case telemetry(NetworkTelemetrySnapshot)
    case diagnostics(ProviderDiagnosticSnapshot)
    case failure(ProxySelectionProviderFailure)
}

public enum ProxySelectionProviderMessageError: Error, Sendable, Equatable {
    case malformed
    case invalidName
    case tooLarge
    case invalidSnapshot
    case invalidLatency
}

/// Versioned binary provider-message protocol. Every allocation is preceded by
/// a fixed upper-bound check, unknown operations are rejected, and decoders
/// require exact consumption so trailing or ambiguous input cannot be smuggled
/// across the app/extension trust boundary.
public enum ProxySelectionProviderMessageCodec {
    public static let maximumNameBytes = 1_024
    public static let maximumURLBytes = 2_048
    public static let maximumMemberCount = 4_096
    public static let maximumMessageBytes = 1_048_576
    public static let minimumLatencyTimeoutMilliseconds: UInt32 = 100
    public static let maximumLatencyTimeoutMilliseconds: UInt32 = 30_000

    private static let requestMagic: [UInt8] = [0x41, 0x52, 0x51, 0x31]
    private static let responseMagic: [UInt8] = [0x41, 0x52, 0x50, 0x31]
    private static let requestHeaderBytes = 16
    private static let responseHeaderBytes = 16
    private static let noSelection = UInt32.max
    private static let diagnosticCounterCount: UInt32 = 8

    public static func encode(
        request: ProxySelectionProviderRequest
    ) throws -> Data {
        let operation: UInt8
        let group: Data
        let member: Data
        let reserved: [UInt8]
        switch request {
        case let .snapshot(value):
            operation = 1
            group = try nameData(value)
            member = Data()
            reserved = [0, 0, 0]
        case let .select(value, selected):
            operation = 2
            group = try nameData(value)
            member = try nameData(selected)
            reserved = [0, 0, 0]
        case let .latency(value, url, timeoutMilliseconds):
            guard
                timeoutMilliseconds >= minimumLatencyTimeoutMilliseconds,
                timeoutMilliseconds <= maximumLatencyTimeoutMilliseconds
            else { throw ProxySelectionProviderMessageError.invalidLatency }
            operation = 3
            group = try nameData(value)
            member = try urlData(url)
            reserved = [
                UInt8((timeoutMilliseconds >> 16) & 0xff),
                UInt8((timeoutMilliseconds >> 8) & 0xff),
                UInt8(timeoutMilliseconds & 0xff),
            ]
        case let .telemetry(maximumConnections):
            guard
                maximumConnections > 0,
                Int(maximumConnections) <= NetworkTelemetryCodec.maximumConnections
            else { throw ProxySelectionProviderMessageError.malformed }
            operation = 4
            group = Data()
            member = Data()
            reserved = [
                0,
                UInt8((maximumConnections >> 8) & 0xff),
                UInt8(maximumConnections & 0xff),
            ]
        case .diagnostics:
            operation = 5
            group = Data()
            member = Data()
            reserved = [0, 0, 0]
        }

        var output = Data(requestMagic)
        output.append(operation)
        output.append(contentsOf: reserved)
        appendUInt32(UInt32(group.count), to: &output)
        appendUInt32(UInt32(member.count), to: &output)
        output.append(group)
        output.append(member)
        guard output.count <= maximumMessageBytes else {
            throw ProxySelectionProviderMessageError.tooLarge
        }
        return output
    }

    public static func decodeRequest(
        _ data: Data
    ) throws -> ProxySelectionProviderRequest {
        guard
            data.count >= requestHeaderBytes,
            data.count <= maximumMessageBytes
        else { throw ProxySelectionProviderMessageError.tooLarge }
        let bytes = [UInt8](data)
        guard
            Array(bytes[0..<4]) == requestMagic,
            let groupLength = readUInt32(bytes, at: 8),
            let memberLength = readUInt32(bytes, at: 12)
        else { throw ProxySelectionProviderMessageError.malformed }

        let groupStart = requestHeaderBytes
        let memberStart = try checkedEnd(
            start: groupStart,
            length: groupLength,
            limit: bytes.count
        )
        let end = try checkedEnd(
            start: memberStart,
            length: memberLength,
            limit: bytes.count
        )
        guard end == bytes.count else {
            throw ProxySelectionProviderMessageError.malformed
        }
        switch bytes[4] {
        case 1:
            guard
                bytes[5] == 0,
                bytes[6] == 0,
                bytes[7] == 0,
                memberLength == 0
            else {
                throw ProxySelectionProviderMessageError.malformed
            }
            return .snapshot(group: try name(bytes[groupStart..<memberStart]))
        case 2:
            guard bytes[5] == 0, bytes[6] == 0, bytes[7] == 0 else {
                throw ProxySelectionProviderMessageError.malformed
            }
            return .select(
                group: try name(bytes[groupStart..<memberStart]),
                member: try name(bytes[memberStart..<end])
            )
        case 3:
            let timeoutMilliseconds = UInt32(bytes[5]) << 16
                | UInt32(bytes[6]) << 8
                | UInt32(bytes[7])
            guard
                timeoutMilliseconds >= minimumLatencyTimeoutMilliseconds,
                timeoutMilliseconds <= maximumLatencyTimeoutMilliseconds
            else { throw ProxySelectionProviderMessageError.invalidLatency }
            return .latency(
                group: try name(bytes[groupStart..<memberStart]),
                url: try url(bytes[memberStart..<end]),
                timeoutMilliseconds: timeoutMilliseconds
            )
        case 4:
            let maximumConnections = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
            guard
                bytes[5] == 0,
                groupLength == 0,
                memberLength == 0,
                maximumConnections > 0,
                Int(maximumConnections) <= NetworkTelemetryCodec.maximumConnections
            else { throw ProxySelectionProviderMessageError.malformed }
            return .telemetry(maximumConnections: maximumConnections)
        case 5:
            guard
                bytes[5] == 0,
                bytes[6] == 0,
                bytes[7] == 0,
                groupLength == 0,
                memberLength == 0
            else { throw ProxySelectionProviderMessageError.malformed }
            return .diagnostics
        default:
            throw ProxySelectionProviderMessageError.malformed
        }
    }

    public static func encode(
        response: ProxySelectionProviderResponse
    ) throws -> Data {
        switch response {
        case let .failure(failure):
            var output = Data(responseMagic)
            output.append(2)
            output.append(failure.rawValue)
            output.append(contentsOf: [0, 0])
            appendUInt32(noSelection, to: &output)
            appendUInt32(0, to: &output)
            return output
        case let .snapshot(snapshot):
            guard snapshot.members.count <= maximumMemberCount else {
                throw ProxySelectionProviderMessageError.tooLarge
            }
            let memberData = try snapshot.members.map(nameData)
            let selectedIndex: UInt32
            if let selected = snapshot.selectedMember {
                guard let index = snapshot.members.firstIndex(of: selected) else {
                    throw ProxySelectionProviderMessageError.invalidSnapshot
                }
                selectedIndex = UInt32(index)
            } else {
                selectedIndex = noSelection
            }

            var output = Data(responseMagic)
            output.append(1)
            output.append(0)
            output.append(contentsOf: [0, 0])
            appendUInt32(selectedIndex, to: &output)
            appendUInt32(UInt32(memberData.count), to: &output)
            for value in memberData {
                appendUInt32(UInt32(value.count), to: &output)
                output.append(value)
                guard output.count <= maximumMessageBytes else {
                    throw ProxySelectionProviderMessageError.tooLarge
                }
            }
            return output
        case let .latency(state):
            guard state.results.count <= maximumMemberCount else {
                throw ProxySelectionProviderMessageError.tooLarge
            }
            let resultData = try state.results.map { result in
                (try nameData(result.member), result.delayMilliseconds)
            }
            var output = Data(responseMagic)
            output.append(3)
            output.append(contentsOf: [0, 0, 0])
            appendUInt32(noSelection, to: &output)
            appendUInt32(UInt32(resultData.count), to: &output)
            for (member, delay) in resultData {
                appendUInt32(UInt32(member.count), to: &output)
                output.append(member)
                appendUInt32(delay ?? UInt32.max, to: &output)
                guard output.count <= maximumMessageBytes else {
                    throw ProxySelectionProviderMessageError.tooLarge
                }
            }
            return output
        case let .telemetry(snapshot):
            let payload = try NetworkTelemetryCodec.encode(snapshot)
            var output = Data(responseMagic)
            output.append(4)
            output.append(contentsOf: [0, 0, 0])
            appendUInt32(noSelection, to: &output)
            appendUInt32(UInt32(snapshot.connections.count), to: &output)
            output.append(payload)
            guard output.count <= maximumMessageBytes else {
                throw ProxySelectionProviderMessageError.tooLarge
            }
            return output
        case let .diagnostics(snapshot):
            var output = Data(responseMagic)
            output.append(5)
            output.append(contentsOf: [0, 0, 0])
            appendUInt32(noSelection, to: &output)
            appendUInt32(diagnosticCounterCount, to: &output)
            for value in [
                snapshot.startupFailureCount,
                snapshot.networkSettingsFailureCount,
                snapshot.invalidControlRequestCount,
                snapshot.unavailableControlRequestCount,
                snapshot.rejectedControlRequestCount,
                snapshot.oversizedControlResponseCount,
                snapshot.internalControlFailureCount,
                snapshot.flowAdmissionFailureCount,
            ] {
                appendUInt64(value, to: &output)
            }
            return output
        }
    }

    public static func decodeResponse(
        _ data: Data
    ) throws -> ProxySelectionProviderResponse {
        guard
            data.count >= responseHeaderBytes,
            data.count <= maximumMessageBytes
        else { throw ProxySelectionProviderMessageError.tooLarge }
        let bytes = [UInt8](data)
        guard
            Array(bytes[0..<4]) == responseMagic,
            bytes[6] == 0,
            bytes[7] == 0,
            let selectedIndex = readUInt32(bytes, at: 8),
            let memberCount = readUInt32(bytes, at: 12)
        else { throw ProxySelectionProviderMessageError.malformed }

        switch bytes[4] {
        case 2:
            guard
                data.count == responseHeaderBytes,
                selectedIndex == noSelection,
                memberCount == 0,
                let failure = ProxySelectionProviderFailure(rawValue: bytes[5])
            else { throw ProxySelectionProviderMessageError.malformed }
            return .failure(failure)
        case 1:
            guard
                bytes[5] == 0,
                memberCount <= maximumMemberCount
            else { throw ProxySelectionProviderMessageError.invalidSnapshot }
        case 3:
            guard
                bytes[5] == 0,
                selectedIndex == noSelection,
                memberCount <= maximumMemberCount
            else { throw ProxySelectionProviderMessageError.invalidLatency }
        case 4:
            guard
                bytes[5] == 0,
                selectedIndex == noSelection,
                Int(memberCount) <= NetworkTelemetryCodec.maximumConnections
            else { throw ProxySelectionProviderMessageError.malformed }
        case 5:
            guard
                bytes[5] == 0,
                selectedIndex == noSelection,
                memberCount == diagnosticCounterCount,
                data.count == responseHeaderBytes
                    + Int(diagnosticCounterCount) * MemoryLayout<UInt64>.size
            else { throw ProxySelectionProviderMessageError.malformed }
        default:
            throw ProxySelectionProviderMessageError.malformed
        }

        var offset = responseHeaderBytes
        if bytes[4] == 5 {
            var counters: [UInt64] = []
            counters.reserveCapacity(Int(diagnosticCounterCount))
            for _ in 0..<diagnosticCounterCount {
                guard let value = readUInt64(bytes, at: offset) else {
                    throw ProxySelectionProviderMessageError.malformed
                }
                counters.append(value)
                offset += MemoryLayout<UInt64>.size
            }
            guard offset == bytes.count else {
                throw ProxySelectionProviderMessageError.malformed
            }
            return .diagnostics(
                ProviderDiagnosticSnapshot(
                    startupFailureCount: counters[0],
                    networkSettingsFailureCount: counters[1],
                    invalidControlRequestCount: counters[2],
                    unavailableControlRequestCount: counters[3],
                    rejectedControlRequestCount: counters[4],
                    oversizedControlResponseCount: counters[5],
                    internalControlFailureCount: counters[6],
                    flowAdmissionFailureCount: counters[7]
                )
            )
        }
        if bytes[4] == 4 {
            let snapshot: NetworkTelemetrySnapshot
            do {
                snapshot = try NetworkTelemetryCodec.decode(
                    Data(bytes[responseHeaderBytes...])
                )
            } catch {
                throw ProxySelectionProviderMessageError.malformed
            }
            guard snapshot.connections.count == Int(memberCount) else {
                throw ProxySelectionProviderMessageError.malformed
            }
            return .telemetry(snapshot)
        }
        if bytes[4] == 3 {
            var results: [ProxyLatencyResult] = []
            results.reserveCapacity(Int(memberCount))
            for _ in 0..<memberCount {
                guard let length = readUInt32(bytes, at: offset) else {
                    throw ProxySelectionProviderMessageError.invalidLatency
                }
                offset += 4
                let end = try checkedEnd(
                    start: offset,
                    length: length,
                    limit: bytes.count
                )
                let member = try name(bytes[offset..<end])
                guard let delay = readUInt32(bytes, at: end) else {
                    throw ProxySelectionProviderMessageError.invalidLatency
                }
                offset = end + 4
                results.append(
                    ProxyLatencyResult(
                        member: member,
                        delayMilliseconds: delay == UInt32.max ? nil : delay
                    )
                )
            }
            guard offset == bytes.count else {
                throw ProxySelectionProviderMessageError.invalidLatency
            }
            return .latency(ProxyLatencyState(results: results))
        }
        var members: [String] = []
        members.reserveCapacity(Int(memberCount))
        for _ in 0..<memberCount {
            guard let length = readUInt32(bytes, at: offset) else {
                throw ProxySelectionProviderMessageError.invalidSnapshot
            }
            offset += 4
            let end = try checkedEnd(
                start: offset,
                length: length,
                limit: bytes.count
            )
            members.append(try name(bytes[offset..<end]))
            offset = end
        }
        guard offset == bytes.count else {
            throw ProxySelectionProviderMessageError.invalidSnapshot
        }
        let selected: String?
        if selectedIndex == noSelection {
            selected = nil
        } else {
            guard Int(selectedIndex) < members.count else {
                throw ProxySelectionProviderMessageError.invalidSnapshot
            }
            selected = members[Int(selectedIndex)]
        }
        return .snapshot(
            ProxySelectionState(selectedMember: selected, members: members)
        )
    }

    private static func nameData(_ value: String) throws -> Data {
        guard
            let data = value.data(using: .utf8),
            (1...maximumNameBytes).contains(data.count),
            !data.contains(0)
        else { throw ProxySelectionProviderMessageError.invalidName }
        return data
    }

    private static func name(_ bytes: ArraySlice<UInt8>) throws -> String {
        guard
            (1...maximumNameBytes).contains(bytes.count),
            !bytes.contains(0),
            let value = String(bytes: bytes, encoding: .utf8)
        else { throw ProxySelectionProviderMessageError.invalidName }
        return value
    }

    private static func urlData(_ value: String) throws -> Data {
        guard
            let data = value.data(using: .utf8),
            (1...maximumURLBytes).contains(data.count),
            !data.contains(0),
            value.hasPrefix("https://") || value.hasPrefix("http://")
        else { throw ProxySelectionProviderMessageError.invalidLatency }
        return data
    }

    private static func url(_ bytes: ArraySlice<UInt8>) throws -> String {
        guard
            (1...maximumURLBytes).contains(bytes.count),
            !bytes.contains(0),
            let value = String(bytes: bytes, encoding: .utf8),
            value.hasPrefix("https://") || value.hasPrefix("http://")
        else { throw ProxySelectionProviderMessageError.invalidLatency }
        return value
    }

    private static func checkedEnd(
        start: Int,
        length: UInt32,
        limit: Int
    ) throws -> Int {
        let (end, overflow) = start.addingReportingOverflow(Int(length))
        guard !overflow, end <= limit else {
            throw ProxySelectionProviderMessageError.malformed
        }
        return end
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        data.append(UInt8((value >> 56) & 0xff))
        data.append(UInt8((value >> 48) & 0xff))
        data.append(UInt8((value >> 40) & 0xff))
        data.append(UInt8((value >> 32) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func readUInt32(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private static func readUInt64(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt64? {
        guard offset >= 0, offset + 8 <= bytes.count else { return nil }
        return UInt64(bytes[offset]) << 56
            | UInt64(bytes[offset + 1]) << 48
            | UInt64(bytes[offset + 2]) << 40
            | UInt64(bytes[offset + 3]) << 32
            | UInt64(bytes[offset + 4]) << 24
            | UInt64(bytes[offset + 5]) << 16
            | UInt64(bytes[offset + 6]) << 8
            | UInt64(bytes[offset + 7])
    }
}
