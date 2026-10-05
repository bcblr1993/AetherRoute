import Foundation

/// The app a transparent-proxy flow came from, as handed to the engine.
///
/// Both fields come from the operating system (`NEFlowMetaData` and the
/// audit token's process), never from the profile. A field that is empty,
/// too long or contains control characters is dropped rather than sent, since
/// the engine rejects the whole description in that case; a description with
/// neither field is `nil`.
public struct FlowSourceApp: Sendable, Equatable, Hashable {
    /// Matches `MAXIMUM_SOURCE_APP_FIELD_BYTES` in clash-ffi's flow ABI.
    public static let maximumFieldBytes = 512

    public let signingIdentifier: String?
    public let executablePath: String?

    public init?(signingIdentifier: String?, executablePath: String?) {
        let signingIdentifier = Self.acceptedField(signingIdentifier)
        let executablePath = Self.acceptedField(executablePath)
        guard signingIdentifier != nil || executablePath != nil else {
            return nil
        }
        self.signingIdentifier = signingIdentifier
        self.executablePath = executablePath
    }

    /// The `ASA1` encoding accepted by `clash_flow_*_create_v2`: the magic,
    /// then a big-endian u16 length and UTF-8 bytes for the signing
    /// identifier and for the path (length 0 when absent).
    public var encoded: Data {
        var output = Data("ASA1".utf8)
        for field in [signingIdentifier, executablePath] {
            let bytes = Data((field ?? "").utf8)
            output.append(UInt8(bytes.count >> 8))
            output.append(UInt8(bytes.count & 0xff))
            output.append(bytes)
        }
        return output
    }

    private static func acceptedField(_ value: String?) -> String? {
        guard
            let value,
            !value.isEmpty,
            value.utf8.count <= maximumFieldBytes,
            !value.unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control
            })
        else { return nil }
        return value
    }
}
