import Foundation

/// The category names in a V2Fly `GeoSite.dat`, so a `GEOSITE` rule can be
/// checked before the core sees it. The core refuses the whole rule set when
/// a category is missing ("geosite matcher, country code … not found").
public struct GeoSiteCategoryIndex: Equatable, Sendable {
    /// Lowercased category codes, as the core compares them.
    public let codes: Set<String>

    public init(codes: Set<String>) {
        self.codes = Set(codes.map { $0.lowercased() })
    }

    /// Reads only the `country_code` of each entry of a `GeoSiteList`
    /// (`repeated GeoSite entry = 1`, `string country_code = 1`) and skips
    /// every other field by its wire type.
    public init(data: Data) throws {
        var reader = ProtobufReader(bytes: [UInt8](data))
        var codes = Set<String>()
        while !reader.isAtEnd {
            let (field, wireType) = try reader.readKey()
            guard field == 1, wireType == 2 else {
                try reader.skip(wireType: wireType)
                continue
            }
            var entry = ProtobufReader(bytes: try reader.readLengthDelimited())
            while !entry.isAtEnd {
                let (entryField, entryWireType) = try entry.readKey()
                if entryField == 1, entryWireType == 2 {
                    let raw = try entry.readLengthDelimited()
                    guard let code = String(bytes: raw, encoding: .utf8) else {
                        throw GeoSiteCategoryIndexError.malformedDatabase
                    }
                    codes.insert(code.lowercased())
                } else {
                    try entry.skip(wireType: entryWireType)
                }
            }
        }
        guard !codes.isEmpty else {
            throw GeoSiteCategoryIndexError.malformedDatabase
        }
        self.codes = codes
    }

    /// The category a rule value names, parsed as the core does: case is
    /// ignored, a leading `!` negates, and `@attr` filters follow the name.
    public static func categoryCode(of ruleValue: String) -> String {
        var value = ruleValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("!") {
            value.removeFirst()
        }
        return String(value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    public func contains(ruleValue: String) -> Bool {
        codes.contains(Self.categoryCode(of: ruleValue))
    }

    /// Enabled `GEOSITE` custom rules whose category this database lacks.
    public func unknownCategories(in rules: [CustomRule]) -> [String] {
        rules.filter { $0.isEnabled && $0.kind == .geoSite && !contains(ruleValue: $0.value) }
            .map(\.value)
    }
}

public enum CustomRuleGeoSiteError: LocalizedError, Equatable, Sendable {
    /// A custom `GEOSITE` rule names a category the routing database lacks.
    case unknownCategory(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownCategory(category):
            "The GEOSITE category \(category) is not in the routing database."
        }
    }
}

public enum GeoSiteCategoryIndexError: LocalizedError, Equatable, Sendable {
    case malformedDatabase

    public var errorDescription: String? {
        "The GeoSite database could not be read."
    }
}

/// Minimal bounds-checked protobuf wire reader for `GeoSiteCategoryIndex`.
private struct ProtobufReader {
    let bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.count, shift < 64 else {
                throw GeoSiteCategoryIndexError.malformedDatabase
            }
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func readKey() throws -> (field: UInt64, wireType: UInt64) {
        let key = try readVarint()
        return (key >> 3, key & 0x7)
    }

    mutating func readLengthDelimited() throws -> [UInt8] {
        let length = try readVarint()
        guard length <= UInt64(bytes.count - offset) else {
            throw GeoSiteCategoryIndexError.malformedDatabase
        }
        let end = offset + Int(length)
        defer { offset = end }
        return Array(bytes[offset..<end])
    }

    mutating func skip(wireType: UInt64) throws {
        switch wireType {
        case 0:
            _ = try readVarint()
        case 1, 5:
            let width = wireType == 1 ? 8 : 4
            guard width <= bytes.count - offset else {
                throw GeoSiteCategoryIndexError.malformedDatabase
            }
            offset += width
        case 2:
            _ = try readLengthDelimited()
        default:
            throw GeoSiteCategoryIndexError.malformedDatabase
        }
    }
}
