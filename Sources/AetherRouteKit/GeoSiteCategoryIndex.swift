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

    /// Evaluates whether `domain` matches `ruleValue` (including `!` negation
    /// and `@attr` filters) in a V2Fly `GeoSite.dat` payload, matching the
    /// Rust protocol core's `GeoSiteMatcher`. Returns `nil` when the category
    /// does not exist or the database is malformed.
    public static func matches(domain: String, ruleValue: String, in data: Data) -> Bool? {
        let host = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return nil }

        var rawRule = ruleValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isNegated = rawRule.hasPrefix("!")
        if isNegated {
            rawRule.removeFirst()
        }
        let parts = rawRule.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard let targetCode = parts.first, !targetCode.isEmpty else { return nil }
        let requiredAttributes = Set(parts.dropFirst().filter { !$0.isEmpty })

        let bytes = [UInt8](data)
        var reader = ProtobufReader(bytes: bytes)
        do {
            while !reader.isAtEnd {
                let (field, wireType) = try reader.readKey()
                guard field == 1, wireType == 2 else {
                    try reader.skip(wireType: wireType)
                    continue
                }
                let entryRange = try reader.readLengthDelimitedRange()
                var codeReader = ProtobufReader(bytes: bytes, range: entryRange)
                var entryCode: String?
                while !codeReader.isAtEnd {
                    let (entryField, entryWireType) = try codeReader.readKey()
                    if entryField == 1, entryWireType == 2 {
                        let raw = try codeReader.readLengthDelimited()
                        entryCode = String(bytes: raw, encoding: .utf8)?.lowercased()
                        break
                    } else {
                        try codeReader.skip(wireType: entryWireType)
                    }
                }
                guard entryCode == targetCode else { continue }

                var domainReader = ProtobufReader(bytes: bytes, range: entryRange)
                var matchedEntry = false
                while !domainReader.isAtEnd {
                    let (entryField, entryWireType) = try domainReader.readKey()
                    guard entryField == 2, entryWireType == 2 else {
                        try domainReader.skip(wireType: entryWireType)
                        continue
                    }
                    let ruleRange = try domainReader.readLengthDelimitedRange()
                    if try matchesDomainRecord(
                        host: host,
                        requiredAttributes: requiredAttributes,
                        bytes: bytes,
                        range: ruleRange
                    ) {
                        matchedEntry = true
                        break
                    }
                }
                return isNegated ? !matchedEntry : matchedEntry
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func matchesDomainRecord(
        host: String,
        requiredAttributes: Set<String>,
        bytes: [UInt8],
        range: Range<Int>
    ) throws -> Bool {
        var reader = ProtobufReader(bytes: bytes, range: range)
        var ruleType: UInt64 = 0
        var ruleValue: String?
        var attributes: Set<String> = []

        while !reader.isAtEnd {
            let (field, wireType) = try reader.readKey()
            switch (field, wireType) {
            case (1, 0):
                ruleType = try reader.readVarint()
            case (2, 2):
                let raw = try reader.readLengthDelimited()
                ruleValue = String(bytes: raw, encoding: .utf8)
            case (3, 2):
                let attrRange = try reader.readLengthDelimitedRange()
                if !requiredAttributes.isEmpty {
                    var attrReader = ProtobufReader(bytes: bytes, range: attrRange)
                    while !attrReader.isAtEnd {
                        let (attrField, attrWire) = try attrReader.readKey()
                        if attrField == 1, attrWire == 2 {
                            let keyBytes = try attrReader.readLengthDelimited()
                            if let key = String(bytes: keyBytes, encoding: .utf8)?.lowercased() {
                                attributes.insert(key)
                            }
                        } else {
                            try attrReader.skip(wireType: attrWire)
                        }
                    }
                }
            default:
                try reader.skip(wireType: wireType)
            }
        }

        if !requiredAttributes.isEmpty, !requiredAttributes.isSubset(of: attributes) {
            return false
        }
        guard let rawPattern = ruleValue, !rawPattern.isEmpty else { return false }
        let pattern = rawPattern.lowercased()
        switch ruleType {
        case 0: // Plain (keyword)
            return host.contains(pattern)
        case 1: // Regex
            guard let regex = try? NSRegularExpression(pattern: rawPattern, options: [.caseInsensitive]) else {
                return false
            }
            return regex.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil
        case 2: // Domain (root/suffix)
            return host == pattern || host.hasSuffix("." + pattern)
        case 3: // Full (exact)
            return host == pattern
        default:
            return false
        }
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
    private var offset: Int
    private let endOffset: Int

    init(bytes: [UInt8], range: Range<Int>? = nil) {
        self.bytes = bytes
        self.offset = range?.lowerBound ?? 0
        self.endOffset = range?.upperBound ?? bytes.count
    }

    var isAtEnd: Bool { offset >= endOffset }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < endOffset, shift < 64 else {
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

    mutating func readLengthDelimitedRange() throws -> Range<Int> {
        let length = try readVarint()
        guard length <= UInt64(endOffset - offset) else {
            throw GeoSiteCategoryIndexError.malformedDatabase
        }
        let end = offset + Int(length)
        defer { offset = end }
        return offset..<end
    }

    mutating func readLengthDelimited() throws -> [UInt8] {
        let range = try readLengthDelimitedRange()
        return Array(bytes[range])
    }

    mutating func skip(wireType: UInt64) throws {
        switch wireType {
        case 0:
            _ = try readVarint()
        case 1, 5:
            let width = wireType == 1 ? 8 : 4
            guard width <= endOffset - offset else {
                throw GeoSiteCategoryIndexError.malformedDatabase
            }
            offset += width
        case 2:
            _ = try readLengthDelimitedRange()
        default:
            throw GeoSiteCategoryIndexError.malformedDatabase
        }
    }
}
